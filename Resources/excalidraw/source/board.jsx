// FocusEdit Excalidraw board, built into Resources/excalidraw/board.js (see README.md there).
import React from 'react';
import { createRoot } from 'react-dom/client';
import {
  Excalidraw, MainMenu, exportToSvg, exportToBlob, convertToExcalidrawElements,
  serializeAsJSON, restore, getSceneVersion,
} from '@excalidraw/excalidraw';
import { parseMermaidToExcalidraw } from '@excalidraw/mermaid-to-excalidraw';

let api = null;
let dark = false;
let savedVersion = -1;
let lastVersion = -1;
const pending = [];

function post(name, body) {
  try { window.webkit.messageHandlers[name].postMessage(body); }
  catch (e) { (window.__feBoardLog = window.__feBoardLog || []).push([name, body]); }
}

function whenReady(fn) { if (api) fn(); else pending.push(fn); }

function scene() {
  return { elements: api.getSceneElements(), appState: api.getAppState(), files: api.getFiles() };
}

function exportOptions() {
  const s = scene();
  return {
    elements: s.elements, files: s.files,
    appState: { ...s.appState, exportBackground: true, exportWithDarkMode: false, exportScale: 2,
                viewBackgroundColor: '#ffffff' },
    exportPadding: 16,
  };
}

function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result).replace(/^data:[^,]*,/, ''));
    r.onerror = reject;
    r.readAsDataURL(blob);
  });
}

/// Mermaid measured its labels in its own font; the hand-drawn one is wider. Each label
/// is measured again and gets the room it needs (its box grows around its centre), so
/// no text is cut off or wrapped mid-word.
async function fitTexts(shapes) {
  try { await document.fonts.load('16px Excalifont'); } catch (e) {}
  const ctx = document.createElement('canvas').getContext('2d');
  const byId = new Map(shapes.map((e) => [e.id, e]));
  for (const t of shapes) {
    if (t.type !== 'text') continue;
    const text = t.originalText || t.text;
    const lines = text.split('\n');
    ctx.font = `${t.fontSize}px Excalifont, Xiaolai, sans-serif`;
    const need = Math.ceil(Math.max(...lines.map((l) => ctx.measureText(l).width))) + 2;
    const height = lines.length * t.fontSize * (t.lineHeight || 1.25);
    const c = t.containerId ? byId.get(t.containerId) : null;
    if (c) {
      const pad = 12;
      if (need + 2 * pad > c.width) { const grow = need + 2 * pad - c.width; c.x -= grow / 2; c.width += grow; }
      if (height + 2 * pad > c.height) { const grow = height + 2 * pad - c.height; c.y -= grow / 2; c.height += grow; }
      t.text = text;
      t.width = need;
      t.height = height;
      t.x = c.x + (c.width - need) / 2;
      if (c.type !== 'rectangle' || !t.verticalAlign || t.verticalAlign === 'middle') t.y = c.y + (c.height - height) / 2;
    } else if (need > t.width) {
      t.x -= (need - t.width) / 2;
      t.width = need;
      t.text = text;
    }
  }
}

window.__feBoard = {
  /// A saved .excalidraw file (JSON text), or '' for an empty board.
  load(json) {
    whenReady(() => {
      let data = { elements: [], appState: {}, files: {} };
      if (json && json.trim()) data = JSON.parse(json);
      const r = restore(data, null, null);
      api.updateScene({ elements: r.elements, appState: { ...r.appState, theme: dark ? 'dark' : 'light' } });
      if (r.files) api.addFiles(Object.values(r.files));
      api.history && api.history.clear && api.history.clear();
      api.scrollToContent(r.elements, { fitToContent: true });
      savedVersion = getSceneVersion(api.getSceneElementsIncludingDeleted());
      post('boardChanged', false);
    });
  },
  /// A Mermaid diagram turned into editable shapes, added to the board.
  async fromMermaid(source) {
    await new Promise(whenReady);
    try {
      const { elements, files } = await parseMermaidToExcalidraw(source, { themeVariables: { fontSize: '20px' } });
      // Mermaid's <br/> line breaks become real ones; HTML entities become characters.
      const clean = (t) => t.replace(/<br\s*\/?>/gi, '\n').replace(/#quot;/g, '"').replace(/&amp;/g, '&');
      for (const el of elements) {
        // Laid out for 20px text, drawn at 16px: the hand-drawn font is wider than Mermaid's.
        if (typeof el.text === 'string') { el.text = clean(el.text); el.fontSize = 16; }
        if (el.label && typeof el.label.text === 'string') { el.label.text = clean(el.label.text); el.label.fontSize = 16; }
      }
      const shapes = convertToExcalidrawElements(elements, { regenerateIds: true });
      await fitTexts(shapes);
      api.updateScene({ elements: [...api.getSceneElements(), ...shapes] });
      if (files) api.addFiles(Object.values(files));
      api.scrollToContent(shapes, { fitToContent: true });
      return { ok: true, count: shapes.length };
    } catch (e) {
      return { ok: false, error: String(e && e.message || e) };
    }
  },
  /// The board as .excalidraw JSON; marks it saved.
  save() {
    const s = scene();
    savedVersion = getSceneVersion(api.getSceneElementsIncludingDeleted());
    post('boardChanged', false);
    return serializeAsJSON(s.elements, s.appState, s.files, 'local');
  },
  async svg() {
    const svg = await exportToSvg(exportOptions());
    return svg.outerHTML;
  },
  async png() {
    const blob = await exportToBlob({ ...exportOptions(), mimeType: 'image/png' });
    return blobToBase64(blob);
  },
  setTheme(isDark) {
    dark = !!isDark;
    whenReady(() => api.updateScene({ appState: { theme: dark ? 'dark' : 'light' } }));
  },
  isEmpty() { return !api || api.getSceneElements().length === 0; },
  ready() { return !!api; },
};

function App() {
  return React.createElement(Excalidraw, {
    excalidrawAPI: (a) => { api = a; pending.splice(0).forEach((f) => f()); },
    theme: dark ? 'dark' : 'light',
    UIOptions: { canvasActions: { loadScene: false, saveToActiveFile: false, export: false, saveAsImage: false } },
    onChange: (elements) => {
      const v = getSceneVersion(elements);
      if (v === lastVersion) return;
      lastVersion = v;
      if (savedVersion >= 0) post('boardChanged', v !== savedVersion);
    },
  }, React.createElement(MainMenu, null,
    React.createElement(MainMenu.DefaultItems.ClearCanvas),
    React.createElement(MainMenu.DefaultItems.ToggleTheme),
    React.createElement(MainMenu.DefaultItems.ChangeCanvasBackground),
    React.createElement(MainMenu.DefaultItems.Help)));
}

createRoot(document.getElementById('board')).render(React.createElement(App));
