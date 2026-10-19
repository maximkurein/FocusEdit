// Editing behaviour checked on a headless EditorState (no DOM needed).

import { closeBrackets, deleteBracketPair, insertBracket } from "@codemirror/autocomplete";
import { insertNewlineContinueMarkup, markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorSelection, EditorState, type Extension, type StateCommand, type Transaction } from "@codemirror/state";
import { describe, expect, it } from "vitest";
import { wrapWith } from "../src/editor";
import { sentenceRange } from "../src/focus";
import { acceptGhost, dismissGhost, ghostField, inlineCompletion } from "../src/ghost";

const pairs = EditorState.languageData.of(() => [{ closeBrackets: { brackets: ["(", "[", "{", '"', "`", "«"] } }]);

function stateAt(doc: string, cursor = doc.length, extensions: Extension[] = []): EditorState {
  return EditorState.create({ doc, selection: EditorSelection.cursor(cursor), extensions });
}

function run(state: EditorState, command: StateCommand): EditorState {
  let next = state;
  command({ state, dispatch: (tr: Transaction) => (next = tr.state) });
  return next;
}

function show(state: EditorState): string {
  const { head } = state.selection.main;
  const text = state.doc.toString();
  return text.slice(0, head) + "|" + text.slice(head);
}

describe("Markdown list continuation (Enter)", () => {
  const md = markdown({ base: markdownLanguage });
  const enter = (doc: string) => show(run(stateAt(doc, doc.length, [md]), insertNewlineContinueMarkup));

  it("continues a bullet list", () => expect(enter("- item")).toBe("- item\n- |"));
  it("increments a numbered list", () => expect(enter("9. nine")).toBe("9. nine\n10. |"));
  it("continues a task as unchecked", () => expect(enter("- [x] done")).toBe("- [x] done\n- [ ] |"));
  it("continues a quote", () => expect(enter("> quote")).toBe("> quote\n> |"));
  it("ends the list on an empty item", () => expect(enter("- item\n- ")).not.toContain("- \n- "));
});

describe("Automatic pairing", () => {
  const typeChar = (state: EditorState, ch: string) => insertBracket(state, ch)?.state ?? null;

  it("closes a bracket", () => {
    const s = typeChar(stateAt("", 0, [closeBrackets(), pairs]), "(");
    expect(s && show(s)).toBe("(|)");
  });

  it("types over the closer it inserted itself", () => {
    // CodeMirror only steps over closers it added (it tracks them), never a ")" already in the text.
    const opened = typeChar(stateAt("", 0, [closeBrackets(), pairs]), "(");
    const s = opened && typeChar(opened, ")");
    expect(s && show(s)).toBe("()|");
  });

  it("wraps a selection", () => {
    const base = EditorState.create({
      doc: "word",
      selection: EditorSelection.range(0, 4),
      extensions: [closeBrackets(), pairs],
    });
    expect(typeChar(base, '"')?.doc.toString()).toBe('"word"');
  });

  it("does not double a quote right after a word", () => {
    expect(typeChar(stateAt("12", 2, [closeBrackets(), pairs]), '"')).toBeNull();
  });

  it("Backspace removes an empty pair", () => {
    expect(show(run(stateAt("()", 1, [closeBrackets(), pairs]), deleteBracketPair))).toBe("|");
  });
});

describe("Inline completion (ghost)", () => {
  const ext = inlineCompletion({
    enabled: () => true,
    provider: (prefix) => (prefix === "Mark" ? "down" : null),
  });

  function typed(doc: string, ch: string): EditorState {
    const state = stateAt(doc, doc.length, [ext]);
    return state.update({
      changes: { from: doc.length, insert: ch },
      selection: EditorSelection.cursor(doc.length + 1),
      userEvent: "input.type",
    }).state;
  }

  it("shows a suggestion after typing at the end of a line", () => {
    expect(typed("Mar", "k").field(ghostField)?.text).toBe("down");
  });

  it("Tab accepts it", () => {
    expect(show(run(typed("Mar", "k"), acceptGhost))).toBe("Markdown|");
  });

  it("Esc dismisses it", () => {
    expect(run(typed("Mar", "k"), dismissGhost).field(ghostField)).toBeNull();
  });

  it("not in the middle of a line", () => {
    const state = stateAt("Mar tail", 3, [ext]).update({
      changes: { from: 3, insert: "k" },
      selection: EditorSelection.cursor(4),
      userEvent: "input.type",
    }).state;
    expect(state.field(ghostField)).toBeNull();
  });

  it("not for pasted text", () => {
    const state = stateAt("Mar", 3, [ext]).update({
      changes: { from: 3, insert: "k" },
      selection: EditorSelection.cursor(4),
      userEvent: "input.paste",
    }).state;
    expect(state.field(ghostField)).toBeNull();
  });
});

describe("Formatting and focus helpers", () => {
  it("Ctrl+B wraps the selection in **", () => {
    const base = EditorState.create({ doc: "bold", selection: EditorSelection.range(0, 4) });
    expect(run(base, wrapWith("**", "**")).doc.toString()).toBe("**bold**");
  });

  it("finds the sentence around the cursor", () => {
    const line = "One two. Three four. Five.";
    const [s, e] = sentenceRange(line, 12);
    expect(line.slice(s, e).trim()).toBe("Three four.");
  });
});
