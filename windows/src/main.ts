// FocusEdit for Windows (experimental) — app shell: document lifecycle,
// toolbar, keyboard shortcuts, title and word count.

import "./styles.css";
import type { Text } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { type DocKind, kindForPath } from "./completion";
import { Editor, type LineSeparator } from "./editor";
import { appendAbout, renderHints } from "./hints";
import { renderMarkdown } from "./markdown-html";
import type { VimAction } from "./vim";
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

const PROJECT_URL = "https://github.com/maximkurein/FocusEdit";

const settings = loadSettings();
const mod = platform.modKey;

interface DocState {
  path: string | null;
  name: string;
  kind: DocKind;
  dirty: boolean;
  bom: boolean;
}

// Edit → Split (editor and live preview side by side) → Preview (reading view).
type ViewMode = "edit" | "split" | "preview";
const viewModes: ViewMode[] = ["edit", "split", "preview"];
let view: ViewMode = "edit";

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
    schedulePreview();
  },
  vim: { coach: $("vim-coach"), perform: (action) => void performVim(action) },
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
  $("btn-vim").classList.toggle("on", settings.vim);
  $("btn-vim").title = settings.vim ? "Vim mode is on — click (or :novim) to turn it off" : "Vim mode: learn Vim as you write";
  $("btn-theme").title = `Theme: ${settings.theme} — click to change`;
  $("btn-size").title = `Column width: ${settings.size} — click to change`;
  $("btn-font").title = `Font: ${settings.font} — click to change`;
}

function changeSettings(update: () => void): void {
  update();
  saveSettings(settings);
  applyAppearance();
  editor.applySettings();
  editor.setVim(settings.vim);
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
  renderHelp();
  applyView();
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

/** A file dropped on the window: ask before discarding unsaved changes, then open it. */
async function openDropped(file: platform.OpenedFile): Promise<void> {
  if (await canDiscard()) load(file.text, file.path, file.name);
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
  renderHelp();
  applyView();
  markSaved();
}

function markSaved(): void {
  doc.dirty = false;
  updateTitle();
}

// ------------------------------------------------------------------- hints

function renderHelp(): void {
  renderHints(hintsEl, doc.kind, mod);
  appendAbout(hintsEl, __APP_VERSION__, () => void platform.openUrl(PROJECT_URL));
}

function toggleHints(show = hintsEl.hidden): void {
  hintsEl.hidden = !show;
  $("btn-hints").classList.toggle("on", show);
  if (!show) editor.focusEditor();
}

// ----------------------------------------------------------------- preview

const previewEl = $("preview");
const viewLabels: Record<ViewMode, string> = { edit: "Edit", split: "Split", preview: "Preview" };
let previewTimer = 0;

/** Fountain scripts are not Markdown; everything else can be previewed. */
const previewable = () => doc.kind !== "fountain";

function renderPreview(): void {
  previewEl.innerHTML = renderMarkdown(editor.text);
}

function schedulePreview(): void {
  if (view === "edit") return;
  window.clearTimeout(previewTimer);
  previewTimer = window.setTimeout(renderPreview, 120);
}

// In Split view scrolling either pane scrolls the other. The pane that was just
// moved by code ignores the scroll event that causes, or the two would chase each other.
const quiet = { editor: 0, preview: 0 };
const hold = (pane: keyof typeof quiet) => void (quiet[pane] = performance.now() + 100);
const maxScroll = (el: HTMLElement) => Math.max(0, el.scrollHeight - el.clientHeight);
const scrollRatio = (el: HTMLElement) => (maxScroll(el) > 0 ? el.scrollTop / maxScroll(el) : 0);

/** Put the preview at the same relative place as the editor (or its cursor). */
function syncPreviewScroll(fromCursor = false): void {
  if (view === "edit") return;
  const state = editor.view.state;
  const ratio = fromCursor
    ? (state.doc.lineAt(state.selection.main.head).number - 1) / Math.max(1, state.doc.lines - 1)
    : scrollRatio(editor.view.scrollDOM);
  hold("preview");
  previewEl.scrollTop = ratio * maxScroll(previewEl);
}

/** Put the editor at the same relative place as the preview. */
function syncEditorScroll(): void {
  const scroller = editor.view.scrollDOM;
  hold("editor");
  scroller.scrollTop = scrollRatio(previewEl) * maxScroll(scroller);
}

/** After reading in the preview: continue editing where the reading stopped. */
function moveCaretTo(ratio: number): void {
  const doc = editor.view.state.doc;
  const line = doc.line(1 + Math.round(ratio * (doc.lines - 1)));
  editor.view.dispatch({
    selection: { anchor: line.from },
    effects: EditorView.scrollIntoView(line.from, { y: "center" }),
  });
}

function applyView(): void {
  if (!previewable()) view = "edit";
  document.body.dataset.view = view;
  previewEl.hidden = view === "edit";
  $("view-label").textContent = viewLabels[view];
  const button = $<HTMLButtonElement>("btn-view");
  button.classList.toggle("on", view !== "edit");
  button.disabled = !previewable();
  if (view !== "edit") renderPreview();
}

function setView(mode: ViewMode): void {
  if (mode !== "edit" && !previewable()) return;
  const readingAt = view === "preview" ? scrollRatio(previewEl) : null;
  view = mode;
  applyView();
  syncPreviewScroll(mode === "preview");
  if (mode === "preview") {
    previewEl.focus();
    return;
  }
  if (readingAt !== null) moveCaretTo(readingAt);
  editor.focusEditor();
}

editor.view.scrollDOM.addEventListener("scroll", () => {
  if (view === "split" && performance.now() >= quiet.editor) syncPreviewScroll();
});
previewEl.addEventListener("scroll", () => {
  if (view === "split" && performance.now() >= quiet.preview) syncEditorScroll();
});

// Links in the preview open in the browser; the window itself never navigates.
previewEl.addEventListener("click", (e) => {
  const link = (e.target as Element).closest("a");
  if (!link) return;
  e.preventDefault();
  const href = link.getAttribute("href");
  if (href) void platform.openUrl(href);
});

// --------------------------------------------------------------------- vim

async function performVim(action: VimAction): Promise<void> {
  switch (action) {
    case "save":
      return save();
    case "close":
      return platform.closeWindow(); // the close guard asks about unsaved changes
    case "saveAndClose":
      await save();
      if (!doc.dirty) await platform.closeWindow();
      return;
    case "discardAndClose":
      doc.dirty = false;
      return platform.closeWindow();
    case "help":
      return toggleHints(true);
    case "exitVim":
      changeSettings(() => (settings.vim = false));
      editor.focusEditor();
  }
}

// ----------------------------------------------------------------- toolbar

const actions: Record<string, () => void> = {
  "btn-open": () => void openDocument(),
  "btn-save": () => void save(),
  "btn-focus": () => changeSettings(() => (settings.focusMode = next(focusModes, settings.focusMode))),
  "btn-view": () => setView(next(viewModes, view)),
  "btn-typewriter": () => changeSettings(() => (settings.typewriter = !settings.typewriter)),
  "btn-vim": () => changeSettings(() => (settings.vim = !settings.vim)),
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
    else if (cmd && e.shiftKey && key === "p") actions["btn-view"]();
    else if (cmd && key === "t") actions["btn-typewriter"]();
    else if (cmd && (key === "=" || key === "+")) setFontSize(1);
    else if (cmd && key === "-") setFontSize(-1);
    else if (e.key === "F1" || (cmd && e.key === "?")) toggleHints();
    else if (e.key === "F11" || (platform.isMac && e.metaKey && e.ctrlKey && key === "f")) void platform.toggleFullscreen();
    else if (e.key === "Escape" && !hintsEl.hidden) toggleHints(false);
    else if (e.key === "Escape" && view === "preview") setView("edit");
    // A reload would throw away the document: swallow the WebView's refresh keys.
    // Ctrl+R is Vim's redo: outside Insert mode Vim itself cancels the reload (a handler that
    // already called preventDefault would stop the editor from seeing the key).
    else if (cmd && (key === "r" || e.code === "KeyR") && editor.vimOwnsKeys) handled = false;
    else if (e.key === "F5" || (cmd && (key === "r" || e.code === "KeyR"))) handled = true;
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
editor.setVim(settings.vim);

const dropOverlay = $("drop-overlay");
void platform.onFileDrop(
  (file) => void openDropped(file),
  (hovering) => (dropOverlay.hidden = !hovering),
);

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
