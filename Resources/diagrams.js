// Mermaid diagrams in the FocusEdit preview.
//
// The preview page has no scripts of its own: the app loads mermaid.min.js and this file
// into every page, then calls `__feDiagrams.configure(colors)` once per page and
// `__feDiagrams.refresh()` after every body replacement. A fenced ```mermaid block
// (<pre><code class="language-mermaid">) is replaced by a figure with the drawn SVG.
//
// - The figure fits the page width and never spills over it; a wide diagram may use the
//   whole window width when the text column is narrower (Preview alone).
// - Zoom per figure: the − / + / Fit buttons, ⌥-scroll or a pinch over it; zoomed, it
//   scrolls inside its own frame and can be dragged.
// - Double-click outside the blocks (or ⤢) opens it over the whole page, fitted to width and height;
//   scroll or pinch zooms there, drag pans, Esc or × closes.
// - Copy (the ⧉ button or a right-click): the picture as PNG or SVG, or its Mermaid
//   code. The app puts it on the clipboard (message `copyDiagram`).
// - A click on a block (no drag) tells the app which node it was (`diagramNode`), so the
//   editor can put the cursor on its line; a syntax error reports its line
//   (`diagramError`) so the editor can mark it. A double-click on a flowchart block
//   opens a text field over it; Enter sends the new label (`diagramRename`) and the app
//   changes it in the text. A double-click elsewhere opens the full size view.
// - Drag from a flowchart block to another to connect them (`diagramConnect`); the
//   right-click menu of a block also renames, adds a next block, duplicates or deletes
//   it (`diagramNodeAction`). The app makes each change in the text.
// - `highlight(source, id)` outlines the block on the editor's cursor line (in Split).
// - `freeze()` swaps every figure for a plain SVG picture, for HTML export and printing.
// - Drawings are cached by source and colours, so typing elsewhere does not redraw
//   them and the page does not flicker. A diagram being edited keeps its last good
//   picture, dimmed, until the new one is ready; a syntax error is shown under it.
(function () {
  'use strict';
  if (window.__feDiagrams) return;

  var GUTTER = 24;        // free space kept at each window edge for a wide figure
  var MIN_ZOOM = 0.1, MAX_ZOOM = 8;
  var STEP = 1.25;

  var colors = null;      // { dark, background, foreground, muted, accent }
  var themeKey = '';
  var cache = {};         // themeKey + source → { svg, w, h }
  var failed = {};        // themeKey + source → error text
  var lastGood = [];      // figure index → last good drawing (shown while redrawing)
  var zooms = [];         // figure index → zoom (null = fit)
  var queue = [];
  var busy = false;
  var seq = 0;
  var overlay = null;

  // MARK: Colours

  function hex(c) {
    var m = /^#?([0-9a-f]{6})$/i.exec(c || '');
    if (!m) return null;
    var n = parseInt(m[1], 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function mix(a, b, t) {
    var x = hex(a), y = hex(b);
    if (!x || !y) return a;
    var out = '#';
    for (var i = 0; i < 3; i++) {
      var v = Math.round(x[i] + (y[i] - x[i]) * t);
      out += (v < 16 ? '0' : '') + v.toString(16);
    }
    return out;
  }

  function mermaidConfig() {
    var c = colors || { dark: false, background: '#ffffff', foreground: '#1c1c1e', muted: '#6b6b70', accent: '#3399d9' };
    var font = '-apple-system, BlinkMacSystemFont, "Helvetica Neue", system-ui, sans-serif';
    return {
      startOnLoad: false,
      securityLevel: 'strict',
      theme: 'base',
      fontFamily: font,
      // Plain SVG text instead of HTML inside <foreignObject>: the labels are measured
      // and drawn by the same engine, so they are not cut off, and the SVG can be
      // copied into other apps as it is.
      htmlLabels: false,
      // Labels keep the lines the author wrote (<br/>): no automatic wrapping that
      // would split words such as host names in the middle.
      markdownAutoWrap: false,
      flowchart: { htmlLabels: false, useMaxWidth: false, padding: 12, wrappingWidth: 1000 },
      sequence: { useMaxWidth: false },
      gantt: { useMaxWidth: false },
      class: { useMaxWidth: false },
      state: { useMaxWidth: false },
      er: { useMaxWidth: false },
      journey: { useMaxWidth: false },
      themeVariables: {
        darkMode: !!c.dark,
        fontFamily: font,
        fontSize: '15px',
        background: c.background,
        primaryColor: mix(c.background, c.accent, c.dark ? 0.22 : 0.12),
        primaryBorderColor: mix(c.background, c.accent, 0.75),
        primaryTextColor: c.foreground,
        secondaryColor: mix(c.background, c.foreground, 0.08),
        secondaryBorderColor: c.muted,
        secondaryTextColor: c.foreground,
        tertiaryColor: mix(c.background, c.foreground, 0.04),
        tertiaryBorderColor: c.muted,
        tertiaryTextColor: c.foreground,
        clusterBkg: mix(c.background, c.foreground, c.dark ? 0.06 : 0.035),
        clusterBorder: mix(c.background, c.muted, 0.7),
        lineColor: mix(c.background, c.foreground, 0.6),
        textColor: c.foreground,
        titleColor: c.foreground,
        edgeLabelBackground: c.background,
        noteBkgColor: mix(c.background, c.accent, 0.08),
        noteTextColor: c.foreground,
        noteBorderColor: c.muted
      }
    };
  }

  // MARK: Drawing

  function sizeOf(svgText) {
    var vb = /viewBox="\s*([-\d.eE]+)[\s,]+([-\d.eE]+)[\s,]+([\d.eE]+)[\s,]+([\d.eE]+)\s*"/.exec(svgText);
    if (vb) return { w: parseFloat(vb[3]) || 1, h: parseFloat(vb[4]) || 1 };
    return { w: 600, h: 300 };
  }

  function enqueue(job) {
    queue.push(job);
    pump();
  }

  function pump() {
    if (busy || !queue.length) return;
    var job = queue.shift();
    if (cache[job.key]) { settle(job.key); return pump(); }
    if (failed[job.key] != null) { failAll(job.key, failed[job.key]); return pump(); }
    if (!window.mermaid) { failAll(job.key, 'Mermaid is not loaded'); return pump(); }
    busy = true;
    var id = 'fe-mermaid-' + (++seq);
    var done = function () { busy = false; pump(); };
    try {
      window.mermaid.render(id, job.source).then(function (out) {
        var size = sizeOf(out.svg);
        cache[job.key] = { svg: out.svg, w: size.w, h: size.h };
        settle(job.key);
        done();
      }, function (err) {
        cleanup(id);
        failed[job.key] = message(err);
        failAll(job.key, failed[job.key]);
        done();
      });
    } catch (err) {
      cleanup(id);
      failed[job.key] = message(err);
      failAll(job.key, failed[job.key]);
      done();
    }
  }

  function cleanup(id) {
    // Mermaid leaves its scratch element (and sometimes an error picture) in the body.
    ['d' + id, id].forEach(function (x) {
      var el = document.getElementById(x);
      if (el && !el.closest('.fe-diagram')) el.remove();
    });
  }

  function message(err) {
    var s = (err && (err.message || err.str)) || String(err || 'Unknown error');
    return s.replace(/\s+$/, '');
  }

  function figures(key) {
    return Array.prototype.filter.call(document.querySelectorAll('.fe-diagram'), function (f) {
      return f.__key === key;
    });
  }

  function settle(key) {
    var d = cache[key];
    figures(key).forEach(function (fig) {
      lastGood[fig.__index] = d;
      show(fig, d, false);
      setError(fig, null);
    });
  }

  function failAll(key, text) {
    figures(key).forEach(function (fig) {
      if (fig.__drawing) {
        fig.classList.remove('fe-stale');
        fig.classList.add('fe-broken');
      } else {
        fig.querySelector('.fe-canvas').innerHTML = '';
        fig.classList.add('fe-empty');
      }
      setError(fig, text);
      reportError(fig.__source, text);
    });
  }

  /// "Parse error on line 3" counts lines after the --- front matter --- block; the app
  /// gets the line within the whole diagram source (1-based, at most its last line).
  function errorLine(source, text) {
    var m = /line (\d+)/i.exec(text || '');
    if (!m) return 0;
    var lines = source.split('\n');
    var skip = 0;
    if (/^---\s*$/.test(lines[0] || '')) {
      for (var i = 1; i < lines.length; i++) {
        if (/^---\s*$/.test(lines[i])) { skip = i + 1; break; }
      }
    }
    return Math.max(1, Math.min(lines.length, skip + parseInt(m[1], 10)));
  }

  function reportError(source, text) {
    var line = errorLine(source || '', text);
    if (!line) return;
    try { window.webkit.messageHandlers.diagramError.postMessage({ source: source, line: line, message: text }); }
    catch (e) { window.__feLastError = { source: source, line: line }; }
  }

  /// The Mermaid id and label of the block under `target`, if it is one.
  function nodeAt(target, fig) {
    var el = target && target.closest ? target.closest('g.node, g.cluster, [data-id], g[id]') : null;
    var svg = fig.querySelector('svg');
    while (el && svg && svg.contains(el) && el !== svg) {
      var id = el.getAttribute('id') || '';
      var m = /-flowchart-(.+)-\d+$/.exec(id);
      var nodeId = m ? m[1] : (el.getAttribute('data-id') || (el.classList.contains('cluster') ? id.replace(/^fe-mermaid-\d+-/, '') : ''));
      if (nodeId && !/^L_/.test(nodeId) && !/^i\d+$/.test(nodeId)) {
        return { id: nodeId, label: (el.textContent || '').replace(/\s+/g, ' ').trim() };
      }
      el = el.parentElement ? el.parentElement.closest('g.node, g.cluster, [data-id], g[id]') : null;
    }
    // Other diagram kinds: the text that was clicked is enough to find its line.
    var text = target && target.closest ? target.closest('text') : null;
    var label = text ? (text.textContent || '').replace(/\s+/g, ' ').trim() : '';
    return label ? { id: '', label: label } : null;
  }

  function isFlowchart(source) {
    var lines = (source || '').split('\n'), i = 0;
    if (/^---\s*$/.test(lines[0] || '')) {
      for (i = 1; i < lines.length && !/^---\s*$/.test(lines[i]); i++) {}
      i++;
    }
    for (; i < lines.length; i++) {
      var t = lines[i].trim();
      if (!t || t.indexOf('%%') === 0) continue;
      return /^(flowchart|graph)\b/.test(t);
    }
    return false;
  }

  /// A text field over the block; Enter (or clicking away) sends the new label to the
  /// app as `diagramRename`, Esc cancels.
  var renaming = null;
  function startRename(fig, node, target) {
    finishRename(false);
    var el = target.closest('g.node, g.cluster, [data-id]') || target;
    var r = el.getBoundingClientRect();
    var input = document.createElement('input');
    input.type = 'text';
    input.className = 'fe-rename';
    input.value = node.label;
    var width = Math.max(120, r.width + 24);
    input.style.left = Math.max(4, r.left + r.width / 2 - width / 2) + 'px';
    input.style.top = Math.max(4, r.top + r.height / 2 - 15) + 'px';
    input.style.width = width + 'px';
    document.body.appendChild(input);
    renaming = { input: input, source: fig.__source, id: node.id, label: node.label };
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') { e.preventDefault(); finishRename(true); }
      else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); finishRename(false); }
    });
    input.addEventListener('blur', function () { finishRename(true); });
    input.focus();
    input.select();
    tellApp(true); // Esc cancels the rename instead of leaving Preview
  }

  function finishRename(save) {
    if (!renaming) return;
    var r = renaming;
    renaming = null;
    var text = r.input.value.trim();
    r.input.remove();
    if (!overlay) tellApp(false);
    if (!save || !text || text === r.label) return;
    var msg = { source: r.source, id: r.id, text: text };
    try { window.webkit.messageHandlers.diagramRename.postMessage(msg); }
    catch (err) { window.__feLastRename = msg; }
  }

  function setError(fig, text) {
    var box = fig.querySelector('.fe-error');
    if (!text) {
      if (box) box.remove();
      fig.classList.remove('fe-broken', 'fe-empty');
      return;
    }
    if (!box) {
      box = document.createElement('div');
      box.className = 'fe-error';
      fig.appendChild(box);
    }
    box.textContent = 'Mermaid: ' + text;
  }

  function show(fig, d, stale) {
    var canvas = fig.querySelector('.fe-canvas');
    if (fig.__drawing !== d) {
      canvas.innerHTML = d.svg;
      var svg = canvas.querySelector('svg');
      if (svg) {
        svg.removeAttribute('style');
        svg.removeAttribute('width');
        svg.removeAttribute('height');
        svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
      }
      fig.__drawing = d;
    }
    fig.classList.toggle('fe-stale', !!stale);
    layout(fig);
    markCurrent(fig);
  }

  /// The block on the editor's cursor line, outlined in its picture (`highlight`).
  var current = null;
  function sameSource(a, b) { return (a || '').replace(/\s+$/, '') === (b || '').replace(/\s+$/, ''); }
  function blockId(el) {
    var id = el.getAttribute('id') || '';
    var m = /-flowchart-(.+)-\d+$/.exec(id);
    return m ? m[1] : (el.getAttribute('data-id') || '');
  }
  function markCurrent(fig) {
    Array.prototype.forEach.call(fig.querySelectorAll('.fe-current'), function (el) { el.classList.remove('fe-current'); });
    if (!current || !current.id || !sameSource(fig.__source, current.source)) return;
    Array.prototype.forEach.call(fig.querySelectorAll('g.node'), function (el) {
      if (blockId(el) === current.id) el.classList.add('fe-current');
    });
  }
  function highlight(source, id) {
    current = source && id ? { source: source, id: id } : null;
    Array.prototype.forEach.call(document.querySelectorAll('.fe-diagram'), markCurrent);
  }

  // MARK: Figures in the page

  function makeFigure(pre, index, source, key) {
    var fig = document.createElement('div');
    fig.className = 'fe-diagram';
    fig.__index = index;
    fig.__key = key;
    fig.__source = source;
    fig.innerHTML =
      '<div class="fe-tools">' +
        '<button data-act="out" title="Zoom out (⌥-scroll)">−</button>' +
        '<button data-act="fit" title="Fit to width">Fit</button>' +
        '<button data-act="in" title="Zoom in (⌥-scroll)">+</button>' +
        '<button data-act="full" title="Open full size (double-click)">⤢</button>' +
        '<button data-act="copy" title="Copy as PNG, SVG or code (right-click)">⧉</button>' +
      '</div>' +
      '<div class="fe-frame"><div class="fe-canvas"></div></div>';
    pre.parentNode.replaceChild(fig, pre);
    return fig;
  }

  function columnWidth(fig) {
    var parent = fig.parentElement || document.body;
    return parent.clientWidth || document.body.clientWidth;
  }

  /// Width the figure may take: the column, or more of the window for a wide picture.
  function layout(fig) {
    var d = fig.__drawing;
    var frame = fig.querySelector('.fe-frame');
    var svg = fig.querySelector('.fe-canvas svg');
    fig.style.marginLeft = '';
    fig.style.width = '';
    if (!d || !svg) return;
    var col = columnWidth(fig);
    var room = Math.max(col, window.innerWidth - 2 * GUTTER);
    var want = Math.min(d.w, room);
    if (want > col) {
      var parent = fig.parentElement || document.body;
      var parentLeft = parent.getBoundingClientRect().left + (parseFloat(getComputedStyle(parent).paddingLeft) || 0);
      var left = Math.max(GUTTER, (window.innerWidth - want) / 2);
      fig.style.width = want + 'px';
      fig.style.marginLeft = (left - parentLeft) + 'px';
    }
    var box = fig.clientWidth;
    var fit = fitScale(fig, d, box);
    var z = zooms[fig.__index];
    var scale = z == null ? fit : z;
    svg.style.width = (d.w * scale) + 'px';
    svg.style.height = (d.h * scale) + 'px';
    var zoomed = z != null && d.w * scale > box + 1;
    fig.classList.toggle('fe-zoomed', z != null);
    frame.style.maxHeight = z != null ? Math.max(240, window.innerHeight * 0.75) + 'px' : '';
    frame.style.cursor = zoomed || (z != null && frame.scrollHeight > frame.clientHeight) ? 'grab' : '';
    var label = fig.querySelector('[data-act="fit"]');
    if (label) label.textContent = z == null ? 'Fit' : Math.round(scale * 100) + '%';
  }

  /// Alone on the page (a .mmd file), the diagram fits the window both ways, like a
  /// live editor, and a small one is drawn a little larger. In a document it fits the
  /// width and is never enlarged.
  function isSolo(fig) {
    var body = document.body;
    return fig.parentElement === body && body.children.length === 1;
  }

  function fitScale(fig, d, box) {
    if (!isSolo(fig)) return Math.min(1, box / d.w);
    var top = fig.getBoundingClientRect().top + window.scrollY;
    // The page keeps its bottom margin (72px in Split), so no scrollbar appears.
    var margin = parseFloat(getComputedStyle(document.body).marginBottom) || 0;
    var room = Math.max(160, window.innerHeight - top - margin - 8);
    return Math.max(MIN_ZOOM, Math.min(1.5, box / d.w, room / d.h));
  }

  function currentScale(fig) {
    var d = fig.__drawing;
    if (!d) return 1;
    var z = zooms[fig.__index];
    return z == null ? fitScale(fig, d, fig.clientWidth) : z;
  }

  function zoomFigure(fig, factor, clientX, clientY) {
    var d = fig.__drawing;
    if (!d) return;
    var frame = fig.querySelector('.fe-frame');
    var before = currentScale(fig);
    var after = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, before * factor));
    if (after === before) return;
    var r = frame.getBoundingClientRect();
    var px = (clientX == null ? r.width / 2 : clientX - r.left);
    var py = (clientY == null ? r.height / 2 : clientY - r.top);
    var ox = (frame.scrollLeft + px) / before;
    var oy = (frame.scrollTop + py) / before;
    zooms[fig.__index] = after;
    layout(fig);
    frame.scrollLeft = ox * after - px;
    frame.scrollTop = oy * after - py;
  }

  function fitFigure(fig) {
    zooms[fig.__index] = null;
    layout(fig);
  }

  // MARK: Full size view

  function openFull(fig) {
    var d = fig.__drawing;
    if (!d) return;
    closeFull();
    var o = document.createElement('div');
    o.className = 'fe-overlay';
    o.innerHTML =
      '<div class="fe-overlay-stage"><div class="fe-overlay-canvas"></div></div>' +
      '<div class="fe-tools fe-overlay-tools">' +
        '<button data-act="out" title="Zoom out (−)">−</button>' +
        '<button data-act="fit" title="Fit to window (0)">Fit</button>' +
        '<button data-act="in" title="Zoom in (+)">+</button>' +
        '<button data-act="copy" title="Copy as PNG, SVG or code">⧉</button>' +
        '<button data-act="close" title="Close (Esc)">×</button>' +
      '</div>';
    o.querySelector('.fe-overlay-canvas').innerHTML = d.svg;
    var svg = o.querySelector('svg');
    svg.removeAttribute('style');
    svg.removeAttribute('width');
    svg.removeAttribute('height');
    document.documentElement.appendChild(o);
    overlay = { el: o, d: d, svg: svg, scale: 1, x: 0, y: 0, source: fig.__source };
    fitFull();
    tellApp(true);
  }

  function closeFull() {
    if (!overlay) return;
    overlay.el.remove();
    overlay = null;
    tellApp(false);
  }

  // The app leaves Preview on Esc; while the full size view is open, Esc closes it instead.
  function tellApp(open) {
    try { window.webkit.messageHandlers.diagramView.postMessage(open); } catch (e) {}
  }

  function fitFull() {
    if (!overlay) return;
    var vw = window.innerWidth, vh = window.innerHeight;
    var pad = 48;
    var s = Math.min((vw - 2 * pad) / overlay.d.w, (vh - 2 * pad) / overlay.d.h);
    s = Math.min(Math.max(s, MIN_ZOOM), 3);
    overlay.scale = s;
    overlay.x = (vw - overlay.d.w * s) / 2;
    overlay.y = (vh - overlay.d.h * s) / 2;
    placeFull();
  }

  function placeFull() {
    var o = overlay;
    o.svg.style.width = (o.d.w * o.scale) + 'px';
    o.svg.style.height = (o.d.h * o.scale) + 'px';
    var c = o.el.querySelector('.fe-overlay-canvas');
    c.style.left = o.x + 'px';
    c.style.top = o.y + 'px';
    o.el.querySelector('[data-act="fit"]').textContent = Math.round(o.scale * 100) + '%';
  }

  function zoomFull(factor, cx, cy) {
    var o = overlay;
    if (!o) return;
    if (cx == null) { cx = window.innerWidth / 2; cy = window.innerHeight / 2; }
    var s = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, o.scale * factor));
    o.x = cx - (cx - o.x) * (s / o.scale);
    o.y = cy - (cy - o.y) * (s / o.scale);
    o.scale = s;
    placeFull();
  }

  // MARK: Copy and export

  /// Space around a copied or exported picture, so shapes at its edge are not cut.
  var PAD = 12;

  /// The drawing as a picture of its own: natural size plus a margin, the page's background.
  function standaloneSVG(d, responsive) {
    var doc = new DOMParser().parseFromString(d.svg, 'image/svg+xml');
    var svg = doc.documentElement;
    svg.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
    svg.setAttribute('xmlns:xlink', 'http://www.w3.org/1999/xlink');
    var vb = (svg.getAttribute('viewBox') || ('0 0 ' + d.w + ' ' + d.h)).trim().split(/[\s,]+/).map(parseFloat);
    svg.setAttribute('viewBox', [vb[0] - PAD, vb[1] - PAD, vb[2] + 2 * PAD, vb[3] + 2 * PAD].join(' '));
    var w = d.w + 2 * PAD, h = d.h + 2 * PAD;
    if (responsive) {
      svg.setAttribute('width', '100%');
      svg.removeAttribute('height');
      svg.setAttribute('style', 'max-width:' + w + 'px;height:auto');
    } else {
      svg.setAttribute('width', String(w));
      svg.setAttribute('height', String(h));
      svg.setAttribute('style', 'background-color:' + ((colors && colors.background) || '#ffffff'));
    }
    return new XMLSerializer().serializeToString(svg);
  }

  /// PNG at twice the size (sharp on Retina), on the page's background.
  function pngData(d, done) {
    var scale = 2;
    var img = new Image();
    img.onload = function () {
      try {
        var canvas = document.createElement('canvas');
        canvas.width = Math.ceil((d.w + 2 * PAD) * scale);
        canvas.height = Math.ceil((d.h + 2 * PAD) * scale);
        var ctx = canvas.getContext('2d');
        ctx.fillStyle = (colors && colors.background) || '#ffffff';
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
        done(canvas.toDataURL('image/png').replace(/^data:image\/png;base64,/, ''));
      } catch (e) { done(null); }
    };
    img.onerror = function () { done(null); };
    img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(standaloneSVG(d, false));
  }

  function postCopy(type, data) {
    try { window.webkit.messageHandlers.copyDiagram.postMessage({ type: type, data: data }); return true; }
    catch (e) {
      // Outside the app (a browser while testing): the text kinds go to the clipboard.
      if (type !== 'png' && navigator.clipboard) navigator.clipboard.writeText(data);
      window.__feLastCopy = { type: type, data: data };
      return true;
    }
  }

  function copied(fig, text) {
    var host = fig || (overlay && overlay.el);
    if (!host) return;
    var tag = document.createElement('div');
    tag.className = 'fe-copied';
    tag.textContent = text;
    if (!fig) { tag.style.position = 'fixed'; tag.style.top = '16px'; }
    host.appendChild(tag);
    setTimeout(function () { tag.remove(); }, 900);
  }

  function copy(type, d, source, fig) {
    if (type === 'code') { postCopy('code', source); copied(fig, 'Code copied'); return; }
    if (type === 'svg') { postCopy('svg', standaloneSVG(d, false)); copied(fig, 'SVG copied'); return; }
    pngData(d, function (b64) {
      if (b64) { postCopy('png', b64); copied(fig, 'PNG copied'); }
      else copied(fig, 'Could not make a PNG');
    });
  }

  var menu = null;
  function closeCopyMenu() { if (menu) { menu.remove(); menu = null; } }

  function openCopyMenu(d, source, at, fig, extra) {
    closeCopyMenu();
    var m = document.createElement('div');
    m.className = 'fe-menu';
    (extra || []).forEach(function (item) {
      if (!item) { var hr = document.createElement('hr'); m.appendChild(hr); return; }
      var b = document.createElement('button');
      b.textContent = item[0];
      b.addEventListener('click', function (e) {
        e.preventDefault(); e.stopPropagation();
        closeCopyMenu();
        item[1]();
      });
      m.appendChild(b);
    });
    [['png', 'Copy as PNG'], ['svg', 'Copy as SVG'], ['code', 'Copy Mermaid code']].forEach(function (item) {
      var b = document.createElement('button');
      b.textContent = item[1];
      b.addEventListener('click', function (e) {
        e.preventDefault(); e.stopPropagation();
        closeCopyMenu();
        copy(item[0], d, source, fig);
      });
      m.appendChild(b);
    });
    document.documentElement.appendChild(m);
    var x, y;
    if (at && at.getBoundingClientRect) {
      var r = at.getBoundingClientRect();
      x = r.right - m.offsetWidth; y = r.bottom + 4;
    } else { x = at.x; y = at.y; }
    m.style.left = Math.max(4, Math.min(x, window.innerWidth - m.offsetWidth - 4)) + 'px';
    m.style.top = Math.max(4, Math.min(y, window.innerHeight - m.offsetHeight - 4)) + 'px';
    menu = m;
  }

  /// For export: each figure becomes a plain picture (or its code if it did not draw).
  function freeze() {
    closeFull();
    closeCopyMenu();
    Array.prototype.forEach.call(document.querySelectorAll('.fe-diagram'), function (fig) {
      var out;
      if (fig.__drawing && !fig.classList.contains('fe-broken')) {
        out = document.createElement('figure');
        out.className = 'fe-static';
        out.innerHTML = standaloneSVG(fig.__drawing, true);
      } else {
        out = document.createElement('pre');
        var code = document.createElement('code');
        code.className = 'language-mermaid';
        code.textContent = fig.__source || '';
        out.appendChild(code);
      }
      fig.parentNode.replaceChild(out, fig);
    });
    return document.body.innerHTML;
  }

  // MARK: Events (installed once per page; the body is replaced while typing)

  function figureOf(t) { return t && t.closest ? t.closest('.fe-diagram') : null; }

  function act(name, fig, button) {
    if (name === 'copy') {
      if (fig && fig.__drawing) openCopyMenu(fig.__drawing, fig.__source, button, fig);
      else if (overlay) openCopyMenu(overlay.d, overlay.source, button, null);
      return;
    }
    if (overlay && (!fig || name === 'close')) {
      if (name === 'in') zoomFull(STEP);
      else if (name === 'out') zoomFull(1 / STEP);
      else if (name === 'fit') fitFull();
      else if (name === 'close') closeFull();
      return;
    }
    if (!fig) return;
    if (name === 'in') zoomFigure(fig, STEP);
    else if (name === 'out') zoomFigure(fig, 1 / STEP);
    else if (name === 'fit') fitFigure(fig);
    else if (name === 'full') openFull(fig);
  }

  function install() {
    var style = document.createElement('style');
    style.textContent = [
      '.fe-diagram{position:relative;margin:1em 0;box-sizing:border-box;max-width:none}',
      '.fe-frame{overflow:hidden;border-radius:8px;text-align:center}',
      '.fe-diagram.fe-zoomed .fe-frame{overflow:auto;text-align:left;background:rgba(127,127,127,.06)}',
      '.fe-canvas{display:inline-block;line-height:0}',
      '.fe-canvas svg{display:block;max-width:none}',
      '.fe-diagram.fe-stale .fe-canvas{opacity:.45;transition:opacity .2s}',
      '.fe-diagram.fe-broken .fe-canvas{opacity:.35}',
      '.fe-diagram.fe-empty .fe-frame{min-height:0}',
      '.fe-error{font:12px/1.4 ui-monospace,Menlo,monospace;white-space:pre-wrap;color:#d0473e;',
      '  background:rgba(208,71,62,.10);border-radius:6px;padding:8px 10px;margin-top:6px;text-align:left}',
      '.fe-tools{position:absolute;top:6px;right:6px;display:flex;gap:2px;opacity:0;transition:opacity .15s;z-index:2}',
      '.fe-diagram:hover .fe-tools,.fe-diagram.fe-zoomed .fe-tools{opacity:1}',
      '.fe-diagram.fe-empty .fe-tools{display:none}',
      '.fe-tools button{font:12px/1 -apple-system,system-ui,sans-serif;min-width:26px;height:24px;padding:0 7px;',
      '  border:1px solid rgba(127,127,127,.35);border-radius:6px;cursor:pointer;color:inherit;',
      '  background:color-mix(in srgb, Canvas 85%, transparent);-webkit-backdrop-filter:blur(6px);backdrop-filter:blur(6px)}',
      '.fe-tools button:hover{background:rgba(127,127,127,.22)}',
      '.fe-overlay{position:fixed;inset:0;z-index:1000;background:var(--fe-bg,Canvas);overflow:hidden;cursor:grab}',
      '.fe-overlay.fe-dragging,.fe-frame.fe-dragging{cursor:grabbing!important}',
      '.fe-overlay-stage{position:absolute;inset:0}',
      '.fe-overlay-canvas{position:absolute;line-height:0}',
      '.fe-overlay-canvas svg{display:block;max-width:none}',
      '.fe-overlay-tools{opacity:1;top:12px;right:12px;position:fixed}',
      '.fe-menu{position:fixed;z-index:1100;min-width:150px;padding:4px;border-radius:8px;',
      '  font:13px/1.2 -apple-system,system-ui,sans-serif;color:var(--fe-fg,CanvasText);background:var(--fe-bg,Canvas);',
      '  border:1px solid rgba(127,127,127,.35);box-shadow:0 6px 24px rgba(0,0,0,.22)}',
      '.fe-menu button{display:block;width:100%;text-align:left;padding:6px 10px;border:0;border-radius:5px;',
      '  background:none;color:inherit;font:inherit;cursor:pointer}',
      '.fe-menu button:hover{background:rgba(127,127,127,.2)}',
      '.fe-copied{position:absolute;left:50%;top:8px;transform:translateX(-50%);z-index:3;padding:4px 10px;',
      '  border-radius:6px;font:12px/1.2 -apple-system,system-ui,sans-serif;background:rgba(127,127,127,.35);pointer-events:none}',
      '.fe-static{margin:1em 0;text-align:center}',
      '.fe-static svg{max-width:100%;height:auto}',
      '.fe-diagram g.node, .fe-diagram g.cluster > rect{cursor:pointer}',
      '.fe-link{position:fixed;left:0;top:0;width:100vw;height:100vh;pointer-events:none;z-index:4;overflow:visible}',
      '.fe-link line{stroke:#3399d9;stroke-width:2;stroke-dasharray:6 4}',
      '.fe-diagram g.node.fe-link-target > :is(rect,polygon,circle,ellipse,path){stroke:#3399d9!important;stroke-width:3px!important}',
      '.fe-menu hr{border:0;border-top:1px solid rgba(127,127,127,.3);margin:4px 0}',
      '.fe-diagram g.node.fe-current > :is(rect,polygon,circle,ellipse,path){stroke:#f59e0b!important;stroke-width:3px!important}',
      '.fe-rename{position:fixed;z-index:5;height:30px;box-sizing:border-box;padding:4px 8px;border-radius:6px;',
      '  border:2px solid #3399d9;font:14px -apple-system,system-ui,sans-serif;text-align:center;',
      '  background:Canvas;color:CanvasText;outline:none;box-shadow:0 4px 16px rgba(0,0,0,.25)}'
    ].join('\n');
    document.documentElement.appendChild(style);

    document.addEventListener('click', function (e) {
      var b = e.target && e.target.closest && e.target.closest('.fe-tools button');
      if (!b) return;
      e.preventDefault();
      e.stopPropagation();
      act(b.getAttribute('data-act'), figureOf(b), b);
    }, true);

    // A click (not a drag) on a block: the app moves the cursor to its line.
    var press = null;
    document.addEventListener('mousedown', function (e) { press = { x: e.clientX, y: e.clientY }; }, true);
    document.addEventListener('click', function (e) {
      if (e.detail > 1 || overlay || (e.target.closest && e.target.closest('.fe-tools, .fe-menu'))) return;
      if (press && Math.abs(e.clientX - press.x) + Math.abs(e.clientY - press.y) > 4) return;
      var fig = figureOf(e.target);
      if (!fig || !fig.__drawing) return;
      var node = nodeAt(e.target, fig);
      if (!node) return;
      var msg = { source: fig.__source, id: node.id, label: node.label };
      try { window.webkit.messageHandlers.diagramNode.postMessage(msg); }
      catch (err) { window.__feLastNode = msg; }
    });

    // Right-click a diagram: the copy menu instead of the web view's own.
    document.addEventListener('contextmenu', function (e) {
      var fig = figureOf(e.target);
      var d = fig ? fig.__drawing : (overlay && overlay.el.contains(e.target) ? overlay.d : null);
      if (!d) return;
      e.preventDefault();
      var extra = [];
      var boardSource = fig ? fig.__source : overlay.source;
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.openBoard) {
        extra.push(['Open in Excalidraw', function () {
          window.webkit.messageHandlers.openBoard.postMessage({ source: boardSource });
        }]);
      }
      var node = fig && isFlowchart(fig.__source) ? nodeAt(e.target, fig) : null;
      if (node && node.id) {
        var target = e.target, source = fig.__source;
        var send = function (action) {
          return function () {
            var msg = { source: source, id: node.id, action: action };
            try { window.webkit.messageHandlers.diagramNodeAction.postMessage(msg); }
            catch (err) { window.__feLastAction = msg; }
          };
        };
        extra = [
          ['Rename…', function () { startRename(fig, node, target); }],
          ['Add Next Block', send('next')],
          ['Duplicate', send('duplicate')],
          ['Delete', send('delete')],
          null
        ].concat(extra);
      }
      if (extra.length && extra[extra.length - 1]) extra.push(null);
      openCopyMenu(d, fig ? fig.__source : overlay.source, { x: e.clientX, y: e.clientY }, fig, extra);
    });
    document.addEventListener('mousedown', function (e) {
      if (menu && !menu.contains(e.target)) closeCopyMenu();
    }, true);
    window.addEventListener('scroll', closeCopyMenu, true);
    window.addEventListener('scroll', function (e) { if (renaming && e.target !== renaming.input) finishRename(false); }, true);

    document.addEventListener('dblclick', function (e) {
      if (overlay) {
        if (!(e.target.closest && e.target.closest('.fe-tools'))) fitFull();
        return;
      }
      var fig = figureOf(e.target);
      if (!fig || (e.target.closest && e.target.closest('.fe-tools, .fe-rename'))) return;
      e.preventDefault();
      var sel = window.getSelection();
      if (sel) sel.removeAllRanges();
      // A block of a flowchart: rename it in place. Elsewhere: full size.
      var node = fig.__drawing && isFlowchart(fig.__source) ? nodeAt(e.target, fig) : null;
      if (node && node.id) { startRename(fig, node, e.target); return; }
      openFull(fig);
    });

    // ⌥-scroll (or a pinch, which arrives as ctrl-scroll) zooms a figure; plain scroll
    // keeps scrolling the page. In the full size view any scroll zooms.
    document.addEventListener('wheel', function (e) {
      var factor = Math.exp(-e.deltaY * (e.deltaMode === 1 ? 0.05 : 0.0025));
      if (overlay) {
        e.preventDefault();
        zoomFull(factor, e.clientX, e.clientY);
        return;
      }
      if (!(e.altKey || e.ctrlKey)) return;
      var fig = figureOf(e.target);
      if (!fig || !fig.__drawing) return;
      e.preventDefault();
      zoomFigure(fig, factor, e.clientX, e.clientY);
    }, { passive: false });

    // Safari's own pinch events.
    var pinch = null;
    document.addEventListener('gesturestart', function (e) {
      var fig = overlay ? null : figureOf(e.target);
      if (!overlay && !fig) return;
      e.preventDefault();
      pinch = { fig: fig, last: 1 };
    });
    document.addEventListener('gesturechange', function (e) {
      if (!pinch) return;
      e.preventDefault();
      var f = e.scale / pinch.last;
      pinch.last = e.scale;
      if (overlay) zoomFull(f, e.clientX, e.clientY);
      else if (pinch.fig) zoomFigure(pinch.fig, f, e.clientX, e.clientY);
    });
    document.addEventListener('gestureend', function () { pinch = null; });

    // Drag from a flowchart block to another: the app adds an arrow between them
    // (`diagramConnect`). A drag that starts outside the blocks pans as before.
    var link = null;
    document.addEventListener('mousedown', function (e) {
      if (e.button !== 0 || overlay || renaming || (e.target.closest && e.target.closest('.fe-tools, .fe-menu'))) return;
      var fig = figureOf(e.target);
      if (!fig || !fig.__drawing || !isFlowchart(fig.__source)) return;
      var el = e.target.closest && e.target.closest('g.node');
      var node = el ? nodeAt(e.target, fig) : null;
      if (!node || !node.id) return;
      link = { fig: fig, from: node.id, el: el, x: e.clientX, y: e.clientY, line: null, over: null };
      e.preventDefault();
      e.stopPropagation(); // not a pan
    }, true);
    document.addEventListener('mousemove', function (e) {
      if (!link) return;
      if (!link.line) {
        if (Math.abs(e.clientX - link.x) + Math.abs(e.clientY - link.y) < 6) return;
        var r = link.el.getBoundingClientRect();
        link.x = r.left + r.width / 2; link.y = r.top + r.height / 2;
        var ns = 'http://www.w3.org/2000/svg';
        var svg = document.createElementNS(ns, 'svg');
        svg.setAttribute('class', 'fe-link');
        var line = document.createElementNS(ns, 'line');
        svg.appendChild(line);
        document.documentElement.appendChild(svg);
        link.svg = svg; link.line = line;
      }
      link.line.setAttribute('x1', link.x); link.line.setAttribute('y1', link.y);
      link.line.setAttribute('x2', e.clientX); link.line.setAttribute('y2', e.clientY);
      var under = document.elementFromPoint(e.clientX, e.clientY);
      var el = under && under.closest ? under.closest('g.node') : null;
      if (el && (figureOf(el) !== link.fig || el === link.el)) el = null;
      if (link.over !== el) {
        if (link.over) link.over.classList.remove('fe-link-target');
        if (el) el.classList.add('fe-link-target');
        link.over = el;
      }
    }, true);
    document.addEventListener('mouseup', function (e) {
      if (!link) return;
      var l = link;
      link = null;
      if (l.svg) l.svg.remove();
      if (l.over) l.over.classList.remove('fe-link-target');
      if (!l.line || !l.over) return;
      var to = nodeAt(l.over, l.fig);
      if (!to || !to.id || to.id === l.from) return;
      var msg = { source: l.fig.__source, from: l.from, to: to.id };
      try { window.webkit.messageHandlers.diagramConnect.postMessage(msg); }
      catch (err) { window.__feLastConnect = msg; }
    }, true);

    // Drag to pan: the full size view, or a zoomed figure inside its frame.
    var drag = null;
    document.addEventListener('mousedown', function (e) {
      if (e.button !== 0 || (e.target.closest && e.target.closest('.fe-tools, .fe-menu'))) return;
      if (overlay) {
        drag = { el: overlay.el, x: e.clientX, y: e.clientY, ox: overlay.x, oy: overlay.y };
      } else {
        var fig = figureOf(e.target);
        if (!fig || zooms[fig.__index] == null) return;
        var frame = fig.querySelector('.fe-frame');
        drag = { el: frame, frame: frame, x: e.clientX, y: e.clientY, sl: frame.scrollLeft, st: frame.scrollTop };
      }
      drag.el.classList.add('fe-dragging');
      e.preventDefault();
    });
    document.addEventListener('mousemove', function (e) {
      if (!drag) return;
      var dx = e.clientX - drag.x, dy = e.clientY - drag.y;
      if (drag.frame) {
        drag.frame.scrollLeft = drag.sl - dx;
        drag.frame.scrollTop = drag.st - dy;
      } else if (overlay) {
        overlay.x = drag.ox + dx;
        overlay.y = drag.oy + dy;
        placeFull();
      }
    });
    document.addEventListener('mouseup', function () {
      if (drag) drag.el.classList.remove('fe-dragging');
      drag = null;
    });

    document.addEventListener('keydown', function (e) {
      if (menu && e.key === 'Escape') { closeCopyMenu(); e.preventDefault(); e.stopPropagation(); return; }
      if (!overlay) return;
      if (e.key === 'Escape') { closeFull(); e.preventDefault(); e.stopPropagation(); }
      else if (e.key === '+' || e.key === '=') { zoomFull(STEP); e.preventDefault(); }
      else if (e.key === '-' || e.key === '−') { zoomFull(1 / STEP); e.preventDefault(); }
      else if (e.key === '0') { fitFull(); e.preventDefault(); }
    }, true);

    var pending = 0;
    window.addEventListener('resize', function () {
      cancelAnimationFrame(pending);
      pending = requestAnimationFrame(function () {
        Array.prototype.forEach.call(document.querySelectorAll('.fe-diagram'), layout);
        if (overlay) fitFull();
      });
    });
  }

  // MARK: API for the app

  window.__feDiagrams = {
    /// Colours of the page (the same as the preview's); call once per page load.
    configure: function (c) {
      colors = c;
      themeKey = JSON.stringify(c) + '\n';
      document.documentElement.style.setProperty('--fe-bg', c.background);
      document.documentElement.style.setProperty('--fe-fg', c.foreground);
      if (window.mermaid) window.mermaid.initialize(mermaidConfig());
    },

    /// Replace every ```mermaid block in the body with its figure.
    refresh: function () {
      if (!themeKey && window.mermaid) this.configure({ dark: false, background: '#ffffff',
        foreground: '#1c1c1e', muted: '#6b6b70', accent: '#3399d9' });
      var blocks = document.querySelectorAll('pre > code.language-mermaid');
      var used = {};
      Array.prototype.forEach.call(blocks, function (code, index) {
        var source = code.textContent;
        var key = themeKey + source;
        var fig = makeFigure(code.parentNode, index, source, key);
        if (cache[key]) {
          show(fig, cache[key], false);
          lastGood[index] = cache[key];
        } else {
          if (lastGood[index]) show(fig, lastGood[index], true);
          if (failed[key] != null) failAll(key, failed[key]);
          else if (!used[key]) enqueue({ key: key, source: source });
        }
        used[key] = true;
      });
      lastGood.length = blocks.length;
      zooms.length = blocks.length;
      if (overlay && !overlay.el.isConnected) { overlay = null; tellApp(false); }
      return blocks.length;
    },

    /// For tests: how many figures are drawn, waiting, broken.
    /// Close the full size view (the app's Esc).
    close: function () { finishRename(false); closeFull(); closeCopyMenu(); },

    /// Plain pictures instead of figures; returns the body's HTML (export, print).
    freeze: freeze,

    /// For tests: the error line for a source and Mermaid's message.
    errorLine: errorLine,
    highlight: highlight,

    /// Drawings still to make (0 when every figure is ready).
    pending: function () { return queue.length + (busy ? 1 : 0); },

    status: function () {
      var figs = document.querySelectorAll('.fe-diagram');
      var s = { figures: figs.length, drawn: 0, stale: 0, errors: 0, pending: queue.length + (busy ? 1 : 0) };
      Array.prototype.forEach.call(figs, function (f) {
        if (f.__drawing && !f.classList.contains('fe-stale') && !f.classList.contains('fe-broken')) s.drawn++;
        if (f.classList.contains('fe-stale')) s.stale++;
        if (f.querySelector('.fe-error')) s.errors++;
      });
      return s;
    }
  };

  install();
})();
