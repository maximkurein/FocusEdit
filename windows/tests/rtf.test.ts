import { describe, expect, it } from "vitest";
import { markdownToRtf, rtfToMarkdown } from "../src/rtf";

const roundTrip = (md: string) => rtfToMarkdown(markdownToRtf(md)).markdown;

describe("Markdown → RTF", () => {
  it("writes a valid RTF envelope with a font table", () => {
    const rtf = markdownToRtf("Hello");
    expect(rtf.startsWith("{\\rtf1\\ansi")).toBe(true);
    expect(rtf).toContain("{\\fonttbl");
    expect(rtf.trimEnd().endsWith("}")).toBe(true);
  });

  it("escapes control characters and non-ASCII text", () => {
    const rtf = markdownToRtf("a \\ b { c } Привет");
    expect(rtf).toContain("a \\\\ b \\{ c \\}");
    expect(rtf).not.toMatch(/[Ѐ-ӿ]/);
    expect(rtf).toContain("\\u");
  });
});

describe("RTF round trip", () => {
  it("keeps paragraphs", () => {
    expect(roundTrip("First paragraph.\n\nSecond paragraph.")).toBe("First paragraph.\n\nSecond paragraph.");
  });

  it("keeps headings of level 1 to 3", () => {
    expect(roundTrip("# One\n\n## Two\n\n### Three\n\nText")).toBe("# One\n\n## Two\n\n### Three\n\nText");
  });

  it("keeps bold, italic, strikethrough and code", () => {
    expect(roundTrip("a **bold** and *italic* and ~~gone~~ and `code`")).toBe("a **bold** and *italic* and ~~gone~~ and `code`");
  });

  it("keeps links", () => {
    expect(roundTrip("see [the site](https://example.com/x) now")).toBe("see [the site](https://example.com/x) now");
  });

  it("keeps bullet, numbered and nested lists", () => {
    const md = "- one\n- two\n  - nested\n- three\n\n1. first\n2. second";
    expect(roundTrip(md)).toBe(md);
  });

  it("keeps quotes", () => {
    expect(roundTrip("> quoted words")).toBe("> quoted words");
  });

  it("keeps Russian and other non-ASCII text", () => {
    expect(roundTrip("# Заметка\n\nПривет, мир! — «тест» ✓ 😀")).toBe("# Заметка\n\nПривет, мир! — «тест» ✓ 😀");
  });

  it("keeps the headings of a template that has empty list items", () => {
    expect(roundTrip("## Agenda\n\n- \n- ")).toContain("## Agenda");
  });

  it("turns a code block into monospaced paragraphs and back", () => {
    expect(roundTrip("```\nlet a = 1;\nlet b = 2;\n```")).toBe("```\nlet a = 1;\nlet b = 2;\n```");
  });
});

describe("RTF from other programs", () => {
  it("reads WordPad-style text with \\'hh escapes and \\uN", () => {
    const rtf = "{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\fnil Calibri;}}\\f0\\fs22 caf\\'e9 \\u1055?\\u1088?\\par}";
    expect(rtfToMarkdown(rtf).markdown).toBe("café Пр");
  });

  it("reports underline, colours, images and tables as lost", () => {
    const rtf = "{\\rtf1\\ansi{\\colortbl;\\red255\\green0\\blue0;}\\cf1 red {\\ul under}\\par{\\pict\\pngblip 89504e47}\\trowd\\cell\\row}";
    const lost = rtfToMarkdown(rtf).lost;
    expect(lost).toEqual(expect.arrayContaining(["colours", "underline", "images", "tables"]));
  });

  it("does not report a link's underline as lost", () => {
    const rtf = markdownToRtf("a [link](https://example.com) here");
    expect(rtfToMarkdown(rtf).lost).toEqual([]);
  });

  it("handles an empty document", () => {
    expect(rtfToMarkdown("{\\rtf1\\ansi}").markdown).toBe("");
  });
});
