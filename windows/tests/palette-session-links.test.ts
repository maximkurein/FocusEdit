import { describe, expect, it } from "vitest";
import { linkFromPaste } from "../src/links";
import { type Command, filterCommands, matchScore } from "../src/palette";
import { countWords, formatDuration, IDLE_MS, Session } from "../src/session";

const cmd = (title: string, keywords?: string): Command => ({ title, keywords, run: () => {} });
const titles = (list: Command[]) => list.map((c) => c.title);

describe("command palette: finding commands", () => {
  const all = [
    cmd("Save"),
    cmd("Save As…"),
    cmd("Theme: Dark", "night"),
    cmd("Theme: Light", "day"),
    cmd("Theme: Sepia"),
    cmd("View: Preview"),
    cmd("Export as HTML…"),
  ];

  it("lists everything, in order, for an empty query", () => {
    expect(filterCommands(all, "")).toBe(all);
    expect(filterCommands(all, "   ")).toBe(all);
  });

  it("matches letters anywhere, ignoring case", () => {
    expect(titles(filterCommands(all, "sepia"))).toEqual(["Theme: Sepia"]);
    expect(titles(filterCommands(all, "HTML"))).toEqual(["Export as HTML…"]);
  });

  it("wants every word of the query", () => {
    expect(titles(filterCommands(all, "theme dark"))).toEqual(["Theme: Dark"]);
    expect(filterCommands(all, "theme zebra")).toEqual([]);
  });

  it("finds by keyword", () => {
    expect(titles(filterCommands(all, "night"))).toEqual(["Theme: Dark"]);
  });

  it("puts the start of a title and of a word first", () => {
    expect(titles(filterCommands(all, "sa"))[0]).toBe("Save");
    expect(titles(filterCommands(all, "save"))).toEqual(["Save", "Save As…"]);
  });

  it("accepts letters in order as a weaker match", () => {
    expect(titles(filterCommands(all, "thdk"))).toEqual(["Theme: Dark"]);
    expect(matchScore("zzz", "Save")).toBeNull();
  });
});

describe("words and the session", () => {
  it("counts words", () => {
    expect(countWords("")).toBe(0);
    expect(countWords("  one  two\nthree\t")).toBe(3);
    expect(countWords("слова по-русски")).toBe(2);
  });

  it("counts words written since the start, never below zero", () => {
    const s = new Session();
    s.reset(100, 0);
    s.note(130, 1000);
    expect(s.written).toBe(30);
    s.note(60, 2000); // deleted more than written
    expect(s.written).toBe(0);
  });

  it("reports progress towards a goal", () => {
    const s = new Session();
    s.reset(0, 0);
    s.note(50, 1);
    expect(s.progress(200)).toBe(0.25);
    expect(s.progress(0)).toBe(0);
    s.note(500, 2);
    expect(s.progress(200)).toBe(1);
  });

  it("times only the seconds spent writing", () => {
    const s = new Session();
    s.reset(0, 0);
    s.tick(1000); // nothing typed yet
    expect(s.activeMs).toBe(0);
    s.note(1, 1500);
    s.tick(2000);
    s.tick(3000);
    expect(s.activeMs).toBe(2000);
    s.tick(3000 + IDLE_MS + 5000); // idle: not counted
    expect(s.activeMs).toBe(2000);
  });

  it("ignores a long gap such as the computer sleeping", () => {
    const s = new Session();
    s.reset(0, 0);
    s.note(1, 100);
    s.tick(1000);
    s.tick(1000 + 60_000); // one tick a minute later while still "active"
    expect(s.activeMs).toBe(1000);
  });

  it("formats durations", () => {
    expect(formatDuration(0)).toBe("0:00");
    expect(formatDuration(75_000)).toBe("1:15");
    expect(formatDuration(3_725_000)).toBe("1:02:05");
  });
});

describe("pasting a link over selected text", () => {
  it("turns the selection and an address into a Markdown link", () => {
    expect(linkFromPaste("my site", "https://example.com/a?b=1")).toBe("[my site](https://example.com/a?b=1)");
    expect(linkFromPaste("x", "  http://example.com \n")).toBe("[x](http://example.com)");
  });

  it("keeps the spaces of the selection outside the link", () => {
    expect(linkFromPaste("click here ", "https://a.b")).toBe("[click here](https://a.b) ");
    expect(linkFromPaste(" word", "https://a.b")).toBe(" [word](https://a.b)");
  });

  it("leaves other pastes alone", () => {
    expect(linkFromPaste("word", "just some text")).toBeNull();
    expect(linkFromPaste("word", "https://a.b and more")).toBeNull();
    expect(linkFromPaste("word", "ftp://a.b")).toBeNull();
    expect(linkFromPaste("", "https://a.b")).toBeNull();
    expect(linkFromPaste("two\nlines", "https://a.b")).toBeNull();
  });

  it("escapes what would break the link", () => {
    expect(linkFromPaste("a [b]", "https://a.b/x_(y)")).toBe("[a \\[b\\]](https://a.b/x_%28y%29)");
  });
});
