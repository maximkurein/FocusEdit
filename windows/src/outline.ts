// The outline: headings of the document, with a panel to jump between them.

import type { DocKind } from "./completion";

export interface Heading {
  /** 1-based line number. */
  line: number;
  level: number;
  title: string;
}

const SCENE = /^(?:INT|EXT|EST|INT\.?\/EXT|I\/E)[. ]/i;

/** Headings of Markdown (ATX `# x` and Setext `x` + `===`) or scene headings and sections of a Fountain script. */
export function extractHeadings(text: string, kind: DocKind): Heading[] {
  const lines = text.split(/\r?\n/);
  const out: Heading[] = [];
  let fence: string | null = null;

  // YAML front matter (--- … ---) at the very top is not a heading.
  let start = 0;
  if (kind !== "fountain" && lines[0]?.trim() === "---") {
    const close = lines.findIndex((l, i) => i > 0 && /^(---|\.\.\.)\s*$/.test(l));
    if (close > 0) start = close + 1;
  }

  for (let i = start; i < lines.length; i++) {
    const line = lines[i];
    const marker = /^\s{0,3}(`{3,}|~{3,})/.exec(line)?.[1];
    if (marker && kind !== "fountain") {
      if (fence === null) fence = marker[0];
      else if (marker[0] === fence) fence = null;
      continue;
    }
    if (fence !== null) continue;

    const atx = /^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line);
    if (atx && atx[2] !== "") {
      out.push({ line: i + 1, level: atx[1].length, title: atx[2] });
      continue;
    }
    if (kind === "fountain") {
      if (SCENE.test(line.trim())) out.push({ line: i + 1, level: 2, title: line.trim() });
      continue;
    }
    // Setext: a text line underlined by === or ---
    const next = lines[i + 1];
    if (next !== undefined && line.trim() !== "" && !/^\s*([-*+]|\d+[.)])\s/.test(line) && !/^\s*>/.test(line)) {
      if (/^ {0,3}=+\s*$/.test(next)) out.push({ line: i + 1, level: 1, title: line.trim() });
      else if (/^ {0,3}-{2,}\s*$/.test(next)) out.push({ line: i + 1, level: 2, title: line.trim() });
    }
  }
  return out;
}

/** Index of the heading the cursor line belongs to (the last one at or above it), or -1. */
export function activeHeading(headings: Heading[], cursorLine: number): number {
  let active = -1;
  for (let i = 0; i < headings.length && headings[i].line <= cursorLine; i++) active = i;
  return active;
}

export class OutlinePanel {
  private headings: Heading[] = [];
  private active = -1;

  constructor(
    private readonly root: HTMLElement,
    private readonly onPick: (line: number) => void,
  ) {}

  update(headings: Heading[], cursorLine: number): void {
    this.headings = headings;
    this.active = activeHeading(headings, cursorLine);
    this.render();
  }

  /** Only the highlighted entry changes: cheap enough to run on every cursor move. */
  setCursor(cursorLine: number): void {
    const active = activeHeading(this.headings, cursorLine);
    if (active === this.active) return;
    this.active = active;
    this.root.querySelectorAll(".outline-item").forEach((el, i) => el.classList.toggle("active", i === active));
    this.root.querySelector(".outline-item.active")?.scrollIntoView({ block: "nearest" });
  }

  private render(): void {
    const title = document.createElement("div");
    title.className = "outline-title";
    title.textContent = "Outline";
    this.root.replaceChildren(title);
    if (this.headings.length === 0) {
      const empty = document.createElement("div");
      empty.className = "outline-empty";
      empty.textContent = "Headings will appear here.";
      this.root.append(empty);
      return;
    }
    const base = Math.min(...this.headings.map((h) => h.level));
    this.headings.forEach((h, i) => {
      const item = document.createElement("button");
      item.type = "button";
      item.className = "outline-item" + (i === this.active ? " active" : "");
      item.style.paddingLeft = `${10 + (h.level - base) * 14}px`;
      item.textContent = h.title;
      item.title = h.title;
      item.addEventListener("click", () => this.onPick(h.line));
      this.root.append(item);
    });
  }
}
