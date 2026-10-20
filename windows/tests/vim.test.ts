// The Vim engine on a headless CodeMirror state (the same buffer the app uses).
// Mirrors the Vim checks in SelfTest.swift on macOS.

import { history } from "@codemirror/commands";
import { EditorSelection, EditorState, type Transaction } from "@codemirror/state";
import { describe, expect, it } from "vitest";
import { type VimAction, VimEngine } from "../src/vim";
import { CmVimBuffer, joinVimEdits, vimToken } from "../src/vim-cm";

class Host {
  state: EditorState;
  constructor(doc: string, cursor: number) {
    this.state = EditorState.create({
      doc,
      selection: EditorSelection.cursor(cursor),
      extensions: [history({ joinToEvent: joinVimEdits })],
    });
  }
  dispatch(tr: Transaction): void {
    this.state = tr.state;
  }
}

/** Keys are space separated; "+text" is typing in Insert mode ("_" is a space);
 *  a multi-character token such as "dw" is fed key by key, "<Esc>" is one key. */
function session(text: string, keys: string, cursor = 0) {
  const host = new Host(text, cursor);
  const vim = new VimEngine(new CmVimBuffer(host));
  for (const token of keys.split(" ").filter(Boolean)) {
    if (token.startsWith("+")) {
      const typed = token.slice(1).replaceAll("_", " ");
      vim.buffer.replace(vim.buffer.selection, typed);
      vim.noteInserted(typed, 0);
    } else if (token.length > 1 && !/^<[A-Za-z-]+>$/.test(token)) {
      for (const ch of token) vim.handle(ch);
    } else {
      vim.handle(token);
    }
  }
  const result = `${host.state.doc.toString()}|${host.state.selection.main.head}`;
  return { vim, host, result };
}

const run = (text: string, keys: string, cursor = 0) => session(text, keys, cursor).result;

describe("Vim motions", () => {
  it("w moves to the next word", () => expect(run("hello world", "w")).toBe("hello world|6"));
  it("b and e", () => expect(run("one two three", "b e", 8)).toBe("one two three|6"));
  it("3w with a count", () => expect(run("a b c d e", "3w")).toBe("a b c d e|6"));
  it("$ goes to the last character", () => expect(run("abc\ndef", "$")).toBe("abc\ndef|2"));
  it("f then ;", () => expect(run("a,b,c", "f, ;")).toBe("a,b,c|3"));
  it("G goes to the last line", () => expect(run("a\nb\nc", "G", 2)).toBe("a\nb\nc|4"));
  it("4G goes to a line", () => expect(run("a\nb\nc\nd\ne", "4G")).toBe("a\nb\nc\nd\ne|6"));
  it("} jumps to the blank line", () => expect(run("a\nb\n\nc", "}")).toBe("a\nb\n\nc|4"));
  it("{ jumps back", () => expect(run("a\n\nb\nc", "{", 5)).toBe("a\n\nb\nc|2"));
  it("/ searches", () => expect(run("hello world wide", "/ w o r <CR>")).toBe("hello world wide|6"));
  it("n repeats the search", () => expect(run("x a x a x", "/ x <CR> n")).toBe("x a x a x|8"));
  it("ge goes to the end of the previous word", () => expect(run("one two", "ge", 5)).toBe("one two|2"));
  it("j keeps the column", () => expect(run("abcd\nx\nabcd", "3l j j")).toBe("abcd\nx\nabcd|10"));
});

describe("Vim operators", () => {
  it("dw deletes a word", () => expect(run("hello world", "dw")).toBe("world|0"));
  it("dw on the last word keeps the newline", () => expect(run("one two\nthree", "dw", 4)).toBe("one \nthree|3"));
  it("d2w deletes two words", () => expect(run("a b c d", "d2w")).toBe("c d|0"));
  it("cw + typing", () => expect(run("hello world", "cw +bye <Esc>")).toBe("bye world|2"));
  it("ciw from inside the word", () => expect(run("hello world", "ciw +there <Esc>", 8)).toBe("hello there|10"));
  it("dd deletes the line", () => expect(run("a\nb\nc", "dd", 2)).toBe("a\nc|2"));
  it("2dd deletes two lines", () => expect(run("a\nb\nc", "2dd")).toBe("c|0"));
  it("dd on the last line", () => expect(run("a\nb", "dd", 2)).toBe("a|0"));
  it("yyp duplicates a line", () => expect(run("a\nb", "yy p")).toBe("a\na\nb|2"));
  it("ddp swaps lines", () => expect(run("a\nb\nc", "dd p")).toBe("b\na\nc|2"));
  it("dt, deletes up to the comma", () => expect(run("foo, bar", "dt,")).toBe(", bar|0"));
  it("yiw then P", () => expect(run("ab cd", "yiw 0 P", 3)).toBe("cdab cd|1"));
  it(">> indents", () => expect(run("a\nb", ">>")).toBe("\ta\nb|1"));
  it("<< unindents", () => expect(run("\ta", "<<")).toBe("a|0"));
  it("d$ deletes to the line end", () => expect(run("abc def\nx", "d$", 3)).toBe("abc\nx|2"));
});

describe("Vim text objects", () => {
  it('di" inside quotes', () => expect(run('say "hi there" now', 'di"', 6)).toBe('say "" now|5'));
  it("da( deletes the group", () => expect(run("f(a, b) x", "da(", 2)).toBe("f x|1"));
  it("ci( changes inside", () => expect(run("f(a, b)", "ci( +x <Esc>", 3)).toBe("f(x)|2"));
  it("daw takes the space after", () => expect(run("one two three", "daw", 4)).toBe("one three|4"));
  it("dip deletes a paragraph", () => expect(run("a\nb\n\nc", "dip")).toBe("\nc|0"));
});

describe("Vim commands", () => {
  it("x and . repeat", () => expect(run("abc", "x .")).toBe("c|0"));
  it("3x", () => expect(run("abcdef", "3x")).toBe("def|0"));
  it("J joins lines", () => expect(run("a\n  b", "J")).toBe("a b|1"));
  it("u undoes, Ctrl-r redoes", () => {
    expect(run("hello world", "dw u")).toBe("hello world|0");
    expect(run("hello world", "dw u <C-r>")).toBe("world|0");
  });
  it("u undoes a whole multi-edit command at once", () => expect(run("a\nb\nc", "V 2j > u")).toBe("a\nb\nc|0"));
  it("~ toggles case", () => expect(run("abc", "~")).toBe("Abc|1"));
  it("r replaces a character", () => expect(run("abc", "rX")).toBe("Xbc|0"));
  it("A appends at the line end", () => expect(run("ab\ncd", "A +! <Esc>")).toBe("ab!\ncd|2"));
  it("i inserts before the cursor", () => expect(run("ab", "i +x <Esc>", 1)).toBe("axb|1"));
  it("o opens a line, and . repeats it", () => expect(run("a", "o +b <Esc> .")).toBe("a\nb\nb|4"));
  it("v l d deletes the selection", () => expect(run("abc\ndef", "v l d")).toBe("c\ndef|0"));
  it("V j d deletes whole lines", () => expect(run("a\nb\nc", "V j d", 2)).toBe("a|0"));
  it("Esc in Visual mode keeps the text", () => expect(run("abc", "v l <Esc>")).toBe("abc|1"));
});

describe("Vim command line and coaching", () => {
  const actionFor = (cmd: string): VimAction | undefined => {
    const { vim } = session("text", "");
    let action: VimAction | undefined;
    vim.onAction = (a) => (action = a);
    for (const k of [":", ...cmd, "<CR>"]) vim.handle(k);
    return action;
  };

  it(":w saves", () => expect(actionFor("w")).toBe("save"));
  it(":wq saves and closes", () => expect(actionFor("wq")).toBe("saveAndClose"));
  it(":q! discards", () => expect(actionFor("q!")).toBe("discardAndClose"));
  it(":novim leaves Vim mode", () => expect(actionFor("novim")).toBe("exitVim"));
  it(":3 goes to a line", () => expect(run("a\nb\nc", ": 3 <CR>")).toBe("a\nb\nc|4"));

  it("explains d2w", () => expect(session("a b c d", "d2w").vim.feedback?.text).toBe("Delete to the start of the next word ×2."));
  it("suggests a count after 4× l", () =>
    expect(session("abcdefgh", "l l l l").vim.tip).toBe("Pressed l 4 times? 4l does it in one go."));
  it("an unknown key is an error", () => expect(session("abc", "q").vim.feedback?.isError).toBe(true));

  it("tracks the mode", () => {
    const { vim } = session("abc", "");
    const modes: string[] = [];
    vim.onModeChange = (m) => modes.push(m);
    for (const k of ["i", "<Esc>", "v", "<Esc>", ":", "<Esc>"]) vim.handle(k);
    expect(modes).toEqual(["INSERT", "NORMAL", "VISUAL", "NORMAL", "COMMAND", "NORMAL"]);
  });
});

describe("Vim keyboard", () => {
  const info = (k: string, mods: Partial<{ ctrlKey: boolean; altKey: boolean; metaKey: boolean }> = {}) => ({
    key: k,
    ctrlKey: false,
    altKey: false,
    metaKey: false,
    ...mods,
  });
  const normal = { mode: "NORMAL", wantsLiteralCharacter: false } as const;

  it("maps special keys", () => {
    expect(vimToken(info("Escape"), normal)).toBe("<Esc>");
    expect(vimToken(info("Enter"), normal)).toBe("<CR>");
    expect(vimToken(info("ArrowDown"), normal)).toBe("<Down>");
  });
  it("Ctrl+R is redo, Ctrl+[ is Esc, other Ctrl combos are left alone", () => {
    expect(vimToken(info("r", { ctrlKey: true }), normal)).toBe("<C-r>");
    expect(vimToken(info("[", { ctrlKey: true }), normal)).toBe("<Esc>");
    expect(vimToken(info("s", { ctrlKey: true }), normal)).toBeNull();
    expect(vimToken(info("x", { metaKey: true }), normal)).toBeNull();
  });
  it("Russian layout works by physical key", () => {
    expect(vimToken(info("о"), normal)).toBe("j");
    expect(vimToken(info("ц"), normal)).toBe("w");
    expect(vimToken(info("о"), { mode: "INSERT", wantsLiteralCharacter: false })).toBe("о");
    // The target of f/t/r and search text stay as typed.
    expect(vimToken(info("о"), { mode: "NORMAL", wantsLiteralCharacter: true })).toBe("о");
  });
});
