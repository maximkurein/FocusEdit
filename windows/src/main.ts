// FocusEdit for Windows (experimental) — app shell: document lifecycle,
// toolbar, keyboard shortcuts, title and word count.

import "./styles.css";
import type { Text } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { type DocKind, kindForPath } from "./completion";
import { clearDraft, loadDraft, saveDraft } from "./draft";
import { Editor, type LineSeparator, wrapWith } from "./editor";
import { copyAsHtml, htmlDocument, printMarkdown, titleOf } from "./export";
import { appendAbout, renderHints } from "./hints";
import { renderMarkdown } from "./markdown-html";
import { closeMenu, type MenuItem, showMenu } from "./menu";
import { fileContents, fileName, freeName, isoDate, joinPath, startingText } from "./newfile";
import { type Command, filterCommands, Palette } from "./palette";
import { extractHeadings, OutlinePanel } from "./outline";
import { describeLost } from "./rtf";
import { addRecent, folderOf, loadRecent, removeRecent, saveRecent } from "./recent";
import { countWords, formatDuration, Session } from "./session";
import type { VimAction } from "./vim";
import { markWelcomed, wasWelcomed, welcomeText } from "./welcome";
import { NewFileWizard } from "./wizard";
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

let cursorLine = 1;
let wordCount = 0;
let selectedWords = 0;
let notice = "";
const session = new Session();

const editor = new Editor($("editor"), {
  settings,
  hintsKey: platform.isMac ? "⌘?" : "F1",
  commandsKey: `${mod}Shift+P`,
  onChange: (text) => {
    if (!doc.dirty) {
      doc.dirty = true;
      updateTitle();
    }
    updateStats(text);
    session.note(wordCount);
    schedulePreview();
    scheduleDraft();
    scheduleOutline();
  },
  onCursor: (line, words) => {
    cursorLine = line;
    if (settings.outline) outline.setCursor(line);
    if (words !== selectedWords) {
      selectedWords = words;
      renderStats();
    }
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
  $("outline").hidden = !settings.outline;
  $("btn-outline").classList.toggle("on", settings.outline);
  if (settings.outline) refreshOutline();
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
  wordCount = countWords(text.toString());
  renderStats();
}

const plural = (n: number) => `${n} word${n === 1 ? "" : "s"}`;

/** The line under the title: a notice, the selection, the session goal, or the document's size. */
function renderStats(): void {
  const goal = settings.goal;
  const bar = $("goal-bar");
  bar.hidden = goal <= 0;
  if (goal > 0) {
    const progress = session.progress(goal);
    $("goal-fill").style.width = `${Math.round(progress * 100)}%`;
    bar.classList.toggle("done", progress >= 1);
  }
  if (notice) statsEl.textContent = notice;
  else if (selectedWords > 0) statsEl.textContent = `${plural(selectedWords)} selected`;
  else if (goal > 0) statsEl.textContent = `+${session.written} / ${goal} words · ${formatDuration(session.activeMs)}${session.progress(goal) >= 1 ? " · goal reached" : ""}`;
  else statsEl.textContent = wordCount === 0 ? "" : `${plural(wordCount)} · ${Math.max(1, Math.ceil(wordCount / 200))} min read`;
}

// The session timer counts the seconds spent writing; the line is redrawn while a goal is set.
window.setInterval(() => {
  session.tick();
  if (settings.goal > 0) renderStats();
}, 1000);

function setGoal(words: number): void {
  changeSettings(() => (settings.goal = words));
  session.reset(wordCount); // count from now
  renderStats();
}

// --------------------------------------------------------------- documents

const EXTENSION: Record<DocKind, string> = { markdown: ".md", fountain: ".fountain", plain: ".txt" };

function load(text: string, path: string | null, name: string, keepDraft = false): void {
  const bom = text.startsWith("﻿");
  const body = bom ? text.slice(1) : text;
  const separator: LineSeparator = body.includes("\r\n") ? "\r\n" : "\n";
  Object.assign(doc, { path, name, kind: kindForPath(path ?? name), dirty: false, bom });
  editor.load(body, doc.kind, separator);
  updateTitle();
  updateStats(editor.view.state.doc);
  session.reset(wordCount);
  renderHelp();
  applyView();
  refreshOutline(1);
  if (!keepDraft) dropDraft();
  if (path) remember(path, name);
  editor.focusEditor();
}

async function canDiscard(): Promise<boolean> {
  return !doc.dirty || platform.confirmDiscard(doc.name);
}

async function newDocument(): Promise<void> {
  if (await canDiscard()) load("", null, "Untitled");
}

/** The three-step dialog, then the file on disk: format, template, name and folder. */
async function newFile(): Promise<void> {
  if (wizard.isOpen || !(await canDiscard())) return;
  const result = await wizard.ask({
    date: isoDate(),
    folder: await platform.defaultFolder(),
    chooseFolder: () => platform.chooseFolder(),
  });
  if (!result) return;
  const text = startingText(result.template, result.format, result.name, isoDate());
  const wanted = fileName(result.name, result.format);
  if (result.folder === null) {
    // No folders in a browser: the file is downloaded and the editor starts from it.
    platform.download(wanted, fileContents(result.format, text));
    load(text, null, wanted);
    editor.goToLine(Number.MAX_SAFE_INTEGER);
    return;
  }
  const folder = result.folder;
  const name = await freeName(wanted, (candidate) => platform.fileExists(joinPath(folder, candidate)));
  const path = joinPath(folder, name);
  if (!(await platform.writeFile(path, fileContents(result.format, text)))) return;
  load(text, path, name);
  remember(path, name);
  editor.goToLine(Number.MAX_SAFE_INTEGER); // ready to write under the template
  notify(`Created ${name}`);
}

async function openDocument(): Promise<void> {
  if (!(await canDiscard())) return;
  const file = await platform.openFile();
  if (file) loadFile(file);
}

/** A file dropped on the window: ask before discarding unsaved changes, then open it. */
async function openDropped(file: platform.OpenedFile): Promise<void> {
  if (await canDiscard()) loadFile(file);
}

async function openPath(path: string): Promise<void> {
  try {
    const file = await platform.readFile(path);
    loadFile(file);
  } catch (error) {
    await platform.showError(`Could not open ${platform.baseName(path)}: ${String(error)}`);
  }
}

/** Show a file that was just read; an .rtf file may have formatting that Markdown cannot keep. */
function loadFile(file: platform.OpenedFile): void {
  load(file.text, file.path, file.name);
  if (file.lost?.length) notify(`Saving this RTF file drops its ${describeLost(file.lost)}`, 8000);
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
  remember(path, doc.name);
  markSaved();
  refreshOutline();
}

function markSaved(): void {
  doc.dirty = false;
  dropDraft();
  updateTitle();
}

// ------------------------------------------------- crash recovery, recent files

let draftTimer = 0;

/** Keep a copy of the unsaved text, so a crash or power cut doesn't lose it. */
function flushDraft(): void {
  window.clearTimeout(draftTimer);
  if (doc.dirty) saveDraft({ path: doc.path, name: doc.name, text: contents(), savedAt: Date.now() });
}

function scheduleDraft(): void {
  window.clearTimeout(draftTimer);
  draftTimer = window.setTimeout(flushDraft, 1500);
}

function dropDraft(): void {
  window.clearTimeout(draftTimer);
  clearDraft();
}

function remember(path: string, name: string): void {
  if (platform.isTauri) addRecent({ path, name });
}

async function openRecent(path: string): Promise<void> {
  if (!(await canDiscard())) return;
  try {
    const file = await platform.readFile(path);
    loadFile(file);
  } catch {
    removeRecent(path);
    await platform.showError(`Could not open ${platform.baseName(path)}. It was moved or deleted, so it was removed from the recent list.`);
  }
}

// ----------------------------------------------------------------- outline

const outline = new OutlinePanel($("outline"), (line) => editor.goToLine(line));
let outlineTimer = 0;

function refreshOutline(line = cursorLine): void {
  if (!settings.outline) return;
  window.clearTimeout(outlineTimer);
  outline.update(extractHeadings(editor.text, doc.kind), line);
}

function scheduleOutline(): void {
  if (!settings.outline) return;
  window.clearTimeout(outlineTimer);
  outlineTimer = window.setTimeout(() => refreshOutline(), 250);
}

// ------------------------------------------------------- file menu, export

/** A short message in place of the word count. */
function notify(message: string, ms = 2500): void {
  notice = message;
  renderStats();
  window.setTimeout(() => {
    notice = "";
    renderStats();
  }, ms);
}

async function exportHtml(): Promise<void> {
  const html = htmlDocument(editor.text, titleOf(doc.name));
  const path = await platform.chooseSavePath(`${titleOf(doc.name)}.html`, html, platform.HTML_FILTERS);
  if (path !== null && (await platform.writeFile(path, html))) notify("Exported as HTML");
}

async function copyHtml(): Promise<void> {
  notify((await copyAsHtml(editor.text)) ? "Copied as HTML" : "Could not copy");
}

function printDocument(): void {
  printMarkdown($("print-root"), editor.text);
}

function openFileMenu(): void {
  if (closeMenu()) return; // the click that closes it must not open it again
  const items: MenuItem[] = [
    { label: "New", heading: true },
    { label: "New file…", detail: `${mod}Shift+N`, run: () => void newFile() },
    { label: "New document", detail: `${mod}N`, run: () => void newDocument() },
    { label: "", separator: true },
  ];
  if (platform.isTauri) {
    const recent = loadRecent();
    items.push({ label: "Recent files", heading: true });
    if (recent.length === 0) items.push({ label: "No recent files", disabled: true });
    for (const file of recent) {
      items.push({ label: file.name, detail: folderOf(file.path), run: () => void openRecent(file.path) });
    }
    if (recent.length > 0) items.push({ label: "Clear the list", run: () => saveRecent([]) });
    items.push({ label: "", separator: true });
  }
  items.push(
    { label: "Export", heading: true },
    { label: "Export as HTML…", run: () => void exportHtml() },
    { label: "Print or save as PDF…", detail: `${mod}P`, run: printDocument },
    { label: "Copy as HTML", run: () => void copyHtml() },
  );
  showMenu($("btn-file"), items);
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

// ----------------------------------------------------------- command palette

const palette = new Palette($("palette"), () => editor.focusEditor());
const wizard = new NewFileWizard($("wizard"), () => editor.focusEditor());

async function showWelcome(): Promise<void> {
  if (!(await canDiscard())) return;
  load(welcomeText(mod), null, "Welcome.md");
}

/** Everything the app can do, for the palette. */
function allCommands(): Command[] {
  const key = (s: string) => `${mod}${s}`;
  const format = (before: string, after: string) => () => {
    const view = editor.view;
    wrapWith(before, after)({ state: view.state, dispatch: (tr) => view.dispatch(tr) });
    editor.focusEditor();
  };
  const list: Command[] = [
    { title: "New file…", shortcut: key("Shift+N"), keywords: "create wizard steps template txt text md markdown rtf rich", run: () => void newFile() },
    { title: "New document", shortcut: key("N"), run: () => void newDocument() },
    { title: "Open…", shortcut: key("O"), run: () => void openDocument() },
    { title: "Save", shortcut: key("S"), run: () => void save() },
    { title: "Save as…", shortcut: key("Shift+S"), run: () => void saveAs() },
    { title: "Export as HTML…", run: () => void exportHtml() },
    { title: "Print or save as PDF…", shortcut: key("P"), keywords: "pdf", run: printDocument },
    { title: "Copy as HTML", run: () => void copyHtml() },
    { title: "View: Edit", shortcut: key("Shift+V"), keywords: "source write", run: () => setView("edit") },
    { title: "View: Split", keywords: "side by side live preview", run: () => setView("split") },
    { title: "View: Preview", keywords: "read reading", run: () => setView("preview") },
    { title: settings.outline ? "Outline: hide" : "Outline: show", shortcut: key("Shift+O"), keywords: "headings", run: () => actions["btn-outline"]() },
    ...focusModes.map((mode): Command => ({
      title: `Focus: ${mode[0].toUpperCase()}${mode.slice(1)}`,
      keywords: "highlight dim",
      run: () => changeSettings(() => (settings.focusMode = mode)),
    })),
    { title: settings.typewriter ? "Typewriter scrolling: off" : "Typewriter scrolling: on", shortcut: key("T"), keywords: "centre center", run: () => actions["btn-typewriter"]() },
    ...themeNames.map((theme): Command => ({
      title: `Theme: ${theme}`,
      keywords: { System: "auto follow windows", Light: "day white", Dark: "night black", Sepia: "paper warm" }[theme],
      run: () => changeSettings(() => (settings.theme = theme)),
    })),
    ...sizes.map((size): Command => ({ title: `Column width: ${size}`, run: () => changeSettings(() => (settings.size = size)) })),
    ...fonts.map((font): Command => ({ title: `Font: ${font[0].toUpperCase()}${font.slice(1)}`, run: () => changeSettings(() => (settings.font = font)) })),
    { title: "Text size: larger", shortcut: key("+"), run: () => setFontSize(1) },
    { title: "Text size: smaller", shortcut: key("−"), run: () => setFontSize(-1) },
    { title: "Full screen", shortcut: "F11", run: () => void platform.toggleFullscreen() },
    {
      title: settings.liveMarkdown ? "Markup: always show the marks" : "Markup: hide the marks away from the cursor",
      keywords: "markdown symbols asterisks hashes wysiwyg live",
      run: () => changeSettings(() => (settings.liveMarkdown = !settings.liveMarkdown)),
    },
    { title: settings.vim ? "Vim mode: turn off" : "Vim mode: turn on", keywords: "learn", run: () => actions["btn-vim"]() },
    { title: "Format: Bold", shortcut: key("B"), run: format("**", "**") },
    { title: "Format: Italic", shortcut: key("I"), run: format("*", "*") },
    { title: "Format: Link", shortcut: key("K"), run: format("[", "](https://)") },
    ...[250, 500, 1000, 2000].map((n): Command => ({ title: `Word goal: ${n} words`, keywords: "target session progress timer", run: () => setGoal(n) })),
    { title: "Word goal: off", keywords: "target session progress timer", run: () => setGoal(0) },
    { title: "Hints and shortcuts", shortcut: "F1", run: () => toggleHints(true) },
    { title: "About FocusEdit", keywords: "version developer github", run: () => toggleHints(true) },
    { title: "Open the welcome tour", keywords: "introduction help start", run: () => void showWelcome() },
  ];
  if (platform.isTauri) {
    for (const file of loadRecent()) {
      list.push({ title: `Open recent: ${file.name}`, keywords: folderOf(file.path), run: () => void openRecent(file.path) });
    }
  }
  return list;
}

/** What the palette lists for what has been typed; a number also offers a word goal and a line. */
function paletteCommands(query: string): Command[] {
  const list = filterCommands(allCommands(), query);
  const number = /^\d+$/.test(query.trim()) ? parseInt(query.trim(), 10) : null;
  if (number !== null && number > 0) {
    list.unshift(
      { title: `Word goal: ${number} words`, run: () => setGoal(number) },
      { title: `Go to line ${number}`, run: () => editor.goToLine(number) },
    );
  }
  return list;
}

function openPalette(): void {
  closeMenu();
  palette.open(paletteCommands);
}

// ----------------------------------------------------------------- toolbar

const actions: Record<string, () => void> = {
  "btn-new": () => void newFile(),
  "btn-open": () => void openDocument(),
  "btn-save": () => void save(),
  "btn-focus": () => changeSettings(() => (settings.focusMode = next(focusModes, settings.focusMode))),
  "btn-file": openFileMenu,
  "btn-outline": () => changeSettings(() => (settings.outline = !settings.outline)),
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
    if (id !== "btn-hints" && id !== "btn-file") editor.focusEditor();
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
    else if (cmd && e.shiftKey && key === "o") actions["btn-outline"]();
    else if (cmd && key === "o") void openDocument();
    else if (cmd && !e.shiftKey && key === "p") printDocument();
    else if (cmd && e.shiftKey && key === "n") void newFile();
    else if (cmd && key === "n") void newDocument();
    else if (cmd && e.shiftKey && key === "p") openPalette();
    else if (cmd && e.shiftKey && key === "v") actions["btn-view"]();
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
// Read before anything can clear it: a draft left by a crash is offered back below.
const pendingDraft = loadDraft();
load("", null, "Untitled", true);
editor.setVim(settings.vim);

// "System" theme follows Windows switching between light and dark.
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if (settings.theme === "System") applyAppearance();
});

const dropOverlay = $("drop-overlay");
void platform.onFileDrop(
  (file) => void openDropped(file),
  (hovering) => (dropOverlay.hidden = !hovering),
);

void platform.onCloseRequested(async () => {
  const leave = !doc.dirty || (await platform.confirmDiscard(doc.name));
  if (leave) dropDraft(); // a clean exit leaves nothing to recover
  return leave;
});

/** Start-up order: unsaved text from a crash, then a file given on the command line, then the last document. */
async function start(): Promise<void> {
  if (pendingDraft && pendingDraft.text.trim() !== "") {
    if (await platform.confirmRestore(pendingDraft.name)) {
      load(pendingDraft.text, pendingDraft.path, pendingDraft.name);
      doc.dirty = true;
      updateTitle();
      flushDraft();
      return;
    }
  }
  dropDraft();
  const startup = await platform.startupFile();
  if (startup) return openPath(startup);
  const last = platform.isTauri ? loadRecent()[0] : undefined;
  let opened = false;
  if (last) {
    try {
      const file = await platform.readFile(last.path);
      loadFile(file);
      opened = true;
    } catch {
      removeRecent(last.path); // gone since last time: start with an empty document
    }
  }
  // The very first start: a document that teaches by being edited.
  if (!opened && !wasWelcomed()) load(welcomeText(mod), null, "Welcome.md");
  markWelcomed();
}
void start();

// Small hook for scripted checks (scripts/snapshot.mjs).
(window as unknown as { focusEdit: unknown }).focusEdit = {
  load: (text: string, name: string) => load(text, null, name),
  editor,
  settings,
};
