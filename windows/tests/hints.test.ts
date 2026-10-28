import { describe, expect, it } from "vitest";
import { hintKeys, hintSections } from "../src/hints";

const keysOf = (isMac: boolean, kind: "markdown" | "fountain" | "plain" = "markdown") =>
  hintSections(kind, hintKeys(isMac)).flatMap((s) => s.rows.map(([key]) => key)).join("\n");

describe("hints follow the OS the app is running on", () => {
  it("shows Ctrl keys and F1 on Windows", () => {
    const keys = keysOf(false);
    expect(keys).toContain("Ctrl+Shift+P");
    expect(keys).toContain("Ctrl+Shift+V");
    expect(keys).toContain("F11");
    expect(keys).toContain("F1");
    expect(keys).not.toContain("⌘");
  });

  it("shows ⌘ keys when this app runs on a Mac", () => {
    const keys = keysOf(true);
    expect(keys).toContain("⌘Shift+P");
    expect(keys).toContain("⌘Shift+V");
    expect(keys).toContain("⌘?");
    expect(keys).toContain("⌃⌘F");
    expect(keys).not.toContain("Ctrl+");
    expect(keys).not.toContain("F1");
  });

  it("mentions click-to-copy only for Markdown", () => {
    expect(keysOf(false, "markdown")).toContain("Click a code block");
    expect(keysOf(false, "plain")).not.toContain("Click a code block");
    expect(keysOf(false, "fountain")).not.toContain("Click a code block");
  });
});
