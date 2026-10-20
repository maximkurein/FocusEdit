// Persisted user preferences (localStorage in the app's WebView profile).

export type FocusMode = "off" | "sentence" | "paragraph";
/** "System" follows the Windows light/dark setting. */
export type ThemeName = "System" | "Light" | "Dark" | "Sepia";
export type EditorSize = "small" | "medium" | "large";
export type FontKind = "system" | "monospace" | "serif";

export interface Settings {
  focusMode: FocusMode;
  typewriter: boolean;
  theme: ThemeName;
  size: EditorSize;
  font: FontKind;
  fontSize: number;
  autocomplete: boolean;
  pairing: boolean;
  vim: boolean;
  outline: boolean;
  /** Hide the marks of Markdown formatting away from the cursor. */
  liveMarkdown: boolean;
  /** Words to write per session; 0 = no goal. */
  goal: number;
}

export const defaults: Settings = {
  focusMode: "paragraph",
  typewriter: true,
  theme: "System",
  size: "medium",
  font: "system",
  fontSize: 17,
  autocomplete: true,
  pairing: true,
  vim: false,
  outline: false,
  liveMarkdown: true,
  goal: 0,
};

const KEY = "focusedit.settings.v1";

export function loadSettings(): Settings {
  try {
    const raw = localStorage.getItem(KEY);
    return { ...defaults, ...(raw ? (JSON.parse(raw) as Partial<Settings>) : {}) };
  } catch {
    return { ...defaults };
  }
}

export function saveSettings(s: Settings): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(s));
  } catch {
    // Private mode or blocked storage: settings just don't persist.
  }
}

export const columnWidth: Record<EditorSize, number> = { small: 550, medium: 650, large: 800 };

export const fontStack: Record<FontKind, string> = {
  system: '"Segoe UI Variable Text", "Segoe UI", -apple-system, system-ui, sans-serif',
  monospace: '"Cascadia Mono", Consolas, ui-monospace, Menlo, monospace',
  serif: "Georgia, Cambria, serif",
};

export const focusModes: FocusMode[] = ["off", "sentence", "paragraph"];
export const themeNames: ThemeName[] = ["System", "Light", "Dark", "Sepia"];
export const sizes: EditorSize[] = ["small", "medium", "large"];
export const fonts: FontKind[] = ["system", "monospace", "serif"];

export function next<T>(list: T[], current: T): T {
  return list[(list.indexOf(current) + 1) % list.length];
}
