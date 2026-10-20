import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorSelection, EditorState } from "@codemirror/state";
import { describe, expect, it } from "vitest";
import { liveItems } from "../src/live";

/** What is hidden, written as the hidden text itself. */
function hiddenText(doc: string, cursor: number | [number, number]): string[] {
  const selection = Array.isArray(cursor) ? EditorSelection.range(cursor[0], cursor[1]) : EditorSelection.cursor(cursor);
  const state = EditorState.create({ doc, selection, extensions: [markdown({ base: markdownLanguage })] });
  return liveItems(state, 0, doc.length)
    .filter((i) => i.type === "hide")
    .map((i) => (i.type === "hide" ? doc.slice(i.from, i.to) : ""))
    .sort();
}

const items = (doc: string, cursor = doc.length) => {
  const state = EditorState.create({ doc, selection: EditorSelection.cursor(cursor), extensions: [markdown({ base: markdownLanguage })] });
  return liveItems(state, 0, doc.length);
};

describe("live Markdown: what is hidden", () => {
  const doc = "# Title\n\nSome **bold**, *it* and `code` here.\n";
  const away = doc.length; // the end of the text, far from the formatting

  it("hides the # of a heading (and its space) away from the cursor", () => {
    expect(hiddenText("# Title\n\ntext", 13)).toContain("# ");
  });

  it("shows it again while the cursor is on that line", () => {
    expect(hiddenText("# Title\n\ntext", 3)).not.toContain("# ");
    expect(hiddenText("# Title\n\ntext", 0)).not.toContain("# ");
  });

  it("hides bold, italic and code marks away from the cursor", () => {
    expect(hiddenText(doc, away)).toEqual(["# ", "*", "*", "**", "**", "`", "`"].sort());
  });

  it("shows the marks of the element the cursor is in or touches", () => {
    const inBold = doc.indexOf("bold") + 1;
    const hidden = hiddenText(doc, inBold);
    expect(hidden).not.toContain("**");
    expect(hidden).toContain("`"); // the others stay hidden
    const atEdge = doc.indexOf("**bold**") + "**bold**".length; // right after the closing **
    expect(hiddenText(doc, atEdge)).not.toContain("**");
  });

  it("shows the marks of anything the selection reaches", () => {
    const from = doc.indexOf("bold");
    expect(hiddenText(doc, [from, from + 2])).not.toContain("**");
  });

  it("hides the brackets and the address of a link, keeping its text", () => {
    const md = "see [the docs](https://example.com/a) now\n\nend";
    const hidden = hiddenText(md, md.length);
    expect(hidden).toEqual(["[", "](https://example.com/a)"].sort());
    expect(hiddenText(md, md.indexOf("docs"))).toEqual([]);
  });

  it("hides the marks of an image and styles its description", () => {
    const md = "![a cat](cat.png)\n\nend";
    const all = items(md, md.length);
    expect(all.filter((i) => i.type === "hide")).toHaveLength(2);
    expect(all.some((i) => i.type === "mark" && md.slice(i.from, i.to) === "a cat")).toBe(true);
  });

  it("hides the brackets of an autolink", () => {
    expect(hiddenText("<https://a.b>\n\nend", 17)).toEqual(["<", ">"]);
  });

  it("gives every heading its size class, wherever the cursor is", () => {
    const md = "# One\n\n### Three\n\nend";
    for (const cursor of [0, 10, md.length]) {
      const lines = items(md, cursor).filter((i) => i.type === "line").map((i) => (i.type === "line" ? i.cls : ""));
      expect(lines).toEqual(["cm-md-h1", "cm-md-h3"]);
    }
  });

  it("leaves lists, quotes and code blocks alone", () => {
    expect(hiddenText("- item\n\n> quote\n\n```\ncode\n```\n\nend", 30)).toEqual([]);
  });

  it("hides nothing in text that is not Markdown", () => {
    const state = EditorState.create({ doc: "# not markdown **here**", selection: EditorSelection.cursor(0) });
    expect(liveItems(state, 0, state.doc.length)).toEqual([]);
  });
});
