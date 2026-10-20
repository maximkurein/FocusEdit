// Colour schemes (same palette as Theme.swift on macOS) applied as CSS variables.

import type { ThemeName } from "./settings";

interface Palette {
  dark: boolean;
  bg: string; // editor background
  fg: string; // active text
  dim: string; // non-focused text
  muted: string; // markup marks, quotes, code
  accent: string; // links, active toolbar buttons
  cursor: string;
  selection: string;
  chrome: string; // toolbar background
  border: string;
  hover: string;
}

type Concrete = Exclude<ThemeName, "System">;

const palettes: Record<Concrete, Palette> = {
  Light: {
    dark: false, bg: "#fffffd", fg: "#1c1c1f", dim: "#b8b8bd", muted: "#8a8a90",
    accent: "#2f7deb", cursor: "#337af2", selection: "rgba(51, 122, 242, 0.18)",
    chrome: "#f7f7f8", border: "#e3e3e6", hover: "rgba(0, 0, 0, 0.06)",
  },
  Dark: {
    dark: true, bg: "#1f1f21", fg: "#e0e0e6", dim: "#6b6b73", muted: "#8e8e96",
    accent: "#6cb0ff", cursor: "#73b3ff", selection: "rgba(115, 179, 255, 0.25)",
    chrome: "#26262a", border: "#35353a", hover: "rgba(255, 255, 255, 0.08)",
  },
  Sepia: {
    dark: false, bg: "#faf2de", fg: "#4d381f", dim: "#a89475", muted: "#8c7656",
    accent: "#99662a", cursor: "#99662a", selection: "rgba(153, 102, 42, 0.18)",
    chrome: "#f2e7cd", border: "#e2d3b3", hover: "rgba(77, 56, 31, 0.08)",
  },
};

/** "System" becomes Light or Dark according to the system setting. */
export function resolveTheme(name: ThemeName, systemIsDark: boolean): Concrete {
  return name === "System" ? (systemIsDark ? "Dark" : "Light") : name;
}

const prefersDark = () => typeof matchMedia === "function" && matchMedia("(prefers-color-scheme: dark)").matches;

export function applyTheme(name: ThemeName): void {
  const resolved = resolveTheme(name, prefersDark());
  const p = palettes[resolved];
  const root = document.documentElement;
  const vars: Record<string, string> = {
    "--bg": p.bg, "--fg": p.fg, "--dim": p.dim, "--muted": p.muted, "--accent": p.accent,
    "--cursor": p.cursor, "--selection": p.selection, "--chrome": p.chrome,
    "--border": p.border, "--hover": p.hover,
  };
  for (const [key, value] of Object.entries(vars)) root.style.setProperty(key, value);
  root.style.colorScheme = p.dark ? "dark" : "light";
  root.dataset.theme = resolved.toLowerCase();
}
