// Crash recovery: while a document has unsaved changes a copy is kept in
// storage, and offered back at the next start if the app didn't close cleanly.

export interface Draft {
  path: string | null;
  name: string;
  /** The text exactly as it would be saved (BOM and line endings included). */
  text: string;
  savedAt: number;
}

const KEY = "focusedit.draft.v1";

type Store = Pick<Storage, "getItem" | "setItem" | "removeItem">;

const defaultStore = (): Store | null => {
  try {
    return localStorage;
  } catch {
    return null;
  }
};

/** False when the storage refused (full or blocked). */
export function saveDraft(draft: Draft, store: Store | null = defaultStore()): boolean {
  try {
    store?.setItem(KEY, JSON.stringify(draft));
    return store !== null;
  } catch {
    return false;
  }
}

export function loadDraft(store: Store | null = defaultStore()): Draft | null {
  try {
    const raw = store?.getItem(KEY);
    if (!raw) return null;
    const d = JSON.parse(raw) as Partial<Draft>;
    if (typeof d.text !== "string" || typeof d.name !== "string") return null;
    return { path: typeof d.path === "string" ? d.path : null, name: d.name, text: d.text, savedAt: Number(d.savedAt) || 0 };
  } catch {
    return null;
  }
}

export function clearDraft(store: Store | null = defaultStore()): void {
  try {
    store?.removeItem(KEY);
  } catch {
    // Nothing to do.
  }
}
