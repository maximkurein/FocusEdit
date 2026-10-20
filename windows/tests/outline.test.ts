import { describe, expect, it } from "vitest";
import { activeHeading, extractHeadings } from "../src/outline";

const titles = (text: string, kind: "markdown" | "plain" | "fountain" = "markdown") =>
  extractHeadings(text, kind).map((h) => `${h.level}:${h.line}:${h.title}`);

describe("outline: headings", () => {
  it("finds ATX headings with level and line", () => {
    expect(titles("# One\n\ntext\n\n## Two ##\n### Three")).toEqual(["1:1:One", "2:5:Two", "3:6:Three"]);
  });

  it("needs a space after the hashes and some text", () => {
    expect(titles("#nospace\n#\n# \n####### seven")).toEqual([]);
  });

  it("finds Setext headings", () => {
    expect(titles("Title\n=====\n\nSub\n---\n")).toEqual(["1:1:Title", "2:4:Sub"]);
  });

  it("does not take a list item or a rule for a heading", () => {
    expect(titles("- item\n---\n\n***\n")).toEqual([]);
  });

  it("ignores # inside code fences", () => {
    expect(titles("# Real\n```\n# not a heading\n```\n~~~\n# nor this\n~~~\n## After")).toEqual(["1:1:Real", "2:8:After"]);
  });

  it("skips YAML front matter", () => {
    expect(titles("---\ntitle: x\n---\n# Heading")).toEqual(["1:4:Heading"]);
  });

  it("reads scene headings and sections of a Fountain script", () => {
    expect(titles("# Act One\n\nINT. HOUSE - DAY\n\nMARY\nHi.\n\next. street - night", "fountain")).toEqual([
      "1:1:Act One",
      "2:3:INT. HOUSE - DAY",
      "2:8:ext. street - night",
    ]);
  });

  it("copes with Windows line endings", () => {
    expect(titles("# A\r\n\r\n## B\r\n")).toEqual(["1:1:A", "2:3:B"]);
  });
});

describe("outline: current heading", () => {
  const h = extractHeadings("# A\n\ntext\n\n## B\n\nmore\n\n## C", "markdown");
  it("is the last heading at or above the cursor line", () => {
    expect(activeHeading(h, 1)).toBe(0);
    expect(activeHeading(h, 4)).toBe(0);
    expect(activeHeading(h, 5)).toBe(1);
    expect(activeHeading(h, 99)).toBe(2);
  });
  it("is -1 above the first heading", () => {
    expect(activeHeading(extractHeadings("text\n# A", "markdown"), 1)).toBe(-1);
  });
});
