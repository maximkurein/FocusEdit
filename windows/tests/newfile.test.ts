import { describe, expect, it } from "vitest";
import {
  cleanName,
  defaultName,
  fileContents,
  fileName,
  freeName,
  isoDate,
  joinPath,
  startingText,
} from "../src/newfile";
import { rtfToMarkdown } from "../src/rtf";

describe("names", () => {
  it("adds the extension of the chosen format", () => {
    expect(fileName("notes", "md")).toBe("notes.md");
    expect(fileName("notes", "txt")).toBe("notes.txt");
    expect(fileName("notes", "rtf")).toBe("notes.rtf");
  });

  it("does not double an extension the user typed", () => {
    expect(fileName("notes.md", "md")).toBe("notes.md");
    expect(fileName("notes.txt", "md")).toBe("notes.md");
  });

  it("removes characters Windows forbids", () => {
    expect(cleanName('a<b>c:d"e/f\\g|h?i*j')).toBe("a b c d e f g h i j");
  });

  it("falls back to Untitled and avoids reserved names", () => {
    expect(cleanName("   ")).toBe("Untitled");
    expect(cleanName("...")).toBe("Untitled");
    expect(cleanName("con")).toBe("_con");
    expect(cleanName("LPT1")).toBe("_LPT1");
  });

  it("keeps Russian names and trims trailing dots and spaces", () => {
    expect(cleanName("  Заметка про дом. ")).toBe("Заметка про дом");
  });

  it("offers a dated default name", () => {
    expect(defaultName("note", "2026-10-21")).toBe("Note 2026-10-21");
    expect(defaultName("blank", "2026-10-21")).toBe("Untitled");
  });

  it("formats a local date", () => {
    expect(isoDate(new Date(2026, 0, 5))).toBe("2026-01-05");
  });

  it("finds a free name by counting", async () => {
    const taken = new Set(["a.md", "a (2).md"]);
    expect(await freeName("a.md", async (n) => taken.has(n))).toBe("a (3).md");
    expect(await freeName("b.md", async (n) => taken.has(n))).toBe("b.md");
  });

  it("joins paths with the folder's own separator", () => {
    expect(joinPath("C:\\Users\\me\\Documents", "a.md")).toBe("C:\\Users\\me\\Documents\\a.md");
    expect(joinPath("/home/me", "a.md")).toBe("/home/me/a.md");
    expect(joinPath("C:\\x\\", "a.md")).toBe("C:\\x\\a.md");
  });
});

describe("starting text", () => {
  it("is empty for a blank file in every format", () => {
    for (const format of ["txt", "md", "rtf"] as const) expect(startingText("blank", format, "x", "2026-10-21")).toBe("");
  });

  it("is Markdown for md and rtf", () => {
    const text = startingText("note", "md", "Trip", "2026-10-21");
    expect(text).toBe("# Trip\n\n2026-10-21\n");
    expect(startingText("note", "rtf", "Trip", "2026-10-21")).toBe(text);
  });

  it("has no Markdown marks in plain text", () => {
    const text = startingText("meeting", "txt", "Weekly", "2026-10-21");
    expect(text).toContain("WEEKLY");
    expect(text).not.toMatch(/^#|\*\*/m);
    expect(text).toContain("[ ]");
  });

  it("builds a to-do list with checkboxes", () => {
    expect(startingText("todo", "md", "Today", "2026-10-21")).toContain("- [ ] First thing");
  });

  it("uses the cleaned name as the title", () => {
    expect(startingText("note", "md", "a/b.md", "2026-10-21").startsWith("# a b\n")).toBe(true);
  });
});

describe("file contents", () => {
  it("writes text as it is for txt and md", () => {
    expect(fileContents("txt", "x")).toBe("x");
    expect(fileContents("md", "# x")).toBe("# x");
  });

  it("writes RTF that reads back as the same Markdown", () => {
    const text = startingText("meeting", "rtf", "Weekly", "2026-10-21");
    const rtf = fileContents("rtf", text);
    expect(rtf.startsWith("{\\rtf1")).toBe(true);
    const back = rtfToMarkdown(rtf).markdown;
    expect(back).toContain("# Weekly");
    expect(back).toContain("## Agenda");
    expect(back).toContain("Date: 2026-10-21");
  });
});
