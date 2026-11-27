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
// - Double-click (or ⤢) opens it over the whole page, fitted to width and height;
//   scroll or pinch zooms there, drag pans, Esc or × closes.
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
    });
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
        '<button data-act="close" title="Close (Esc)">×</button>' +
      '</div>';
    o.querySelector('.fe-overlay-canvas').innerHTML = d.svg;
    var svg = o.querySelector('svg');
    svg.removeAttribute('style');
    svg.removeAttribute('width');
    svg.removeAttribute('height');
    document.documentElement.appendChild(o);
    overlay = { el: o, d: d, svg: svg, scale: 1, x: 0, y: 0 };
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

  // MARK: Events (installed once per page; the body is replaced while typing)

  function figureOf(t) { return t && t.closest ? t.closest('.fe-diagram') : null; }

  function act(name, fig) {
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
      '.fe-overlay-tools{opacity:1;top:12px;right:12px;position:fixed}'
    ].join('\n');
    document.documentElement.appendChild(style);

    document.addEventListener('click', function (e) {
      var b = e.target && e.target.closest && e.target.closest('.fe-tools button');
      if (!b) return;
      e.preventDefault();
      e.stopPropagation();
      act(b.getAttribute('data-act'), figureOf(b));
    }, true);

    document.addEventListener('dblclick', function (e) {
      if (overlay) {
        if (!(e.target.closest && e.target.closest('.fe-tools'))) fitFull();
        return;
      }
      var fig = figureOf(e.target);
      if (!fig || (e.target.closest && e.target.closest('.fe-tools'))) return;
      e.preventDefault();
      var sel = window.getSelection();
      if (sel) sel.removeAllRanges();
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

    // Drag to pan: the full size view, or a zoomed figure inside its frame.
    var drag = null;
    document.addEventListener('mousedown', function (e) {
      if (e.button !== 0 || (e.target.closest && e.target.closest('.fe-tools'))) return;
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
    close: function () { closeFull(); },

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
