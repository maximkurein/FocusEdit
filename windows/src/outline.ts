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
  if (kind === "mermaid") return [];
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

/** The Diagrams tab: its list, buttons and the Properties of the cursor's block. */
export interface DiagramTab {
  /** The diagrams of the document (null: the document cannot have any). */
  items: { title: string; line: number }[] | null;
  /** Index of the diagram under the cursor, or -1. */
  current: number;
  /** A diagram file shows the Diagrams tab only. */
  only: boolean;
  properties: {
    block: string | null;
    shape: number | null;
    color: number | null;
    customColor: boolean;
    arrow: number | null;
    flowchart: boolean;
  } | null;
}

export interface DiagramTabActions {
  pick(line: number): void;
  insert(element: "block" | "arrow" | "group"): void;
  template(index: number): void;
  shape(index: number): void;
  color(index: number | null): void;
  arrow(index: number): void;
  templates: string[];
  shapes: string[];
  colors: string[];
  arrows: string[];
}

export type OutlineTab = "headings" | "diagrams";

export class OutlinePanel {
  private headings: Heading[] = [];
  private active = -1;
  private diagrams: DiagramTab | null = null;
  tab: OutlineTab = "headings";

  constructor(
    private readonly root: HTMLElement,
    private readonly onPick: (line: number) => void,
    private readonly actions?: DiagramTabActions,
    private readonly onTab?: (tab: OutlineTab) => void,
  ) {}

  update(headings: Heading[], cursorLine: number, diagrams: DiagramTab | null = null): void {
    this.headings = headings;
    this.active = activeHeading(headings, cursorLine);
    this.diagrams = diagrams?.items ? diagrams : null;
    this.render();
  }

  /** Only the highlighted entry changes: cheap enough to run on every cursor move. */
  setCursor(cursorLine: number): void {
    if (this.showing === "diagrams") return;
    const active = activeHeading(this.headings, cursorLine);
    if (active === this.active) return;
    this.active = active;
    this.root.querySelectorAll(".outline-item").forEach((el, i) => el.classList.toggle("active", i === active));
    this.root.querySelector(".outline-item.active")?.scrollIntoView({ block: "nearest" });
  }

  /** Show a tab (the Diagrams tab only where there can be diagrams). */
  setTab(tab: OutlineTab): void {
    this.tab = tab;
    this.onTab?.(tab);
    this.render();
  }

  /** The tab on screen. */
  get showing(): OutlineTab {
    if (!this.diagrams) return "headings";
    return this.diagrams.only ? "diagrams" : this.tab;
  }

  private render(): void {
    this.root.replaceChildren();
    if (this.diagrams && !this.diagrams.only) {
      const tabs = document.createElement("div");
      tabs.className = "outline-tabs";
      tabs.setAttribute("role", "tablist");
      for (const [tab, label] of [["headings", "Headings"], ["diagrams", "Diagrams"]] as const) {
        const b = document.createElement("button");
        b.type = "button";
        b.textContent = label;
        b.className = "outline-tab" + (this.showing === tab ? " on" : "");
        b.setAttribute("role", "tab");
        b.addEventListener("click", () => this.setTab(tab));
        tabs.append(b);
      }
      this.root.append(tabs);
    }
    if (this.showing === "diagrams" && this.diagrams) this.renderDiagrams(this.diagrams);
    else this.renderHeadings();
  }

  private renderHeadings(): void {
    const title = document.createElement("div");
    title.className = "outline-title";
    title.textContent = "Outline";
    this.root.append(title);
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

  private renderDiagrams(d: DiagramTab): void {
    const a = this.actions;
    const title = document.createElement("div");
    title.className = "outline-title";
    title.textContent = "Diagrams";
    this.root.append(title);
    const items = d.items ?? [];
    if (items.length === 0) {
      const empty = document.createElement("div");
      empty.className = "outline-empty";
      empty.textContent = "Mermaid diagrams will appear here. Template ▾ adds one.";
      this.root.append(empty);
    }
    items.forEach((item, i) => {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "outline-item" + (i === d.current ? " active" : "");
      b.textContent = item.title;
      b.title = item.title;
      b.addEventListener("click", () => (a ? a.pick(item.line) : this.onPick(item.line)));
      this.root.append(b);
    });
    if (!a) return;

    const bar = document.createElement("div");
    bar.className = "outline-buttons";
    for (const [element, label, tip] of [
      ["block", "Block", "Add a block after the cursor's line"],
      ["arrow", "Arrow", "Add an arrow from the block on the cursor's line"],
      ["group", "Group", "Add a group (subgraph, loop)"],
    ] as const) {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "outline-button";
      b.textContent = label;
      b.title = tip;
      b.disabled = d.current < 0;
      b.addEventListener("click", () => a.insert(element));
      bar.append(b);
    }
    bar.append(select("Template ▾", a.templates, null, (i) => a.template(i), "Insert a ready diagram"));
    this.root.append(bar);

    const p = d.properties;
    if (!p || !p.flowchart) return;
    const grid = document.createElement("div");
    grid.className = "outline-properties";
    const head = document.createElement("div");
    head.className = "outline-title";
    head.textContent = p.block ? `Properties · ${p.block}` : "Properties";
    grid.append(head);
    const row = (label: string, control: HTMLElement) => {
      const l = document.createElement("label");
      l.className = "outline-row";
      const span = document.createElement("span");
      span.textContent = label;
      l.append(span, control);
      grid.append(l);
    };
    const shape = select(null, a.shapes, p.shape, (i) => a.shape(i));
    shape.disabled = !p.block;
    row("Shape", shape);
    const colorChoices = ["None", ...a.colors, ...(p.customColor ? ["Custom"] : [])];
    const colorIndex = p.customColor ? colorChoices.length - 1 : p.color === null ? 0 : p.color + 1;
    const color = select(null, colorChoices, p.block ? colorIndex : null, (i) => {
      if (i <= a.colors.length) a.color(i === 0 ? null : i - 1);
    });
    color.disabled = !p.block;
    row("Color", color);
    const arrow = select(null, a.arrows, p.arrow, (i) => a.arrow(i));
    arrow.disabled = p.arrow === null;
    row("Arrow", arrow);
    this.root.append(grid);
  }
}

/** A drop-down; `prompt` is a first entry that only names it (a pull-down menu). */
function select(prompt: string | null, options: string[], selected: number | null, onPick: (index: number) => void, tip = ""): HTMLSelectElement {
  const el = document.createElement("select");
  el.className = "outline-select";
  if (tip) el.title = tip;
  const first = document.createElement("option");
  first.textContent = prompt ?? "—";
  first.value = "-1";
  first.hidden = prompt === null && selected !== null;
  el.append(first);
  options.forEach((label, i) => {
    const o = document.createElement("option");
    o.value = String(i);
    o.textContent = label;
    el.append(o);
  });
  el.value = selected === null ? "-1" : String(selected);
  el.addEventListener("change", () => {
    const i = Number(el.value);
    if (prompt !== null) el.value = "-1";
    if (i >= 0) onPick(i);
  });
  return el;
}
