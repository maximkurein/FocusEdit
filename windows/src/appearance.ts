// The last look of each file: view mode, outline, and how Split divides the width
// (localStorage in the app's WebView profile). Files that were never saved have no path
// and are not remembered.

export type ViewName = "edit" | "split" | "preview";

export interface Appearance {
  view: ViewName;
  outline: boolean;
  /** The editor's part of the editor + preview width; 0.5 is equal panes. */
  share: number;
}

const KEY = "focusedit.appearance.v1";
export const MAX_FILES = 200;
export const DEFAULT_SHARE = 0.5;
const VIEWS: ViewName[] = ["edit", "split", "preview"];

type Store = Pick<Storage, "getItem" | "setItem">;
type Entry = Appearance & { path: string };

const defaultStore = (): Store | null => {
  try {
    return localStorage;
  } catch {
    return null;
  }
};

/** Neither pane may collapse. */
export function clampShare(share: number): number {
  return Number.isFinite(share) ? Math.min(0.8, Math.max(0.2, share)) : DEFAULT_SHARE;
}

const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

function read(store: Store | null): Entry[] {
  try {
    const parsed: unknown = JSON.parse(store?.getItem(KEY) ?? "[]");
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(
      (e): e is Entry =>
        typeof e?.path === "string" && VIEWS.includes(e.view) && typeof e.outline === "boolean" && typeof e.share === "number",
    );
  } catch {
    return [];
  }
}

export function loadAppearance(path: string, store: Store | null = defaultStore()): Appearance | null {
  const entry = read(store).find((e) => same(e.path, path));
  return entry ? { view: entry.view, outline: entry.outline, share: clampShare(entry.share) } : null;
}

/** The newest file goes last; the oldest fall off after MAX_FILES. */
export function saveAppearance(path: string, look: Appearance, store: Store | null = defaultStore()): void {
  const list = read(store).filter((e) => !same(e.path, path));
  list.push({ path, view: look.view, outline: look.outline, share: clampShare(look.share) });
  try {
    store?.setItem(KEY, JSON.stringify(list.slice(-MAX_FILES)));
  } catch {
    // Storage blocked: the look just isn't remembered.
  }
}
