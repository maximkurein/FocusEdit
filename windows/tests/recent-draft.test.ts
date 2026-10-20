import { describe, expect, it } from "vitest";
import { clearDraft, loadDraft, saveDraft } from "../src/draft";
import { addRecent, folderOf, loadRecent, MAX_RECENT, pushRecent, removeRecent } from "../src/recent";

function memory() {
  const data = new Map<string, string>();
  return {
    getItem: (k: string) => data.get(k) ?? null,
    setItem: (k: string, v: string) => void data.set(k, v),
    removeItem: (k: string) => void data.delete(k),
  };
}

describe("recent files", () => {
  const f = (n: string) => ({ path: `C:\\docs\\${n}.md`, name: `${n}.md` });

  it("puts the newest first and drops duplicates (any case)", () => {
    const list = pushRecent([f("a"), f("b")], { path: "c:\\DOCS\\a.md", name: "a.md" });
    expect(list.map((x) => x.name)).toEqual(["a.md", "b.md"]);
    expect(list[0].path).toBe("c:\\DOCS\\a.md");
  });

  it("keeps at most MAX_RECENT", () => {
    let list: ReturnType<typeof pushRecent> = [];
    for (let i = 0; i < MAX_RECENT + 5; i++) list = pushRecent(list, f(String(i)));
    expect(list).toHaveLength(MAX_RECENT);
    expect(list[0].name).toBe(`${MAX_RECENT + 4}.md`);
  });

  it("is remembered in storage, and removable", () => {
    const store = memory();
    addRecent(f("a"), store);
    addRecent(f("b"), store);
    expect(loadRecent(store).map((x) => x.name)).toEqual(["b.md", "a.md"]);
    expect(removeRecent("C:\\DOCS\\B.md", store).map((x) => x.name)).toEqual(["a.md"]);
  });

  it("survives garbage in storage", () => {
    const store = memory();
    store.setItem("focusedit.recent.v1", "{nope");
    expect(loadRecent(store)).toEqual([]);
    store.setItem("focusedit.recent.v1", JSON.stringify([{ path: 1 }, { path: "x", name: "y" }]));
    expect(loadRecent(store)).toEqual([{ path: "x", name: "y" }]);
  });

  it("splits the folder from a path", () => {
    expect(folderOf("C:\\a\\b\\c.md")).toBe("C:\\a\\b");
    expect(folderOf("/home/u/c.md")).toBe("/home/u");
    expect(folderOf("c.md")).toBe("");
  });
});

describe("draft recovery", () => {
  it("stores and returns a draft, then forgets it", () => {
    const store = memory();
    const draft = { path: "C:\\a.md", name: "a.md", text: "unsaved", savedAt: 5 };
    expect(saveDraft(draft, store)).toBe(true);
    expect(loadDraft(store)).toEqual(draft);
    clearDraft(store);
    expect(loadDraft(store)).toBeNull();
  });

  it("keeps an untitled draft (no path)", () => {
    const store = memory();
    saveDraft({ path: null, name: "Untitled", text: "x", savedAt: 1 }, store);
    expect(loadDraft(store)?.path).toBeNull();
  });

  it("reports a full or blocked storage", () => {
    const full = {
      getItem: () => null,
      setItem: () => {
        throw new Error("quota");
      },
      removeItem: () => {},
    };
    expect(saveDraft({ path: null, name: "n", text: "x", savedAt: 1 }, full)).toBe(false);
    expect(saveDraft({ path: null, name: "n", text: "x", savedAt: 1 }, null)).toBe(false);
  });

  it("ignores a damaged draft", () => {
    const store = memory();
    store.setItem("focusedit.draft.v1", JSON.stringify({ name: 3 }));
    expect(loadDraft(store)).toBeNull();
  });
});
