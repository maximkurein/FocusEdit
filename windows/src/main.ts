// FocusEdit for Windows (experimental) — app shell: document lifecycle,
// toolbar, keyboard shortcuts, title and word count.

import "./styles.css";
import type { Text } from "@codemirror/state";
import { type DocKind, kindForPath } from "./completion";
import { Editor, type LineSeparator } from "./editor";
import { renderHints } from "./hints";
import * as platform from "./platform";
import {
  columnWidth,
  fontStack,
  fonts,
  focusModes,
  loadSettings,
  next,
  saveSettings,
  sizes,
  themeNames,
} from "./settings";
import { applyTheme } from "./themes";

const settings = loadSettings();
const mod = platform.modKey;

interface DocState {
  path: string | null;
  name: string;
  kind: DocKind;
  dirty: boolean;
  bom: boolean;
}

const doc: DocState = { path: null, name: "Untitled", kind: "plain", dirty: false, bom: false };

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const nameEl = $("doc-name");
const statsEl = $("doc-stats");
const hintsEl = $("hints");

const editor = new Editor($("editor"), {
  settings,
  hintsKey: platform.isMac ? "⌘?" : "F1",
  onChange: (text) => {
    if (!doc.dirty) {
      doc.dirty = true;
      updateTitle();
    }
    updateStats(text);
  },
});

// ---------------------------------------------------------------- appearance

function applyAppearance(): void {
  applyTheme(settings.theme);
  const root = document.documentElement.style;
  root.setProperty("--column", `${columnWidth[settings.size]}px`);
  root.setProperty("--editor-font", fontStack[settings.font]);
  root.setProperty("--mono-font", fontStack.monospace);
  root.setProperty("--font-size", `${settings.fontSize}px`);

  const focusLabel = { off: "Off", sentence: "Sentence", paragraph: "Paragraph" }[settings.focusMode];
  $("focus-label").textContent = focusLabel;
  $("btn-focus").classList.toggle("on", settings.focusMode !== "off");
  $("btn-focus").title = `Focus highlighting: ${focusLabel} — click to change`;
  $("btn-typewriter").classList.toggle("on", settings.typewriter);
  $("btn-theme").title = `Theme: ${settings.theme} — click to change`;
  $("btn-size").title = `Column width: ${settings.size} — click to change`;
  $("btn-font").title = `Font: ${settings.font} — click to change`;
}

function changeSettings(update: () => void): void {
  update();
  saveSettings(settings);
  applyAppearance();
  editor.applySettings();
}

// ------------------------------------------------------------------- title

function updateTitle(): void {
  nameEl.textContent = (doc.dirty ? "• " : "") + doc.name;
  void platform.setWindowTitle(`${doc.dirty ? "• " : ""}${doc.name} — FocusEdit`);
  (window as unknown as { focusEditDirty: boolean }).focusEditDirty = doc.dirty;
}

function updateStats(text: Text): void {
  const words = text.toString().split(/\s+/).filter(Boolean).length;
  const minutes = Math.max(1, Math.ceil(words / 200));
  statsEl.textContent = words === 0 ? "" : `${words} word${words === 1 ? "" : "s"} · ${minutes} min read`;
}

// --------------------------------------------------------------- documents

const EXTENSION: Record<DocKind, string> = { markdown: ".md", fountain: ".fountain", plain: ".txt" };

function load(text: string, path: string | null, name: string): void {
  const bom = text.startsWith("﻿");
  const body = bom ? text.slice(1) : text;
  const separator: LineSeparator = body.includes("\r\n") ? "\r\n" : "\n";
  Object.assign(doc, { path, name, kind: kindForPath(path ?? name), dirty: false, bom });
  editor.load(body, doc.kind, separator);
  updateTitle();
  updateStats(editor.view.state.doc);
  renderHints(hintsEl, doc.kind, mod);
  editor.focusEditor();
}

async function canDiscard(): Promise<boolean> {
  return !doc.dirty || platform.confirmDiscard(doc.name);
}

async function newDocument(): Promise<void> {
  if (await canDiscard()) load("", null, "Untitled");
}

async function openDocument(): Promise<void> {
  if (!(await canDiscard())) return;
  const file = await platform.openFile();
  if (file) load(file.text, file.path, file.name);
}

async function openPath(path: string): Promise<void> {
  try {
    const file = await platform.readFile(path);
    load(file.text, file.path, file.name);
  } catch (error) {
    await platform.showError(`Could not open ${platform.baseName(path)}: ${String(error)}`);
  }
}

function contents(): string {
  return (doc.bom ? "﻿" : "") + editor.text;
}

async function save(): Promise<void> {
  if (!doc.path) return saveAs();
  if (await platform.writeFile(doc.path, contents())) markSaved();
}

async function saveAs(): Promise<void> {
  const suggested = /\.[^.]+$/.test(doc.name) ? doc.name : doc.name + EXTENSION[doc.kind];
  const path = await platform.chooseSavePath(suggested, contents());
  if (path === null) {
    if (!platform.isTauri) markSaved(); // browser fallback downloaded the file
    return;
  }
  if (!(await platform.writeFile(path, contents()))) return;
  doc.path = path;
  doc.name = platform.baseName(path);
  // Untitled → notes.md switches highlighting and list continuation at once.
  doc.kind = kindForPath(path);
  editor.setKind(doc.kind);
  renderHints(hintsEl, doc.kind, mod);
  markSaved();
}

function markSaved(): void {
  doc.dirty = false;
  updateTitle();
}

// ------------------------------------------------------------------- hints

function toggleHints(show = hintsEl.hidden): void {
  hintsEl.hidden = !show;
  $("btn-hints").classList.toggle("on", show);
  if (!show) editor.focusEditor();
}

// ----------------------------------------------------------------- toolbar

const actions: Record<string, () => void> = {
  "btn-open": () => void openDocument(),
  "btn-save": () => void save(),
  "btn-focus": () => changeSettings(() => (settings.focusMode = next(focusModes, settings.focusMode))),
  "btn-typewriter": () => changeSettings(() => (settings.typewriter = !settings.typewriter)),
  "btn-theme": () => changeSettings(() => (settings.theme = next(themeNames, settings.theme))),
  "btn-size": () => changeSettings(() => (settings.size = next(sizes, settings.size))),
  "btn-font": () => changeSettings(() => (settings.font = next(fonts, settings.font))),
  "btn-fullscreen": () => void platform.toggleFullscreen(),
  "btn-hints": () => toggleHints(),
};

for (const [id, run] of Object.entries(actions)) {
  const button = $(id);
  button.addEventListener("click", () => {
    run();
    if (id !== "btn-hints") editor.focusEditor();
  });
  // Show the platform's modifier in tooltips (⌘ on macOS test builds).
  button.title = button.title.replaceAll("Ctrl+", mod);
}

// ----------------------------------------------------------------- shortcuts

function setFontSize(delta: number): void {
  changeSettings(() => (settings.fontSize = Math.min(32, Math.max(12, settings.fontSize + delta))));
}

window.addEventListener(
  "keydown",
  (e) => {
    const cmd = platform.isMac ? e.metaKey : e.ctrlKey;
    const key = e.key.toLowerCase();
    let handled = true;
    if (cmd && e.shiftKey && key === "s") void saveAs();
    else if (cmd && key === "s") void save();
    else if (cmd && key === "o") void openDocument();
    else if (cmd && key === "n") void newDocument();
    else if (cmd && key === "t") actions["btn-typewriter"]();
    else if (cmd && (key === "=" || key === "+")) setFontSize(1);
    else if (cmd && key === "-") setFontSize(-1);
    else if (e.key === "F1" || (cmd && e.key === "?")) toggleHints();
    else if (e.key === "F11" || (platform.isMac && e.metaKey && e.ctrlKey && key === "f")) void platform.toggleFullscreen();
    else if (e.key === "Escape" && !hintsEl.hidden) toggleHints(false);
    // A reload would throw away the document: swallow the WebView's refresh keys.
    else if (e.key === "F5" || (cmd && key === "r")) handled = true;
    else handled = false;
    if (handled) {
      e.preventDefault();
      e.stopPropagation();
    }
  },
  { capture: true },
);

// ------------------------------------------------------------------- start

applyAppearance();
load("", null, "Untitled");

void platform.onCloseRequested(async () => !doc.dirty || platform.confirmDiscard(doc.name));
void platform.startupFile().then((path) => {
  if (path) void openPath(path);
});

// Small hook for scripted checks (scripts/snapshot.mjs).
(window as unknown as { focusEdit: unknown }).focusEdit = {
  load: (text: string, name: string) => load(text, null, name),
  editor,
  settings,
};
