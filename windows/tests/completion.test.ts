import { describe, expect, it } from "vitest";
import { CompletionEngine, kindForPath } from "../src/completion";

describe("CompletionEngine (port of the macOS engine)", () => {
  const md = new CompletionEngine();
  md.kind = "markdown";
  md.update("Markdown is plain. Markdown is portable. A marker pen.");

  it("suggests the most frequent document word", () => {
    expect(md.suffix("Mark", "Mark")).toBe("down");
  });

  it("keeps the typed case", () => {
    expect(md.suffix("mark", "mark")).toBe("down");
  });

  it("needs two letters", () => {
    expect(md.suffix("M", "M")).toBeNull();
  });

  it("works with Cyrillic", () => {
    const ru = new CompletionEngine();
    ru.update("Привет мир. Приветствие и привет снова.");
    expect(ru.suffix("При", "При")).toBe("вет");
  });

  it("lists candidates for Ctrl+Space", () => {
    expect(md.completions("ma", "ma")).toEqual(["markdown", "marker"]);
  });

  const fountain = new CompletionEngine();
  fountain.kind = "fountain";
  fountain.update("INT. HOUSE - DAY\n\nMARGARET\nHello.\n\nMARGARET (V.O.)\nAgain.\n");

  it("completes Fountain scene headings", () => {
    expect(fountain.suffix("IN", "IN")).toBe("T. ");
  });

  it("completes Fountain character cues", () => {
    expect(fountain.suffix("MAR", "MAR")).toBe("GARET");
  });

  it("maps file extensions to document kinds", () => {
    expect(kindForPath("C:\\notes\\a.MD")).toBe("markdown");
    expect(kindForPath("script.fountain")).toBe("fountain");
    expect(kindForPath("a.txt")).toBe("plain");
    expect(kindForPath(null)).toBe("plain");
  });
});
