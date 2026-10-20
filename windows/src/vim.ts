// A teaching Vim mode: the classic "operator + motion" grammar of Vim/NeoVim
// on top of FocusEdit's editor, with an explanation of every command.
// A port of VimEngine.swift — keep the two in step.
//
// Supported (Normal):  h j k l  w b e W B E  0 ^ $  gg G  { }  f F t T ; ,
//                      / ? n N   counts (3w, d2w, 2dd)
// Operators:           d c y > <  (doubled = whole lines: dd cc yy >> <<)
// Text objects:        iw aw  ip ap  i" a" i' a'  i( a( ib ab  i[ a[  i{ a{ iB aB
// Commands:            x X D C Y s S r ~ J p P u Ctrl-r .  i a I A o O  v V
// Command line:        :w :q :wq :x :q! :help :novim :{line}
//
// Positions are UTF-16 offsets into the buffer (JS string indices).

export interface VimRange {
  location: number;
  length: number;
}

/** The text the engine edits — the CodeMirror view in the app, a state in tests. */
export interface VimBuffer {
  readonly text: string;
  selection: VimRange;
  replace(range: VimRange, string: string): void;
  undo(): void;
  redo(): void;
  /** Group the edits of one command into one undo step. */
  beginChange(): void;
  endChange(): void;
}

export type VimMode = "NORMAL" | "INSERT" | "VISUAL" | "VISUAL LINE" | "COMMAND";
export type VimAction = "save" | "close" | "saveAndClose" | "discardAndClose" | "help" | "exitVim";

/** What the coach shows after a command. */
export interface VimFeedback {
  keys: string;
  text: string;
  isError?: boolean;
}

interface Motion {
  target: number;
  linewise?: boolean;
  inclusive?: boolean;
}

type Awaiting =
  | { t: "find"; kind: string }
  | { t: "replace" }
  | { t: "textObject"; kind: string }
  | { t: "g" };

const end = (r: VimRange) => r.location + r.length;
const range = (location: number, length: number): VimRange => ({ location, length });
const isBlankChar = (c: number) => c === 32 || c === 9;
const isSingle = (key: string) => [...key].length === 1;

export class VimEngine {
  private _mode: VimMode = "NORMAL";
  onModeChange?: (mode: VimMode) => void;
  onAction?: (action: VimAction) => void;
  onFeedback?: (feedback: VimFeedback | null, tip: string | null) => void;

  feedback: VimFeedback | null = null;
  tip: string | null = null;
  /** Keys of the command still being typed ("d2", "f", "ci"). */
  pendingKeys = "";
  /** Text typed after ":" "/" or "?". */
  commandLine = "";
  commandPrefix = ":";

  constructor(readonly buffer: VimBuffer) {}

  get mode(): VimMode {
    return this._mode;
  }

  private setMode(mode: VimMode): void {
    if (mode === this._mode) return;
    this._mode = mode;
    this.onModeChange?.(mode);
  }

  /** True while a command waits for a character argument (f/t/r targets):
   *  that character is taken literally, not through the keyboard-layout map. */
  get wantsLiteralCharacter(): boolean {
    return this.awaiting?.t === "find" || this.awaiting?.t === "replace";
  }

  // ------------------------------------------------------------ command state

  private countDigits = "";
  private operatorKey: string | null = null;
  private operatorCount = 1;
  private awaiting: Awaiting | null = null;
  private register = "";
  private registerLinewise = false;
  private lastFind: { kind: string; char: string } | null = null;
  private lastSearch: { pattern: string; forward: boolean } | null = null;
  private visualAnchor = 0;
  private visualCursor = 0;
  private wantColumn: number | null = null;

  // Dot repeat: the keys of the last change, plus text typed in Insert mode.
  private commandKeys: string[] = [];
  private changeKeys: string[] | null = null;
  private insertedText = "";
  private lastChange: { keys: string[]; inserted: string } | null = null;
  private replaying = false;

  // Coaching
  private lastSimpleKey = "";
  private repeatRun = 0;
  private tipIndex = 0;

  // ------------------------------------------------------------- entry points

  /** Feed one key: a character ("w", "3", "$") or "<Esc>", "<CR>", "<BS>",
   *  "<C-r>", "<Left>", "<Right>", "<Up>", "<Down>". Returns false when the
   *  editor should handle the key itself (typing in Insert mode). */
  handle(key: string): boolean {
    switch (this._mode) {
      case "INSERT":
        return this.handleInsert(key);
      case "COMMAND":
        this.handleCommandLine(key);
        return true;
      default:
        this.handleNormal(key);
        return true;
    }
  }

  /** Text typed in Insert mode by the editor itself (recorded for "."). */
  noteInserted(string: string, deletedBackward: number): void {
    if (this._mode !== "INSERT" || this.replaying) return;
    if (deletedBackward > 0 && string === "") {
      this.insertedText = this.insertedText.slice(0, Math.max(0, this.insertedText.length - deletedBackward));
    } else {
      this.insertedText += string;
    }
  }

  /** Switching Vim mode on: start in Normal mode with the cursor on a character. */
  reset(): void {
    this.setMode("NORMAL");
    this.clearPending();
    this.buffer.selection = range(this.clampNormal(this.buffer.selection.location), 0);
    this.report(
      { keys: "", text: "Vim mode on. NORMAL: letters are commands — press i to type, Esc to come back." },
      "Exit Vim (right) or :novim turns Vim mode off. VIM_GUIDE.md has the lessons.",
    );
  }

  /** The cursor must sit on a character in Normal mode (after a mouse click). */
  clampSelection(): void {
    if (this._mode !== "NORMAL") return;
    const s = this.buffer.selection;
    if (s.length === 0 && s.location !== this.clampNormal(s.location)) {
      this.buffer.selection = range(this.clampNormal(s.location), 0);
    }
  }

  // -------------------------------------------------------------- Insert mode

  private handleInsert(key: string): boolean {
    if (key === "<Esc>") {
      this.setMode("NORMAL");
      const p = this.buffer.selection.location;
      const back = p > this.lineStart(p) ? p - 1 : p;
      this.buffer.selection = range(this.clampNormal(back), 0);
      if (this.changeKeys && !this.replaying) this.lastChange = { keys: this.changeKeys, inserted: this.insertedText };
      this.changeKeys = null;
      if (!this.replaying) {
        this.report({ keys: "Esc", text: "Back to Normal mode. What you typed can be repeated with ." }, null);
      }
      return true;
    }
    if (!this.replaying) return false;
    // Replaying "." types the recorded text itself.
    const sel = this.buffer.selection;
    if (key === "<BS>") {
      if (sel.location > 0) this.buffer.replace(range(sel.location - 1, 1), "");
    } else {
      this.buffer.replace(sel, key === "<CR>" ? "\n" : key);
    }
    return true;
  }

  // ---------------------------------------------------- Command line (: / ?)

  private handleCommandLine(key: string): void {
    switch (key) {
      case "<Esc>":
        this.setMode("NORMAL");
        this.commandLine = "";
        this.report({ keys: this.commandPrefix, text: "Command line cancelled." }, null);
        break;
      case "<BS>":
        if (this.commandLine === "") this.setMode("NORMAL");
        else this.commandLine = [...this.commandLine].slice(0, -1).join("");
        this.onFeedback?.(this.feedback, this.tip);
        break;
      case "<CR>": {
        const line = this.commandLine;
        this.commandLine = "";
        this.setMode("NORMAL");
        if (this.commandPrefix === ":") this.runCommand(line);
        else this.search(line, this.commandPrefix === "/", 1, this.commandPrefix + line);
        break;
      }
      default:
        if (isSingle(key)) this.commandLine += key;
        this.onFeedback?.(this.feedback, this.tip);
    }
  }

  private runCommand(line: string): void {
    const cmd = line.trim();
    const keys = ":" + cmd;
    switch (cmd) {
      case "w":
        this.onAction?.("save");
        this.report({ keys, text: "write — save the file." }, null);
        break;
      case "q":
        this.onAction?.("close");
        this.report({ keys, text: "quit — close the window (asks first if there are unsaved changes)." }, null);
        break;
      case "wq":
      case "x":
        this.onAction?.("saveAndClose");
        this.report({ keys, text: "write and quit — save, then close." }, null);
        break;
      case "q!":
        this.onAction?.("discardAndClose");
        this.report({ keys, text: "quit! — close and throw away unsaved changes." }, null);
        break;
      case "novim":
      case "vimoff":
      case "noh vim":
        this.onAction?.("exitVim");
        this.report({ keys, text: "Vim mode off — FocusEdit is a normal editor again." }, null);
        break;
      case "h":
      case "help":
        this.onAction?.("help");
        this.report({ keys, text: "help — the cheat sheet." }, null);
        break;
      default:
        if (/^\d+$/.test(cmd)) {
          const n = parseInt(cmd, 10);
          this.buffer.selection = range(this.firstNonBlank(this.lineStartOf(n)), 0);
          this.report({ keys, text: `Go to line ${n}.` }, `${n}G does the same from Normal mode.`);
        } else {
          this.report(
            { keys, text: `Not an editor command: ${cmd}. Try :w, :q, :wq, :q!, :help or :novim (leave Vim mode).`, isError: true },
            null,
          );
        }
    }
  }

  // ----------------------------------------------------- Normal and Visual mode

  private get inVisual(): boolean {
    return this._mode === "VISUAL" || this._mode === "VISUAL LINE";
  }

  private handleNormal(key: string): void {
    this.commandKeys.push(key);
    this.pendingKeys += VimEngine.display(key);

    if (key === "<Esc>") {
      const wasVisual = this._mode !== "NORMAL";
      if (wasVisual) {
        this.setMode("NORMAL");
        this.buffer.selection = range(this.clampNormal(this.visualCursor), 0);
      }
      this.clearPending();
      this.report({ keys: "Esc", text: wasVisual ? "Visual mode off." : "Cancelled. You are in Normal mode." }, null);
      return;
    }

    if (this.awaiting) {
      const a = this.awaiting;
      this.awaiting = null;
      this.resolve(a, key);
      return;
    }

    // Counts: 3w, d2w, 2dd. A lone 0 is a motion (start of line).
    if (/^[0-9]$/.test(key) && !(key === "0" && this.countDigits === "")) {
      this.countDigits += key;
      this.onFeedback?.(this.feedback, this.tip);
      return;
    }

    const countGiven = this.countDigits !== "";
    const n = Math.max(1, parseInt(this.countDigits, 10) || 1);
    this.countDigits = "";

    // Operators
    if (["d", "c", "y", ">", "<"].includes(key)) {
      if (this.inVisual) {
        this.applyVisual(key);
        return;
      }
      if (this.operatorKey === key) {
        this.linewiseOperator(key, this.operatorCount * n);
        return;
      }
      this.operatorKey = key;
      this.operatorCount = n;
      this.onFeedback?.(this.feedback, this.tip);
      return;
    }

    switch (key) {
      case "g":
        this.countDigits = countGiven ? String(n) : "";
        this.awaiting = { t: "g" };
        this.onFeedback?.(this.feedback, this.tip);
        return;
      case "f":
      case "F":
      case "t":
      case "T":
        this.countDigits = countGiven ? String(n) : "";
        this.awaiting = { t: "find", kind: key };
        this.onFeedback?.(this.feedback, this.tip);
        return;
      case "i":
      case "a":
        if (this.operatorKey !== null || this._mode !== "NORMAL") {
          this.awaiting = { t: "textObject", kind: key };
          this.onFeedback?.(this.feedback, this.tip);
          return;
        }
        break;
    }

    const m = this.motion(key, this.cursor, n, countGiven, this.operatorKey !== null);
    if (m) {
      if (this.operatorKey) this.operate(this.operatorKey, key, m, this.operatorCount * n);
      else this.move(m.target, key, n, countGiven);
      return;
    }

    if (this.operatorKey !== null) {
      this.fail(`${this.pendingKeys} — after an operator comes a motion (w, $, j…) or a text object (iw, ip…).`);
      return;
    }
    this.command(key, n);
  }

  private resolve(a: Awaiting, key: string): void {
    const countGiven = this.countDigits !== "";
    const n = Math.max(1, parseInt(this.countDigits, 10) || 1);
    this.countDigits = "";
    switch (a.t) {
      case "g":
        if (key === "g") {
          const m: Motion = { target: this.firstNonBlank(this.lineStartOf(countGiven ? n : 1)), linewise: true };
          if (this.operatorKey) this.operate(this.operatorKey, "gg", m, 1);
          else this.move(m.target, "gg", n, countGiven);
        } else if (key === "e") {
          let q = this.cursor;
          for (let i = 0; i < n; i++) q = this.wordEndBackward(q, false);
          const m: Motion = { target: q, inclusive: true };
          if (this.operatorKey) this.operate(this.operatorKey, "ge", m, n);
          else this.move(q, "ge", n, countGiven);
        } else {
          this.fail(`g${VimEngine.display(key)} — FocusEdit knows gg (first line) and ge (end of previous word).`);
        }
        return;
      case "find": {
        if (!isSingle(key)) return this.fail(`${a.kind} needs a character to look for.`);
        this.lastFind = { kind: a.kind, char: key };
        const target = this.findChar(a.kind, key, this.cursor, n);
        if (target === null) {
          return this.fail(`No “${key}” ${a.kind === "f" || a.kind === "t" ? "after" : "before"} the cursor on this line.`);
        }
        const m: Motion = { target, inclusive: a.kind === "f" || a.kind === "t" };
        if (this.operatorKey) this.operate(this.operatorKey, a.kind + key, m, n);
        else this.move(target, a.kind + key, n, countGiven);
        return;
      }
      case "replace":
        if (!isSingle(key)) return this.fail("r needs the character to put there.");
        this.replaceChars(key, n);
        return;
      case "textObject": {
        const obj = this.textObject(a.kind, key, this.cursor);
        if (!obj) {
          return this.fail(`${a.kind}${VimEngine.display(key)} — not a text object here. Try iw, ip, i", i(…`);
        }
        if (this.inVisual) {
          this.visualAnchor = obj.range.location;
          this.visualCursor = Math.max(obj.range.location, end(obj.range) - 1);
          if (obj.linewise) this.setMode("VISUAL LINE");
          this.updateVisualSelection();
          this.report(
            { keys: this.pendingKeys, text: `Select ${VimEngine.objectName(a.kind, key)}.` },
            "Now d, c, y or > act on the selection.",
          );
          this.clearPending();
        } else if (this.operatorKey) {
          this.apply(this.operatorKey, obj.range, obj.linewise, this.pendingKeys, VimEngine.objectName(a.kind, key));
        }
      }
    }
  }

  // ------------------------------------------------------------------ motions

  private get cursor(): number {
    return this.inVisual ? this.visualCursor : this.buffer.selection.location;
  }

  private motion(key: string, p: number, n: number, countGiven: boolean, forOperator: boolean): Motion | null {
    if (!["j", "k", "<Up>", "<Down>"].includes(key)) this.wantColumn = null;
    const len = this.text.length;
    switch (key) {
      case "h":
      case "<Left>":
        return { target: Math.max(this.lineStart(p), p - n) };
      case "l":
      case "<Right>":
      case " ":
        return { target: Math.min(forOperator ? this.lineEnd(p) : this.lastCharPos(p), p + n) };
      case "j":
      case "<Down>":
        return this.verticalMotion(p, n);
      case "k":
      case "<Up>":
        return this.verticalMotion(p, -n);
      case "0":
        return { target: this.lineStart(p) };
      case "^":
        return { target: this.firstNonBlank(p) };
      case "$": {
        let q = p;
        for (let i = 1; i < n; i++) q = Math.min(len, this.lineEnd(q) + 1);
        return { target: forOperator ? this.lineEnd(q) : this.lastCharPos(q) };
      }
      case "w":
      case "W": {
        let q = p;
        for (let i = 0; i < n; i++) q = this.nextWordStart(q, key === "W");
        // "dw" on the last word of a line stops at the line end, it doesn't join lines.
        if (forOperator && q > this.lineEnd(p) && p < this.lineEnd(p)) q = this.lineEnd(p);
        return { target: forOperator ? q : Math.min(q, Math.max(0, len - 1)) };
      }
      case "e":
      case "E": {
        let q = p;
        for (let i = 0; i < n; i++) q = this.wordEnd(q, key === "E");
        return { target: q, inclusive: true };
      }
      case "b":
      case "B": {
        let q = p;
        for (let i = 0; i < n; i++) q = this.wordBack(q, key === "B");
        return { target: q };
      }
      case "G": {
        const line = countGiven ? n : this.lineCount;
        return { target: this.firstNonBlank(this.lineStartOf(line)), linewise: true };
      }
      case "}": {
        let q = p;
        for (let i = 0; i < n; i++) q = this.paragraphForward(q);
        return { target: q };
      }
      case "{": {
        let q = p;
        for (let i = 0; i < n; i++) q = this.paragraphBackward(q);
        return { target: q };
      }
      case ";":
      case ",": {
        const f = this.lastFind;
        if (!f) return null;
        const reversed = ({ f: "F", F: "f", t: "T", T: "t" } as Record<string, string>)[f.kind] ?? f.kind;
        const kind = key === ";" ? f.kind : reversed;
        const t = this.findChar(kind, f.char, p, n);
        if (t === null) return { target: p };
        return { target: t, inclusive: kind === "f" || kind === "t" };
      }
      case "n":
      case "N": {
        const s = this.lastSearch;
        if (!s) return null;
        const forward = key === "n" ? s.forward : !s.forward;
        const t = this.find(s.pattern, p, forward, n);
        return { target: t ?? p };
      }
      default:
        return null;
    }
  }

  private verticalMotion(p: number, delta: number): Motion {
    const column = this.wantColumn ?? p - this.lineStart(p);
    this.wantColumn = column;
    const line = Math.max(1, Math.min(this.lineCount, this.lineNumber(p) + delta));
    const start = this.lineStartOf(line);
    return { target: Math.min(start + column, this.lastCharPos(start)), linewise: true };
  }

  private move(target: number, key: string, count: number, countGiven: boolean): void {
    const dest = this._mode === "NORMAL" ? this.clampNormal(target) : Math.min(target, Math.max(0, this.text.length - 1));
    if (this._mode === "NORMAL") {
      this.buffer.selection = range(dest, 0);
    } else {
      this.visualCursor = dest;
      this.updateVisualSelection();
    }
    const keys = this.pendingKeys;
    this.clearPending();
    let tipText: string | null = null;
    if (!countGiven && ["h", "j", "k", "l", "w", "b", "e", "<Left>", "<Right>", "<Up>", "<Down>"].includes(key)) {
      this.repeatRun = this.lastSimpleKey === key ? this.repeatRun + 1 : 1;
      this.lastSimpleKey = key;
      if (this.repeatRun >= 4) {
        const k = VimEngine.arrowAsKey[key] ?? key;
        tipText = `Pressed ${k} ${this.repeatRun} times? ${this.repeatRun}${k} does it in one go.`;
      }
    } else {
      this.repeatRun = 0;
      this.lastSimpleKey = "";
    }
    const arrow = VimEngine.arrowAsKey[key];
    if (key.startsWith("<") && arrow) {
      tipText = tipText ?? `In Vim the arrows are ${arrow} — keep your fingers on the home row.`;
    }
    this.report({ keys, text: "Move " + VimEngine.motionName(key, count) }, tipText ?? this.nextTip());
  }

  // ---------------------------------------------------------------- operators

  private operate(op: string, key: string, m: Motion, count: number): void {
    const p = this.cursor;
    let lo = Math.min(p, m.target);
    let hi = Math.max(p, m.target);
    if (m.inclusive) hi = Math.min(this.text.length, hi + 1);
    // "cw" changes to the end of the word (like "ce"), as Vim does.
    if (op === "c" && (key === "w" || key === "W") && this.wordClass(p, key === "W") !== 0) {
      const c = this.wordClass(p, key === "W");
      let q = p;
      while (q + 1 < this.text.length && this.wordClass(q + 1, key === "W") === c) q += 1;
      for (let i = 1; i < Math.max(1, count); i++) q = this.wordEnd(q, key === "W");
      lo = p;
      hi = Math.min(this.text.length, q + 1);
    }
    this.apply(op, range(lo, hi - lo), m.linewise ?? false, this.pendingKeys, VimEngine.motionName(key, count));
  }

  private linewiseOperator(op: string, n: number): void {
    const start = this.lineStart(this.cursor);
    const lastLine = Math.min(this.lineCount, this.lineNumber(this.cursor) + n - 1);
    const endStart = this.lineStartOf(lastLine);
    const r = range(start, this.lineEnd(endStart) - start);
    this.apply(op, r, true, this.pendingKeys, n === 1 ? "the whole line" : `${n} whole lines`);
  }

  /** Run operator `op` over `r` (expanded to whole lines when `linewise`). */
  private apply(op: string, r: VimRange, linewise: boolean, keys: string, what: string): void {
    if (linewise) {
      const start = this.lineStart(r.location);
      const lastPos = Math.max(r.location, end(r) - 1);
      let e = this.lineEnd(lastPos);
      if (e < this.text.length) e += 1; // include the newline
      r = range(start, e - start);
    }
    const removed = this.text.slice(r.location, end(r));
    const isChange = op !== "y";
    if (isChange && !this.replaying) this.changeKeys = [...this.commandKeys];

    this.buffer.beginChange();
    switch (op) {
      case "y":
        this.setRegister(removed, linewise);
        this.buffer.selection = range(this.clampNormal(r.location), 0);
        break;
      case "d": {
        this.setRegister(removed, linewise);
        let del = r;
        // Deleting the last line also takes the newline before it.
        if (linewise && end(del) === this.text.length && del.location > 0 && !removed.endsWith("\n")) {
          del = range(del.location - 1, del.length + 1);
        }
        this.buffer.replace(del, "");
        const at = Math.min(del.location, Math.max(0, this.text.length - 1));
        this.buffer.selection = range(linewise ? this.firstNonBlank(this.lineStart(at)) : this.clampNormal(at), 0);
        break;
      }
      case "c": {
        this.setRegister(removed, linewise);
        let del = r;
        if (linewise && removed.endsWith("\n")) del = range(del.location, del.length - 1); // keep the (now empty) line
        this.buffer.replace(del, "");
        this.buffer.selection = range(del.location, 0);
        break;
      }
      case ">":
      case "<":
        this.shiftLines(r, op === ">");
        this.buffer.selection = range(this.firstNonBlank(this.lineStart(r.location)), 0);
        break;
    }
    this.buffer.endChange();

    const wasVisual = this.inVisual;
    this.clearPending();
    if (op === "c") {
      this.enterInsert();
    } else {
      this.setMode("NORMAL");
      if (isChange && !this.replaying && !wasVisual && this.changeKeys) this.lastChange = { keys: this.changeKeys, inserted: "" };
      this.changeKeys = null;
    }

    const verb = VimEngine.operatorName[op] ?? op;
    const cap = verb.charAt(0).toUpperCase() + verb.slice(1);
    const text = wasVisual ? `${cap} the selection.` : `${cap} ${what}.`;
    const suffix = op === "c" ? " Now type the new text, then Esc." : "";
    this.report({ keys, text: text + suffix }, op === "c" ? null : this.nextTip());
  }

  private setRegister(s: string, linewise: boolean): void {
    this.register = linewise && !s.endsWith("\n") ? s + "\n" : s;
    this.registerLinewise = linewise;
  }

  private shiftLines(r: VimRange, right: boolean): void {
    const starts: number[] = [];
    let p = r.location;
    while (p < end(r) || (starts.length === 0 && p === r.location)) {
      starts.push(this.lineStart(p));
      const e = this.lineEnd(p);
      if (e >= this.text.length) break;
      p = e + 1;
    }
    for (const s of starts.reverse()) {
      if (right) {
        if (this.lineEnd(s) > s) this.buffer.replace(range(s, 0), "\t");
      } else {
        let len = 0;
        if (s < this.text.length && this.text.charCodeAt(s) === 9) len = 1;
        else while (len < 4 && s + len < this.text.length && this.text.charCodeAt(s + len) === 32) len++;
        if (len > 0) this.buffer.replace(range(s, len), "");
      }
    }
  }

  // -------------------------------------------------------------- Visual mode

  private updateVisualSelection(): void {
    const lo = Math.min(this.visualAnchor, this.visualCursor);
    const hi = Math.max(this.visualAnchor, this.visualCursor);
    if (this._mode === "VISUAL LINE") {
      const start = this.lineStart(lo);
      let e = this.lineEnd(hi);
      if (e < this.text.length) e += 1;
      this.buffer.selection = range(start, e - start);
    } else {
      this.buffer.selection = range(lo, Math.min(this.text.length, hi + 1) - lo);
    }
  }

  private applyVisual(op: string): void {
    this.apply(op, this.buffer.selection, this._mode === "VISUAL LINE", this.pendingKeys, "the selection");
  }

  // ---------------------------------------------------------- simple commands

  private command(key: string, n: number): void {
    const p = this.cursor;
    const keys = this.pendingKeys;
    const startsChange = ["x", "X", "D", "C", "s", "S", "p", "P", "J", "~", "o", "O", "i", "a", "I", "A"].includes(key);
    if (startsChange && this._mode === "NORMAL" && !this.replaying) this.changeKeys = [...this.commandKeys];
    const eol = this.lineEnd(p);

    if (key === "o" && this._mode !== "NORMAL") {
      [this.visualAnchor, this.visualCursor] = [this.visualCursor, this.visualAnchor];
      this.updateVisualSelection();
      this.clearPending();
      return this.report({ keys, text: "Jump to the other end of the selection." }, null);
    }

    switch (key) {
      case "i":
      case "a":
      case "I":
      case "A":
      case "o":
      case "O":
        this.insertCommand(key, p);
        this.report({ keys, text: VimEngine.insertName[key] ?? "Insert." }, "Type, then Esc to get back to Normal mode.");
        return;
      case "v":
      case "V": {
        const target: VimMode = key === "v" ? "VISUAL" : "VISUAL LINE";
        if (this._mode === target) {
          this.setMode("NORMAL");
          this.buffer.selection = range(this.clampNormal(this.visualCursor), 0);
          this.clearPending();
          return this.report({ keys, text: "Visual mode off." }, null);
        }
        if (this._mode === "NORMAL") {
          this.visualAnchor = p;
          this.visualCursor = p;
        }
        this.setMode(target);
        this.updateVisualSelection();
        this.clearPending();
        this.report(
          { keys, text: key === "v" ? "Visual mode: move to select characters." : "Visual Line mode: move to select whole lines." },
          "Then d deletes, y copies, c changes, > indents the selection.",
        );
        return;
      }
      case "x":
        if (this._mode !== "NORMAL") return this.applyVisual("d");
        return this.apply("d", range(p, Math.min(n, eol - p)), false, keys, n === 1 ? "the character under the cursor" : `${n} characters`);
      case "X": {
        const lo = Math.max(this.lineStart(p), p - n);
        return this.apply("d", range(lo, p - lo), false, keys, n === 1 ? "the character before the cursor" : `${n} characters before the cursor`);
      }
      case "D":
        return this.apply("d", range(p, eol - p), false, keys, "to the end of the line");
      case "C":
        return this.apply("c", range(p, eol - p), false, keys, "to the end of the line");
      case "s":
        return this.apply("c", range(p, Math.min(n, eol - p)), false, keys, n === 1 ? "the character under the cursor" : `${n} characters`);
      case "S":
        this.operatorCount = 1;
        return this.linewiseOperator("c", n);
      case "Y":
        return this.linewiseOperator("y", n);
      case "r":
        this.awaiting = { t: "replace" };
        this.countDigits = n > 1 ? String(n) : "";
        this.onFeedback?.(this.feedback, this.tip);
        return;
      case "~":
        return this.toggleCase(n);
      case "J":
        return this.joinLines(Math.max(2, n));
      case "p":
      case "P":
        return this.put(key === "p", n);
      case "u":
        this.buffer.undo();
        this.buffer.selection = range(this.clampNormal(this.buffer.selection.location), 0);
        this.clearPending();
        return this.report({ keys, text: "Undo the last change." }, "Ctrl-r redoes it.");
      case "<C-r>":
        this.buffer.redo();
        this.buffer.selection = range(this.clampNormal(this.buffer.selection.location), 0);
        this.clearPending();
        return this.report({ keys, text: "Redo — bring the undone change back." }, null);
      case ".":
        return this.repeatLastChange();
      case ":":
      case "/":
      case "?":
        if (this._mode !== "NORMAL") {
          this.setMode("NORMAL");
          this.buffer.selection = range(this.clampNormal(this.visualCursor), 0);
        }
        this.commandPrefix = key;
        this.commandLine = "";
        this.setMode("COMMAND");
        this.clearPending();
        return this.report(
          {
            keys: key,
            text:
              key === ":"
                ? "Command line: w save, q quit, wq both, q! quit without saving."
                : `Search ${key === "/" ? "forward" : "backward"}: type the text, then Return. n repeats.`,
          },
          null,
        );
      default:
        if (key === "<CR>" || key === "<BS>") return this.command(key === "<CR>" ? "j" : "h", n);
        this.fail(`${VimEngine.display(key)} — not a Vim command FocusEdit knows. :help lists them.`);
    }
  }

  private insertCommand(key: string, p: number): void {
    this.buffer.beginChange();
    switch (key) {
      case "i":
        this.buffer.selection = range(p, 0);
        break;
      case "a":
        this.buffer.selection = range(this.lineEnd(p) > this.lineStart(p) ? Math.min(p + 1, this.lineEnd(p)) : p, 0);
        break;
      case "I":
        this.buffer.selection = range(this.firstNonBlank(p), 0);
        break;
      case "A":
        this.buffer.selection = range(this.lineEnd(p), 0);
        break;
      case "o": {
        const e = this.lineEnd(p);
        this.buffer.replace(range(e, 0), "\n");
        this.buffer.selection = range(e + 1, 0);
        break;
      }
      case "O": {
        const s = this.lineStart(p);
        this.buffer.replace(range(s, 0), "\n");
        this.buffer.selection = range(s, 0);
        break;
      }
    }
    this.buffer.endChange();
    this.clearPending();
    this.enterInsert();
  }

  private enterInsert(): void {
    this.insertedText = "";
    this.setMode("INSERT");
  }

  private replaceChars(ch: string, n: number): void {
    const p = this.cursor;
    if (p + n > this.lineEnd(p)) return this.fail(`r${ch} — not enough characters on the line.`);
    if (!this.replaying) this.changeKeys = [...this.commandKeys];
    const keys = this.pendingKeys;
    this.buffer.beginChange();
    this.buffer.replace(range(p, n), ch.repeat(n));
    this.buffer.endChange();
    this.buffer.selection = range(p + n - 1, 0);
    this.finishChange();
    this.report(
      { keys, text: `Replace ${n === 1 ? "the character" : `${n} characters`} with “${ch}” — stays in Normal mode.` },
      this.nextTip(),
    );
  }

  private toggleCase(n: number): void {
    const keys = this.pendingKeys;
    if (this._mode !== "NORMAL") {
      const sel = this.buffer.selection;
      this.buffer.beginChange();
      this.buffer.replace(sel, VimEngine.toggled(this.text.slice(sel.location, end(sel))));
      this.buffer.endChange();
      this.setMode("NORMAL");
      this.buffer.selection = range(this.clampNormal(sel.location), 0);
      this.clearPending();
      return this.report({ keys, text: "Switch upper/lower case of the selection." }, null);
    }
    const p = this.cursor;
    const len = Math.min(n, this.lineEnd(p) - p);
    if (len <= 0) return this.clearPending();
    const r = range(p, len);
    this.buffer.beginChange();
    this.buffer.replace(r, VimEngine.toggled(this.text.slice(p, p + len)));
    this.buffer.endChange();
    this.buffer.selection = range(this.clampNormal(p + len), 0);
    this.finishChange();
    this.report({ keys, text: "Switch upper/lower case and move on." }, this.nextTip());
  }

  private joinLines(n: number): void {
    const keys = this.pendingKeys;
    this.buffer.beginChange();
    let joinAt = this.cursor;
    for (let i = 1; i < n; i++) {
      const e = this.lineEnd(joinAt);
      if (e >= this.text.length) break;
      let k = e + 1;
      while (k < this.text.length && isBlankChar(this.text.charCodeAt(k))) k++;
      const atEnd = k >= this.text.length || this.text.charCodeAt(k) === 10;
      this.buffer.replace(range(e, k - e), atEnd ? "" : " ");
      joinAt = e;
    }
    this.buffer.endChange();
    this.buffer.selection = range(this.clampNormal(joinAt), 0);
    this.finishChange();
    this.report({ keys, text: "Join the next line onto this one." }, this.nextTip());
  }

  private put(after: boolean, n: number): void {
    const keys = this.pendingKeys;
    if (this.register === "") {
      this.clearPending();
      return this.fail("Nothing to put yet — copy with y or delete with d first.");
    }
    const p = this.cursor;
    const chunk = this.register.repeat(n);
    this.buffer.beginChange();
    if (this.registerLinewise) {
      let at = after ? this.lineEnd(p) : this.lineStart(p);
      let insert = chunk;
      if (after) {
        if (at < this.text.length) at += 1;
        else insert = "\n" + chunk.slice(0, -1);
      }
      this.buffer.replace(range(at, 0), insert);
      const lineAt = insert.startsWith("\n") ? at + 1 : at;
      this.buffer.selection = range(this.firstNonBlank(lineAt), 0);
    } else {
      const at = after && this.lineEnd(p) > this.lineStart(p) ? Math.min(p + 1, this.lineEnd(p)) : p;
      this.buffer.replace(range(at, 0), chunk);
      this.buffer.selection = range(this.clampNormal(at + chunk.length - 1), 0);
    }
    this.buffer.endChange();
    this.finishChange();
    const what = this.registerLinewise
      ? after ? "the copied line(s) below this one" : "the copied line(s) above this one"
      : after ? "the copied text after the cursor" : "the copied text before the cursor";
    this.report({ keys, text: `Put ${what}.` }, "dd then p moves a line down; yy then p duplicates it.");
  }

  private repeatLastChange(): void {
    const change = this.lastChange;
    if (!change) {
      this.clearPending();
      return this.fail(". repeats the last change — make one first (x, dw, ciw…).");
    }
    const shown = change.keys.map(VimEngine.display).join("");
    this.replaying = true;
    this.clearPending();
    for (const k of change.keys) this.handle(k);
    if (this._mode === "INSERT") {
      for (const ch of change.inserted) this.handle(ch === "\n" ? "<CR>" : ch);
      this.handle("<Esc>");
    }
    this.replaying = false;
    this.report(
      {
        keys: ".",
        text: `Repeat the last change (${shown}${change.inserted === "" ? "" : ` + typing “${change.inserted}”`}).`,
      },
      "Combine with motions: n . n . — find the next match, repeat the fix.",
    );
  }

  private finishChange(): void {
    if (!this.replaying && this.changeKeys) this.lastChange = { keys: this.changeKeys, inserted: "" };
    this.changeKeys = null;
    this.clearPending();
  }

  private search(pattern: string, forward: boolean, count: number, keys: string): void {
    if (pattern === "") return;
    this.lastSearch = { pattern, forward };
    const t = this.find(pattern, this.buffer.selection.location, forward, count);
    if (t === null) {
      return this.report({ keys, text: `Pattern not found: ${pattern}`, isError: true }, null);
    }
    this.buffer.selection = range(t, 0);
    this.report({ keys, text: `Jump to “${pattern}”.` }, "n finds the next one, N the previous.");
  }

  private fail(message: string): void {
    this.clearPending();
    this.report({ keys: "", text: message, isError: true }, null);
  }

  private clearPending(): void {
    this.countDigits = "";
    this.operatorKey = null;
    this.operatorCount = 1;
    this.awaiting = null;
    this.pendingKeys = "";
    this.commandKeys = [];
  }

  private report(fb: VimFeedback, tip: string | null): void {
    if (!this.replaying) {
      this.feedback = fb;
      this.tip = tip;
    }
    this.onFeedback?.(this.feedback, this.tip);
  }

  // ------------------------------------------------------------- text helpers

  private get text(): string {
    return this.buffer.text;
  }

  private get lineCount(): number {
    let n = 1;
    const t = this.text;
    for (let i = 0; i < t.length; i++) if (t.charCodeAt(i) === 10) n++;
    return n;
  }

  private lineStart(p: number): number {
    p = Math.min(Math.max(0, p), this.text.length);
    return p === 0 ? 0 : this.text.lastIndexOf("\n", p - 1) + 1;
  }

  /** Index of the line's "\n" (or the end of the text). */
  private lineEnd(p: number): number {
    p = Math.min(Math.max(0, p), this.text.length);
    const i = this.text.indexOf("\n", p);
    return i < 0 ? this.text.length : i;
  }

  private lastCharPos(p: number): number {
    const s = this.lineStart(p);
    const e = this.lineEnd(p);
    return e > s ? e - 1 : s;
  }

  private clampNormal(p: number): number {
    p = Math.min(Math.max(0, p), this.text.length);
    return Math.min(p, this.lastCharPos(p));
  }

  private firstNonBlank(p: number): number {
    let i = this.lineStart(p);
    const e = this.lineEnd(p);
    while (i < e && isBlankChar(this.text.charCodeAt(i))) i++;
    return Math.min(i, this.lastCharPos(p));
  }

  private lineNumber(p: number): number {
    let n = 1;
    const stop = Math.min(Math.max(0, p), this.text.length);
    for (let i = 0; i < stop; i++) if (this.text.charCodeAt(i) === 10) n++;
    return n;
  }

  private lineStartOf(line: number): number {
    if (line <= 1) return 0;
    let current = 1;
    const t = this.text;
    for (let i = 0; i < t.length; i++) {
      if (t.charCodeAt(i) === 10) {
        current++;
        if (current === line) return i + 1;
      }
    }
    return this.lineStart(t.length);
  }

  /** 0 = blank, 1 = word characters (letters, digits, _), 2 = punctuation.
   *  For WORD motions (W B E) everything that isn't blank is one class. */
  private wordClass(i: number, big: boolean): number {
    if (i < 0 || i >= this.text.length) return 0;
    const c = this.text.charCodeAt(i);
    if (c === 10 || c === 32 || c === 9 || c === 13) return 0;
    if (big) return 1;
    if (c >= 0xd800 && c <= 0xdfff) return 1; // surrogate halves: treat as letters
    return c === 95 || /[\p{L}\p{M}\p{N}]/u.test(String.fromCharCode(c)) ? 1 : 2;
  }

  private isEmptyLine(i: number): boolean {
    return i < this.text.length && this.text.charCodeAt(i) === 10 && (i === 0 || this.text.charCodeAt(i - 1) === 10);
  }

  private nextWordStart(p: number, big: boolean): number {
    let i = p;
    const c0 = this.wordClass(i, big);
    if (c0 !== 0) while (i < this.text.length && this.wordClass(i, big) === c0) i++;
    while (i < this.text.length && this.wordClass(i, big) === 0) {
      if (i > p && this.isEmptyLine(i)) return i; // an empty line is a word of its own
      i++;
    }
    return Math.min(i, this.text.length);
  }

  private wordEnd(p: number, big: boolean): number {
    let i = p + 1;
    while (i < this.text.length && this.wordClass(i, big) === 0) i++;
    if (i >= this.text.length) return Math.max(0, this.text.length - 1);
    const c = this.wordClass(i, big);
    while (i + 1 < this.text.length && this.wordClass(i + 1, big) === c) i++;
    return i;
  }

  private wordEndBackward(p: number, big: boolean): number {
    let i = p;
    const c0 = this.wordClass(i, big);
    while (i > 0 && this.wordClass(i, big) === c0 && c0 !== 0) i--;
    while (i > 0 && this.wordClass(i, big) === 0) i--;
    return Math.max(0, i);
  }

  private wordBack(p: number, big: boolean): number {
    let i = p - 1;
    while (i > 0 && this.wordClass(i, big) === 0) i--;
    if (i <= 0) return 0;
    const c = this.wordClass(i, big);
    while (i > 0 && this.wordClass(i - 1, big) === c) i--;
    return i;
  }

  private nextLineStart(lineStartPos: number): number | null {
    const e = this.lineEnd(lineStartPos);
    return e < this.text.length ? e + 1 : null;
  }

  private isBlankLine(lineStartPos: number): boolean {
    return this.lineEnd(lineStartPos) === lineStartPos;
  }

  /** "}": skip blank lines, then the paragraph, and land on the next blank line. */
  private paragraphForward(p: number): number {
    let line = this.lineStart(p);
    for (;;) {
      const next = this.isBlankLine(line) ? this.nextLineStart(line) : null;
      if (next === null) break;
      line = next;
    }
    while (!this.isBlankLine(line)) {
      const next = this.nextLineStart(line);
      if (next === null) return this.lastCharPos(line);
      line = next;
    }
    return line;
  }

  /** "{": the same, backwards. */
  private paragraphBackward(p: number): number {
    let line = this.lineStart(p);
    while (this.isBlankLine(line) && line > 0) line = this.lineStart(line - 1);
    while (!this.isBlankLine(line)) {
      if (line <= 0) return 0;
      line = this.lineStart(line - 1);
    }
    return line;
  }

  private findChar(kind: string, ch: string, p: number, n: number): number | null {
    const target = ch.charCodeAt(0);
    let found = 0;
    if (kind === "f" || kind === "t") {
      for (let i = p + 1 + (kind === "t" ? 1 : 0); i < this.lineEnd(p); i++) {
        if (this.text.charCodeAt(i) === target && ++found === n) return kind === "f" ? i : i - 1;
      }
    } else {
      for (let i = p - 1 - (kind === "T" ? 1 : 0); i >= this.lineStart(p); i--) {
        if (this.text.charCodeAt(i) === target && ++found === n) return kind === "F" ? i : i + 1;
      }
    }
    return null;
  }

  /** Literal search with smart case (case-insensitive unless the pattern has capitals), wrapping around. */
  private find(pattern: string, p: number, forward: boolean, n: number): number | null {
    const ci = pattern === pattern.toLowerCase();
    const hay = ci ? this.text.toLowerCase() : this.text;
    const needle = ci ? pattern.toLowerCase() : pattern;
    let pos = p;
    for (let i = 0; i < n; i++) {
      let r: number;
      if (forward) {
        r = hay.indexOf(needle, Math.min(pos + 1, hay.length));
        if (r < 0) r = hay.indexOf(needle); // wrap
      } else {
        r = pos - needle.length >= 0 ? hay.lastIndexOf(needle, pos - needle.length) : -1;
        if (r < 0) r = hay.lastIndexOf(needle); // wrap
      }
      if (r < 0) return null;
      pos = r;
    }
    return pos;
  }

  // ------------------------------------------------------------- text objects

  private textObject(kind: string, key: string, p: number): { range: VimRange; linewise: boolean } | null {
    const t = this.text;
    if (t.length === 0 || p >= t.length) return null;
    const inner = kind === "i";
    switch (key) {
      case "w":
      case "W": {
        const big = key === "W";
        const c = this.wordClass(p, big);
        let lo = p;
        let hi = p;
        while (lo > this.lineStart(p) && this.wordClass(lo - 1, big) === c) lo--;
        while (hi + 1 < this.lineEnd(p) && this.wordClass(hi + 1, big) === c) hi++;
        hi++;
        if (!inner) {
          let h = hi;
          while (h < this.lineEnd(p) && isBlankChar(t.charCodeAt(h))) h++;
          if (h > hi) hi = h;
          else while (lo > this.lineStart(p) && isBlankChar(t.charCodeAt(lo - 1))) lo--;
        }
        return { range: range(lo, hi - lo), linewise: false };
      }
      case "p": {
        const blank = this.lineEnd(p) === this.lineStart(p);
        let first = this.lineStart(p);
        let last = this.lineStart(p);
        while (first > 0) {
          const prev = this.lineStart(first - 1);
          if ((this.lineEnd(prev) === prev) !== blank) break;
          first = prev;
        }
        while (this.lineEnd(last) < t.length) {
          const next = this.lineEnd(last) + 1;
          if ((this.lineEnd(next) === next) !== blank) break;
          last = next;
        }
        if (!inner) {
          while (this.lineEnd(last) < t.length) {
            const next = this.lineEnd(last) + 1;
            if (this.lineEnd(next) !== next) break;
            last = next;
          }
        }
        return { range: range(first, this.lineEnd(last) - first), linewise: true };
      }
      case '"':
      case "'":
      case "`": {
        const q = key.charCodeAt(0);
        const s = this.lineStart(p);
        const e = this.lineEnd(p);
        let open = -1;
        for (let i = p; i >= s; i--) {
          if (t.charCodeAt(i) === q) {
            open = i;
            break;
          }
        }
        if (open < 0) return null;
        let close = -1;
        for (let i = open === p ? p + 1 : p; i < e; i++) {
          if (t.charCodeAt(i) === q && i !== open) {
            close = i;
            break;
          }
        }
        if (close < 0) return null;
        return inner
          ? { range: range(open + 1, close - open - 1), linewise: false }
          : { range: range(open, close - open + 1), linewise: false };
      }
      case "(":
      case ")":
      case "b":
      case "[":
      case "]":
      case "{":
      case "}":
      case "B": {
        const pairs: Record<string, [number, number]> = {
          "(": [40, 41], ")": [40, 41], b: [40, 41],
          "[": [91, 93], "]": [91, 93],
          "{": [123, 125], "}": [123, 125], B: [123, 125],
        };
        const [openCh, closeCh] = pairs[key];
        let depth = 0;
        let o = p;
        if (p < t.length && t.charCodeAt(p) === closeCh) depth = -1;
        while (o >= 0) {
          const c = t.charCodeAt(Math.min(o, t.length - 1));
          if (c === closeCh && o !== p) depth++;
          if (c === openCh) {
            if (depth === 0) break;
            depth--;
          }
          o--;
        }
        if (o < 0) return null;
        depth = 0;
        let c = o + 1;
        while (c < t.length) {
          const ch = t.charCodeAt(c);
          if (ch === openCh) depth++;
          if (ch === closeCh) {
            if (depth === 0) break;
            depth--;
          }
          c++;
        }
        if (c >= t.length) return null;
        return inner
          ? { range: range(o + 1, c - o - 1), linewise: false }
          : { range: range(o, c - o + 1), linewise: false };
      }
      default:
        return null;
    }
  }

  // ------------------------------------------------------------- explanations

  private static readonly operatorName: Record<string, string> = {
    d: "delete", c: "change (delete, then type)", y: "copy (yank)", ">": "indent", "<": "unindent",
  };

  private static readonly insertName: Record<string, string> = {
    i: "Insert before the cursor.", a: "Append after the cursor.",
    I: "Insert at the start of the line.", A: "Append at the end of the line.",
    o: "Open a new line below and insert.", O: "Open a new line above and insert.",
  };

  private static readonly arrowAsKey: Record<string, string> = {
    "<Left>": "h", "<Right>": "l", "<Up>": "k", "<Down>": "j",
  };

  static motionName(key: string, n: number): string {
    const times = n > 1 ? ` ×${n}` : "";
    let base: string;
    switch (key) {
      case "h": case "<Left>": base = "one character left"; break;
      case "l": case "<Right>": case " ": base = "one character right"; break;
      case "j": case "<Down>": base = "one line down"; break;
      case "k": case "<Up>": base = "one line up"; break;
      case "w": base = "to the start of the next word"; break;
      case "W": base = "to the start of the next WORD (anything between spaces)"; break;
      case "e": base = "to the end of the word"; break;
      case "E": base = "to the end of the WORD"; break;
      case "b": base = "back to the start of the word"; break;
      case "B": base = "back to the start of the WORD"; break;
      case "ge": base = "back to the end of the previous word"; break;
      case "0": base = "to the very start of the line"; break;
      case "^": base = "to the first non-blank character of the line"; break;
      case "$": base = "to the end of the line"; break;
      case "gg": return n > 1 ? `to line ${n}` : "to the first line";
      case "G": return n > 1 ? `to line ${n}` : "to the last line";
      case "}": base = "to the next blank line (end of paragraph)"; break;
      case "{": base = "to the previous blank line (start of paragraph)"; break;
      case ";": base = "to the next match of the last f/t"; break;
      case ",": base = "to the previous match of the last f/t"; break;
      case "n": base = "to the next search match"; break;
      case "N": base = "to the previous search match"; break;
      default: {
        const chars = [...key];
        if (chars.length === 2) {
          const [k, c] = chars;
          switch (k) {
            case "f": base = `to the next “${c}” on the line`; break;
            case "F": base = `back to the previous “${c}”`; break;
            case "t": base = `up to (just before) the next “${c}”`; break;
            case "T": base = `back to just after the previous “${c}”`; break;
            default: base = key;
          }
        } else {
          base = key;
        }
      }
    }
    return base + times;
  }

  static objectName(kind: string, key: string): string {
    const inside = kind === "i";
    switch (key) {
      case "w": return inside ? "the word under the cursor" : "the word and the space after it";
      case "W": return inside ? "the WORD under the cursor" : "the WORD and the space after it";
      case "p": return inside ? "the paragraph" : "the paragraph and the blank lines after it";
      case '"': return inside ? "the text inside the double quotes" : "the double-quoted text, quotes included";
      case "'": return inside ? "the text inside the single quotes" : "the single-quoted text, quotes included";
      case "(": case ")": case "b": return inside ? "the text inside the parentheses" : "the parentheses and what's inside";
      case "[": case "]": return inside ? "the text inside the brackets" : "the brackets and what's inside";
      case "{": case "}": case "B": return inside ? "the text inside the braces" : "the braces and what's inside";
      default: return `${kind}${key}`;
    }
  }

  static display(key: string): string {
    switch (key) {
      case "<Esc>": return "Esc";
      case "<CR>": return "⏎";
      case "<BS>": return "⌫";
      case "<C-r>": return "Ctrl-r";
      case "<Left>": return "←";
      case "<Right>": return "→";
      case "<Up>": return "↑";
      case "<Down>": return "↓";
      case " ": return "␣";
      default: return key;
    }
  }

  private static toggled(s: string): string {
    return [...s].map((ch) => (ch === ch.toUpperCase() ? ch.toLowerCase() : ch.toUpperCase())).join("");
  }

  private static readonly tips = [
    "ciw changes the word under the cursor — from anywhere inside it.",
    "dd deletes a line, p puts it below: dd p swaps two lines.",
    ". repeats your last change. Fix one place, then move and press .",
    "f then a letter jumps to it on this line; ; jumps to the next one.",
    "A appends at the end of the line, I inserts at its start.",
    "Counts work everywhere: 3j, d2w, 5x.",
    'di" deletes inside quotes, da( deletes a whole (…) group.',
    "u undoes, Ctrl-r redoes.",
    "Grammar: operator + motion. d$ = delete to line end, y} = copy to paragraph end.",
    "o opens a new line below, O above — no need to go to the line end first.",
    "V then j j selects whole lines; > indents them.",
    ":w saves, :wq saves and closes, :q! closes without saving.",
  ];

  private nextTip(): string {
    this.tipIndex = (this.tipIndex + 1) % VimEngine.tips.length;
    return VimEngine.tips[this.tipIndex];
  }
}

/** ЙЦУКЕН → QWERTY by physical key position (like NeoVim's langmap). */
export const langmap: Record<string, string> = (() => {
  const ru = "йцукенгшщзхъфывапролджэячсмитьбю" + "ЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ" + "ёЁ";
  const en = "qwertyuiop[]asdfghjkl;'zxcvbnm,." + 'QWERTYUIOP{}ASDFGHJKL:"ZXCVBNM<>' + "`~";
  const map: Record<string, string> = {};
  [...ru].forEach((r, i) => (map[r] = en[i]));
  return map;
})();
