// Mermaid diagrams in the preview, the same as on the Mac.
//
// The Mac's `Resources/diagrams.js` does the drawing, zoom, full size view, copy menu
// and the editing gestures; Mermaid itself is `Resources/mermaid.min.js` (+ the ELK
// layout). `scripts/copy-resources.mjs` copies them into `public/fe/`, and they are
// loaded on first use, so a document without diagrams never pays for 8 MB of script.
// diagrams.js talks to the app through `window.webkit.messageHandlers.<name>`
// (WKWebView's bridge); here that is a small shim that calls `handlers`.

/** Colours of the preview page, as `__feDiagrams.configure` expects them. */
export interface DiagramColors {
  dark: boolean;
  background: string;
  foreground: string;
  muted: string;
  accent: string;
}

/** What diagrams.js exposes as `window.__feDiagrams`. */
export interface FeDiagrams {
  configure(colors: DiagramColors): void;
  refresh(): number;
  close(): void;
  freeze(): string;
  highlight(source: string, id: string | null): void;
  pending(): number;
  errorLine(source: string, message: string): number | null;
}

export type DiagramHandler = (message: any) => void;

declare global {
  interface Window {
    __feDiagrams?: FeDiagrams;
    mermaid?: { render(id: string, source: string): Promise<{ svg: string }>; initialize(c: object): void };
    webkit?: { messageHandlers: Record<string, { postMessage(message: unknown): void }> };
  }
}

/** A ```mermaid block in Markdown, or the whole text of a diagram file. */
export const hasDiagram = (markdown: string): boolean => /^\s{0,3}(`{3,}|~{3,})\s*mermaid\b/im.test(markdown);

/** The text the preview shows for a diagram file: the whole file as one block. */
export function diagramFileMarkdown(source: string): string {
  const fence = "`".repeat(Math.max(3, ...[...source.matchAll(/`{3,}/g)].map((m) => m[0].length + 1)));
  return `${fence}mermaid\n${source.replace(/\n+$/, "")}\n${fence}\n`;
}

/** A colour as #rrggbb (accepts #rgb, #rrggbb and rgb(…) from getComputedStyle). */
export function hexColor(value: string): string {
  const v = value.trim();
  const short = /^#([0-9a-f])([0-9a-f])([0-9a-f])$/i.exec(v);
  if (short) return `#${short[1]}${short[1]}${short[2]}${short[2]}${short[3]}${short[3]}`.toLowerCase();
  if (/^#[0-9a-f]{6}$/i.test(v)) return v.toLowerCase();
  const rgb = /^rgba?\(\s*(\d+)[\s,]+(\d+)[\s,]+(\d+)/i.exec(v);
  if (rgb) return "#" + rgb.slice(1, 4).map((n) => Number(n).toString(16).padStart(2, "0")).join("");
  return v;
}

/** True for a dark background (relative luminance below the middle). */
export function isDark(hex: string): boolean {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hexColor(hex));
  if (!m) return false;
  const [r, g, b] = m.slice(1).map((h) => parseInt(h, 16) / 255);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.5;
}

/** The preview's colours from its CSS variables. */
export function colorsOf(el: HTMLElement): DiagramColors {
  const style = getComputedStyle(el);
  const read = (name: string, fallback: string) => hexColor(style.getPropertyValue(name) || fallback);
  const background = read("--bg", "#ffffff");
  return {
    dark: isDark(background),
    background,
    foreground: read("--fg", "#1c1c1e"),
    muted: read("--muted", "#6b6b70"),
    accent: read("--accent", "#3399d9"),
  };
}

// ----------------------------------------------------------------- loading

const BASE = "./fe/";
const handlers: Record<string, DiagramHandler> = {};
let loading: Promise<FeDiagrams | null> | null = null;

function script(src: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const el = document.createElement("script");
    el.src = BASE + src;
    el.onload = () => resolve();
    el.onerror = () => reject(new Error(`${src} did not load`));
    document.head.appendChild(el);
  });
}

/** Messages from diagrams.js; set before the first `load`. */
export function onDiagramMessage(name: string, handler: DiagramHandler): void {
  handlers[name] = handler;
  installBridge();
}

function installBridge(): void {
  const bridge = (window.webkit ??= { messageHandlers: {} });
  for (const name of Object.keys(handlers)) {
    bridge.messageHandlers[name] = { postMessage: (message: unknown) => handlers[name]?.(message) };
  }
}

/** Mermaid, the ELK layout and diagrams.js, loaded once; null when they are missing. */
export function loadDiagrams(): Promise<FeDiagrams | null> {
  loading ??= (async () => {
    installBridge();
    try {
      await script("mermaid.min.js");
      await script("mermaid-layout-elk.min.js").catch(() => undefined); // optional
      await script("diagrams.js");
    } catch {
      return null;
    }
    return window.__feDiagrams ?? null;
  })();
  return loading;
}

/** The diagrams script if it is already loaded (no waiting). */
export const loadedDiagrams = (): FeDiagrams | null => window.__feDiagrams ?? null;

let configured = "";

/** Draw the diagrams of the preview: call after every body replacement. */
export async function refreshDiagrams(previewEl: HTMLElement): Promise<void> {
  if (!previewEl.querySelector("pre > code.language-mermaid") && !loadedDiagrams()) return;
  const d = await loadDiagrams();
  if (!d) return;
  const colors = colorsOf(previewEl);
  const key = JSON.stringify(colors);
  if (key !== configured) {
    configured = key;
    d.configure(colors);
  }
  try {
    d.refresh();
  } catch {
    /* a broken diagram shows its own error */
  }
}

/** Plain SVGs for the ```mermaid blocks under `root` (printing): black on white. */
export async function drawStatic(root: HTMLElement): Promise<void> {
  const blocks = [...root.querySelectorAll<HTMLElement>("pre > code.language-mermaid")];
  if (blocks.length === 0) return;
  // Out of reach of diagrams.js's refresh, which looks for this class in the whole page.
  for (const code of blocks) code.className = "fe-print-mermaid";
  if (!(await loadDiagrams()) || !window.mermaid) return;
  window.mermaid.initialize({ startOnLoad: false, theme: "default", securityLevel: "strict" });
  let n = 0;
  for (const code of blocks) {
    try {
      const { svg } = await window.mermaid.render(`fe-print-${Date.now()}-${n++}`, code.textContent ?? "");
      const figure = document.createElement("figure");
      figure.className = "fe-print-diagram";
      figure.innerHTML = svg;
      code.parentElement?.replaceWith(figure);
    } catch {
      /* stays as code */
    }
  }
  configured = ""; // the preview's colours go back on the next refresh
}
