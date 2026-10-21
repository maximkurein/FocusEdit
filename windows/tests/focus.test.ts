import { describe, expect, it } from "vitest";
import { focusUnit, sentenceRange } from "../src/focus";

/** The unit around line `n` (1-based) of `text`. */
const unit = (text: string, n: number) => {
  const lines = text.split("\n");
  return focusUnit((i) => lines[i - 1], lines.length, n);
};

describe("focus unit (the Paragraph mode)", () => {
  const prose = "First line of a paragraph\nsecond line of it\nthird line\n\nNext paragraph\nwith two lines";

  it("covers all lines of a paragraph up to the blank line", () => {
    expect(unit(prose, 1)).toEqual([1, 3]);
    expect(unit(prose, 2)).toEqual([1, 3]);
    expect(unit(prose, 3)).toEqual([1, 3]);
    expect(unit(prose, 5)).toEqual([5, 6]);
    expect(unit(prose, 6)).toEqual([5, 6]);
  });

  it("is just the blank line when the cursor is on one", () => {
    expect(unit(prose, 4)).toEqual([4, 4]);
  });

  it("makes a heading a block of its own", () => {
    const text = "# Title\nText right under it\nmore text";
    expect(unit(text, 1)).toEqual([1, 1]);
    expect(unit(text, 2)).toEqual([2, 3]);
    expect(unit(text, 3)).toEqual([2, 3]);
  });

  it("makes each list item a block, with the lines that continue it", () => {
    const text = "- one\n- two\n  still two\n- three\n1. first\n2. second";
    expect(unit(text, 1)).toEqual([1, 1]);
    expect(unit(text, 2)).toEqual([2, 3]);
    expect(unit(text, 3)).toEqual([2, 3]);
    expect(unit(text, 4)).toEqual([4, 4]);
    expect(unit(text, 5)).toEqual([5, 5]);
    expect(unit(text, 6)).toEqual([6, 6]);
  });

  it("handles a one-line document and the last line", () => {
    expect(unit("only", 1)).toEqual([1, 1]);
    expect(unit("a\nb", 2)).toEqual([1, 2]);
  });

  it("keeps quotes together", () => {
    expect(unit("> one\n> two\n\ntext", 1)).toEqual([1, 2]);
  });
});

describe("sentence inside a block", () => {
  it("can span the lines of a hard-wrapped paragraph", () => {
    const text = "This sentence starts here\nand ends on the next line. Another one follows.";
    const [s, e] = sentenceRange(text, 30);
    expect(text.slice(s, e)).toBe("This sentence starts here\nand ends on the next line. ");
  });
});
