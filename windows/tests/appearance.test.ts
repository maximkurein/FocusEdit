import { describe, expect, it } from "vitest";
import { clampShare, DEFAULT_SHARE, loadAppearance, MAX_FILES, saveAppearance } from "../src/appearance";

function memory() {
  const data = new Map<string, string>();
  return { getItem: (k: string) => data.get(k) ?? null, setItem: (k: string, v: string) => void data.set(k, v) };
}

describe("per-file appearance", () => {
  it("equal panes by default and never collapses a pane", () => {
    expect(DEFAULT_SHARE).toBe(0.5);
    expect(clampShare(0.01)).toBe(0.2);
    expect(clampShare(0.99)).toBe(0.8);
    expect(clampShare(NaN)).toBe(0.5);
  });

  it("restores what was saved for a file, ignoring path case", () => {
    const store = memory();
    saveAppearance("C:\\docs\\a.md", { view: "split", outline: true, share: 0.4 }, store);
    saveAppearance("C:\\docs\\b.md", { view: "preview", outline: false, share: 0.5 }, store);
    expect(loadAppearance("c:\\DOCS\\a.md", store)).toEqual({ view: "split", outline: true, share: 0.4 });
    expect(loadAppearance("C:\\docs\\b.md", store)?.view).toBe("preview");
    expect(loadAppearance("C:\\docs\\none.md", store)).toBeNull();
  });

  it("keeps one entry per file and caps the list", () => {
    const store = memory();
    for (let i = 0; i < MAX_FILES + 5; i++) saveAppearance(`C:\\f${i}.md`, { view: "edit", outline: false, share: 0.5 }, store);
    expect(loadAppearance("C:\\f0.md", store)).toBeNull();
    expect(loadAppearance(`C:\\f${MAX_FILES + 4}.md`, store)).not.toBeNull();
    saveAppearance("C:\\f9.md", { view: "split", outline: false, share: 0.3 }, store);
    expect(loadAppearance("C:\\f9.md", store)?.view).toBe("split");
  });

  it("survives broken storage", () => {
    const bad = { getItem: () => "not json", setItem: () => {} };
    expect(loadAppearance("C:\\a.md", bad)).toBeNull();
    expect(loadAppearance("C:\\a.md", null)).toBeNull();
  });
});
