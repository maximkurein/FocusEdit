// Recently opened files and the last document, remembered between runs
// (localStorage in the app's WebView profile).

export interface RecentFile {
  path: string;
  name: string;
}

const KEY = "focusedit.recent.v1";
export const MAX_RECENT = 10;

type Store = Pick<Storage, "getItem" | "setItem">;

const defaultStore = (): Store | null => {
  try {
    return localStorage;
  } catch {
    return null;
  }
};

/** `file` first, no duplicates (same path, ignoring case on Windows drive paths), at most `max` entries. */
export function pushRecent(list: RecentFile[], file: RecentFile, max = MAX_RECENT): RecentFile[] {
  const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
  return [file, ...list.filter((f) => !same(f.path, file.path))].slice(0, max);
}

export function loadRecent(store: Store | null = defaultStore()): RecentFile[] {
  try {
    const parsed: unknown = JSON.parse(store?.getItem(KEY) ?? "[]");
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter((f): f is RecentFile => typeof f?.path === "string" && typeof f?.name === "string")
      .slice(0, MAX_RECENT);
  } catch {
    return [];
  }
}

export function saveRecent(list: RecentFile[], store: Store | null = defaultStore()): void {
  try {
    store?.setItem(KEY, JSON.stringify(list));
  } catch {
    // Storage blocked: the list just isn't remembered.
  }
}

export function addRecent(file: RecentFile, store: Store | null = defaultStore()): RecentFile[] {
  const list = pushRecent(loadRecent(store), file);
  saveRecent(list, store);
  return list;
}

export function removeRecent(path: string, store: Store | null = defaultStore()): RecentFile[] {
  const list = loadRecent(store).filter((f) => f.path.toLowerCase() !== path.toLowerCase());
  saveRecent(list, store);
  return list;
}

/** The folder part of a path, for showing next to the file name. */
export function folderOf(path: string): string {
  const cut = Math.max(path.lastIndexOf("\\"), path.lastIndexOf("/"));
  return cut > 0 ? path.slice(0, cut) : "";
}
