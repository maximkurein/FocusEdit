// Vim mode inside CodeMirror: the buffer the engine edits, key translation,
// the block cursor and the coach bar under the editor — VimController.swift
// on macOS.

import { isolateHistory, redo, undo } from "@codemirror/commands";
import {
  Annotation,
  EditorSelection,
  type EditorState,
  type Extension,
  Prec,
  StateEffect,
  StateField,
  type Transaction,
} from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, WidgetType } from "@codemirror/view";
import { clearGhost } from "./ghost";
import { langmap, type VimAction, type VimBuffer, type VimFeedback, type VimMode, type VimRange, VimEngine } from "./vim";

/** A transaction that belongs to the previous history event (one Vim command = one undo step). */
export const vimGroup = Annotation.define<boolean>();
/** A transaction made by the engine itself (not typing, so not recorded for "."). */
const vimOwn = Annotation.define<boolean>();

/** Join the edits of one Vim command into one undo step; pass to history({ joinToEvent }). */
export const joinVimEdits = (tr: Transaction, isAdjacent: boolean): boolean => isAdjacent || tr.annotation(vimGroup) === true;

/** What the buffer needs from the editor: an EditorView, or a bare state in tests. */
export interface VimHost {
  readonly state: EditorState;
  dispatch(tr: Transaction): void;
}

export class CmVimBuffer implements VimBuffer {
  private depth = 0;
  private firstEdit = true;
  private pending: VimRange | null = null;
  private cachedDoc: EditorState["doc"] | null = null;
  private cachedText = "";

  constructor(private readonly host: VimHost) {}

  get text(): string {
    const doc = this.host.state.doc;
    if (doc !== this.cachedDoc) {
      this.cachedDoc = doc;
      this.cachedText = doc.toString();
    }
    return this.cachedText;
  }

  get selection(): VimRange {
    if (this.pending) return this.pending;
    const { from, to } = this.host.state.selection.main;
    return { location: from, length: to - from };
  }

  set selection(value: VimRange) {
    const len = this.host.state.doc.length;
    const location = Math.min(Math.max(0, value.location), len);
    const range = { location, length: Math.min(value.length, len - location) };
    if (this.depth > 0) {
      this.pending = range; // written with the next edit or when the command ends
      return;
    }
    this.pending = null;
    this.dispatchSelection(range);
  }

  private dispatchSelection(range: VimRange): void {
    const { from, to } = this.host.state.selection.main;
    if (from === range.location && to === range.location + range.length) return;
    this.host.dispatch(
      this.host.state.update({
        selection: EditorSelection.single(range.location, range.location + range.length),
        scrollIntoView: true,
        annotations: vimOwn.of(true),
      }),
    );
  }

  replace(range: VimRange, string: string): void {
    const cur = this.selection;
    const from = range.location;
    const to = range.location + range.length;
    const delta = string.length - range.length;
    // Like a text view: positions inside the replaced text land after the new text.
    const map = (pos: number) => (pos < from ? pos : pos <= to ? from + string.length : pos + delta);
    const start = map(cur.location);
    const stop = Math.max(start, map(cur.location + cur.length));
    const grouped = this.depth > 0;
    this.pending = null;
    this.host.dispatch(
      this.host.state.update({
        changes: { from, to, insert: string },
        selection: EditorSelection.single(start, stop),
        scrollIntoView: true,
        annotations: [
          vimOwn.of(true),
          ...(grouped ? (this.firstEdit ? [isolateHistory.of("before")] : [vimGroup.of(true)]) : []),
        ],
      }),
    );
    if (grouped) this.firstEdit = false;
  }

  undo(): void {
    undo({ state: this.host.state, dispatch: (tr) => this.host.dispatch(tr) });
  }

  redo(): void {
    redo({ state: this.host.state, dispatch: (tr) => this.host.dispatch(tr) });
  }

  beginChange(): void {
    this.depth++;
  }

  endChange(): void {
    if (--this.depth > 0) return;
    this.depth = 0;
    this.firstEdit = true;
    const range = this.pending;
    this.pending = null;
    if (range) this.dispatchSelection(range);
  }
}

// ------------------------------------------------------------------- keys

interface KeyInfo {
  key: string;
  ctrlKey: boolean;
  altKey: boolean;
  metaKey: boolean;
}

/** Translate a key press into an engine key, or null when Vim doesn't take it. */
export function vimToken(e: KeyInfo, engine: Pick<VimEngine, "mode" | "wantsLiteralCharacter">): string | null {
  if (e.metaKey) return null;
  const altGr = e.ctrlKey && e.altKey; // Windows reports AltGr as Ctrl+Alt
  if (e.altKey && !altGr) return null;
  switch (e.key) {
    case "Escape": return "<Esc>";
    case "Enter": return "<CR>";
    case "Backspace": return "<BS>";
    case "ArrowLeft": return "<Left>";
    case "ArrowRight": return "<Right>";
    case "ArrowDown": return "<Down>";
    case "ArrowUp": return "<Up>";
  }
  if (e.ctrlKey && !altGr) {
    switch (e.key.toLowerCase()) {
      case "r": case "к": return "<C-r>";
      case "[": case "х": return "<Esc>";
      default: return null;
    }
  }
  if ([...e.key].length !== 1) return null;
  // Russian layout: commands still work by physical key (like NeoVim's langmap),
  // but characters Vim is waiting for (f/t/r targets, search text) stay as typed.
  if (engine.mode !== "INSERT" && engine.mode !== "COMMAND" && !engine.wantsLiteralCharacter && langmap[e.key]) {
    return langmap[e.key];
  }
  return e.key;
}

// ------------------------------------------------------------ mode + cursor

const setVimMode = StateEffect.define<VimMode>();

const modeField = StateField.define<VimMode>({
  create: () => "NORMAL",
  update(mode, tr) {
    for (const e of tr.effects) if (e.is(setVimMode)) return e.value;
    return mode;
  },
  provide: (field) =>
    EditorView.editorAttributes.from(field, (mode) => ({
      class: "vim-on" + (mode === "NORMAL" || mode === "VISUAL" || mode === "VISUAL LINE" ? " vim-hide-caret" : ""),
    })),
});

class EmptyBlock extends WidgetType {
  eq() {
    return true;
  }
  toDOM() {
    const span = document.createElement("span");
    span.className = "cm-vim-block cm-vim-block-empty";
    span.textContent = "​";
    return span;
  }
}

/** Normal mode draws the cursor as a block over the character it sits on. */
function blockCursor(state: EditorState): DecorationSet {
  if (state.field(modeField) !== "NORMAL") return Decoration.none;
  const head = state.selection.main.head;
  const next = state.doc.sliceString(head, head + 1);
  const deco =
    next === "" || next === "\n"
      ? Decoration.widget({ widget: new EmptyBlock(), side: 1 }).range(head)
      : Decoration.mark({ class: "cm-vim-block" }).range(head, head + 1);
  return Decoration.set([deco]);
}

// -------------------------------------------------------------- coach bar

const MODE_CLASS: Record<VimMode, string> = {
  NORMAL: "normal",
  INSERT: "insert",
  VISUAL: "visual",
  "VISUAL LINE": "visual",
  COMMAND: "command",
};

function legendFor(mode: VimMode): string {
  switch (mode) {
    case "NORMAL": return "i type · v select · : commands · u undo";
    case "INSERT": return "Esc → NORMAL";
    case "VISUAL":
    case "VISUAL LINE": return "d y c > act · Esc → NORMAL";
    case "COMMAND": return "Enter run · Esc cancel";
  }
}

/** The bar under the editor in Vim mode: mode, the keys being typed, what the last command did, and a tip. */
export class VimCoach {
  private readonly badge = el("span", "vim-badge");
  private readonly keys = el("span", "vim-keys");
  private readonly message = el("span", "vim-message");
  private readonly tip = el("div", "vim-tip");
  private readonly legend = el("span", "vim-legend");

  constructor(
    private readonly root: HTMLElement,
    onExit: () => void,
  ) {
    const exit = el("button", "vim-exit");
    exit.type = "button";
    exit.textContent = "Exit Vim";
    exit.title = "Turn Vim mode off (also the Vim button in the toolbar, or :novim)";
    // Keep the editor focused: a click on the button must not steal the keyboard.
    exit.addEventListener("mousedown", (e) => e.preventDefault());
    exit.addEventListener("click", onExit);
    const row = el("div", "vim-row");
    row.append(this.badge, this.keys, this.message);
    const main = el("div", "vim-main");
    main.append(row, this.tip);
    const side = el("div", "vim-side");
    side.append(this.legend, exit);
    root.replaceChildren(main, side);
  }

  show(visible: boolean): void {
    this.root.hidden = !visible;
  }

  update(engine: VimEngine): void {
    const mode = engine.mode;
    this.badge.textContent = mode;
    this.badge.className = `vim-badge ${MODE_CLASS[mode]}`;
    this.legend.textContent = legendFor(mode);
    if (mode === "COMMAND") {
      this.keys.textContent = engine.commandPrefix + engine.commandLine + "▏";
      this.message.textContent =
        engine.commandPrefix === ":" ? "Enter runs it · Esc cancels" : "Type the text to find, then Enter · Esc cancels";
      this.message.className = "vim-message muted";
      this.setTip(null);
      return;
    }
    const fb: VimFeedback | null = engine.feedback;
    const pending = engine.pendingKeys;
    this.keys.textContent = pending === "" ? (fb?.keys ?? "") : pending + "…";
    if (pending !== "") {
      this.message.textContent = "waiting for the rest of the command";
      this.message.className = "vim-message muted";
    } else {
      this.message.textContent = fb?.text ?? "";
      this.message.className = "vim-message" + (fb?.isError ? " error" : "");
    }
    this.setTip(engine.tip);
  }

  private setTip(text: string | null): void {
    this.tip.textContent = text ? `Tip: ${text}` : "";
    this.tip.hidden = !text;
  }
}

function el<K extends keyof HTMLElementTagNameMap>(tag: K, className: string): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  node.className = className;
  return node;
}

// ------------------------------------------------------------- controller

/** Connects a VimEngine to an EditorView and the coach bar. */
export class VimController {
  readonly engine: VimEngine;
  private readonly coach: VimCoach;

  constructor(
    private readonly view: EditorView,
    coachRoot: HTMLElement,
    /** Save / close / help, carried out by the app (it knows the document). */
    perform: (action: VimAction) => void,
  ) {
    this.engine = new VimEngine(new CmVimBuffer(view));
    this.coach = new VimCoach(coachRoot, () => perform("exitVim"));
    this.engine.onModeChange = (mode) => {
      view.dispatch({ effects: setVimMode.of(mode) });
      this.coach.update(this.engine);
    };
    this.engine.onFeedback = () => this.coach.update(this.engine);
    this.engine.onAction = perform;
  }

  /** Start in Normal mode on the current document. */
  start(): void {
    this.engine.reset();
    this.view.dispatch({ effects: setVimMode.of(this.engine.mode) });
    this.coach.show(true);
    this.coach.update(this.engine);
  }

  stop(): void {
    this.coach.show(false);
  }

  /** The editor extension that routes keys to the engine and draws the block cursor. */
  extension(): Extension {
    return [
      modeField,
      EditorView.decorations.compute([modeField, "selection"], blockCursor),
      // Ahead of the keymaps (ghost text, brackets, history) so Normal mode owns every key.
      Prec.highest(
        EditorView.domEventHandlers({
          keydown: (e) => this.keydown(e),
          mouseup: () => void setTimeout(() => this.engine.clampSelection(), 0),
        }),
      ),
      // What the editor itself inserts in Insert mode is what "." will repeat.
      EditorView.updateListener.of((u) => {
        if (!u.docChanged || this.engine.mode !== "INSERT") return;
        for (const tr of u.transactions) {
          if (tr.annotation(vimOwn)) continue;
          tr.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
            if (inserted.length > 0) this.engine.noteInserted(inserted.toString(), 0);
            else this.engine.noteInserted("", toA - fromA);
          });
        }
      }),
    ];
  }

  private keydown(e: KeyboardEvent): boolean {
    if (e.isComposing) return false;
    const token = vimToken(e, this.engine);
    if (this.engine.mode === "INSERT") {
      if (token !== "<Esc>") return false; // typing goes to the editor
      this.view.dispatch({ effects: clearGhost.of(null) });
    } else if (token === null) {
      // No stray Tab or Delete edits in Normal mode.
      if ((e.key === "Tab" || e.key === "Delete") && !e.ctrlKey && !e.metaKey && !e.altKey) {
        e.preventDefault();
        return true;
      }
      return false;
    }
    e.preventDefault();
    return this.engine.handle(token as string);
  }
}
