// The Diagram commands on the editor: the port of the Mac's DiagramCommands.swift.
// They find the diagram under the cursor (or the one a message from the picture names)
// and replace its text with what mermaid-edit.ts makes, as one undoable edit.

import type { EditorState } from "@codemirror/state";
import type { DocKind } from "./completion";
import type { Editor } from "./editor";
import * as M from "./mermaid-edit";

export const directions = [
  { title: "Top to Bottom", value: "TB" },
  { title: "Left to Right", value: "LR" },
  { title: "Bottom to Top", value: "BT" },
  { title: "Right to Left", value: "RL" },
];
export const looks = [
  { title: "Classic", value: null },
  { title: "Hand-Drawn", value: "handDrawn" },
];
export const layouts = [
  { title: "Standard", value: null },
  { title: "ELK (fewer crossings)", value: "elk" },
];
export const themes = [
  { title: "Same as Preview", value: null },
  { title: "Default", value: "default" },
  { title: "Neutral", value: "neutral" },
  { title: "Dark", value: "dark" },
  { title: "Forest", value: "forest" },
];

/** The block on the cursor's line and its properties (flowcharts). */
export interface DiagramProperties {
  block: string | null;
  shape: M.Shape | null;
  color: M.Color | null;
  /** Has a style that is not one of ours. */
  customColor: boolean;
  arrow: M.Arrow | null;
  flowchart: boolean;
}

export interface DiagramHost {
  editor: Editor;
  kind(): DocKind;
  notify(message: string): void;
}

export class DiagramCommands {
  constructor(private readonly host: DiagramHost) {}

  private get editor(): Editor {
    return this.host.editor;
  }

  /** Diagrams can live in Markdown, plain text and diagram files. */
  get allowed(): boolean {
    return ["markdown", "plain", "mermaid"].includes(this.host.kind());
  }

  private get cursor(): number {
    return this.editor.view.state.selection.main.head;
  }

  /** The diagram under the cursor. */
  currentRange(): M.Span | null {
    if (!this.allowed) return null;
    return M.diagramRange(this.editor.text, this.cursor, this.host.kind());
  }

  currentSource(): string | null {
    const r = this.currentRange();
    return r ? this.editor.text.slice(r.from, r.to) : null;
  }

  /** The diagram whose text is `source` (a message from the picture). */
  private rangeOf(source: string): M.Span | null {
    const text = this.editor.text;
    const want = source.replace(/\s+$/, "");
    const cursorRange = this.currentRange();
    const all = M.diagrams(text, this.host.kind()).map((d) => d.body);
    // The one under the cursor first: two diagrams can have the same text.
    for (const r of cursorRange ? [cursorRange, ...all] : all) {
      if (text.slice(r.from, r.to).replace(/\s+$/, "") === want) return r;
    }
    return null;
  }

  /** Replace the diagram at `range` with `edit(source)`; `select` is inside the new source. */
  private apply(range: M.Span, next: string | null, select?: M.Span): boolean {
    if (next === null) return false;
    const old = this.editor.text.slice(range.from, range.to);
    if (next === old) return true;
    // Only the changed middle, so the cursor and the undo step stay small.
    let start = 0;
    while (start < old.length && start < next.length && old[start] === next[start]) start++;
    let end = 0;
    while (end < old.length - start && end < next.length - start && old[old.length - 1 - end] === next[next.length - 1 - end]) end++;
    const from = range.from + start;
    const to = range.from + old.length - end;
    const insert = next.slice(start, next.length - end);
    this.editor.replace(from, to, insert, select ? { from: range.from + select.from, to: range.from + select.to } : undefined);
    return true;
  }

  private editCurrent(edit: (source: string) => string | null): boolean {
    const r = this.currentRange();
    if (!r) {
      this.host.notify("Put the cursor in a Mermaid diagram first");
      return false;
    }
    return this.apply(r, edit(this.editor.text.slice(r.from, r.to)));
  }

  /** The cursor's line within the current diagram (0-based), or null. */
  private lineInDiagram(r: M.Span): number {
    const before = this.editor.text.slice(r.from, Math.max(r.from, Math.min(this.cursor, r.to)));
    return before.split("\n").length - 1;
  }

  // ---------------------------------------------------------------- menu

  insertTemplate(index: number): void {
    const template = M.templates[index] ?? M.templates[0];
    const kind = this.host.kind();
    const text = this.editor.text;
    if (kind === "mermaid" && text.trim() === "") {
      this.editor.replace(0, text.length, template.source + "\n");
      return;
    }
    if (kind === "mermaid") {
      this.host.notify("A diagram file holds one diagram: start a new .mmd file for another");
      return;
    }
    const { from, to } = this.editor.view.state.selection.main;
    const line = this.editor.view.state.doc.lineAt(from);
    // On a line of its own, with an empty line before it when it follows text.
    let insert = M.insertion(template, kind);
    let at = from;
    if (line.text.trim() !== "") {
      at = this.editor.view.state.doc.lineAt(to).to;
      insert = "\n\n" + insert;
    } else if (line.number > 1 && this.editor.view.state.doc.line(line.number - 1).text.trim() !== "") {
      insert = "\n" + insert;
    }
    const bodyStart = at + insert.indexOf("\n", insert.indexOf("```mermaid")) + 1;
    this.editor.replace(at, from === at ? to : at, insert, { from: bodyStart, to: bodyStart });
  }

  insertElement(element: M.Element): void {
    const r = this.currentRange();
    if (!r) {
      this.host.notify("Put the cursor in a Mermaid diagram first");
      return;
    }
    const source = this.editor.text.slice(r.from, r.to);
    const result = M.inserting(element, source, this.lineInDiagram(r));
    if (!result) {
      this.host.notify("Block, Arrow and Group work in flowcharts and sequence diagrams");
      return;
    }
    this.apply(r, result.source, result.select);
  }

  setDirection(dir: string): void {
    this.editCurrent((s) => {
      const next = M.settingDirection(s, dir);
      if (next === null) this.host.notify("Direction is for flowcharts");
      return next;
    });
  }

  setConfig(key: "look" | "layout" | "theme", value: string | null): void {
    this.editCurrent((s) => M.settingConfig(s, key, value));
  }

  /** The current setting, for check marks in the menu. */
  current(): { direction: string | null; look: string | null; layout: string | null; theme: string | null } | null {
    const s = this.currentSource();
    if (s === null) return null;
    return {
      direction: M.direction(s),
      look: M.configValue(s, "look"),
      layout: M.configValue(s, "layout"),
      theme: M.configValue(s, "theme"),
    };
  }

  // ---------------------------------------------------------------- properties

  properties(): DiagramProperties | null {
    const r = this.currentRange();
    if (!r) return null;
    const source = this.editor.text.slice(r.from, r.to);
    const type = M.diagramType(source);
    const flowchart = type === "flowchart" || type === "graph";
    const line = this.lineInDiagram(r);
    const block = flowchart ? M.block(source, line) : null;
    return {
      block,
      shape: block ? M.shape(source, block) : null,
      color: block ? M.color(source, block) : null,
      customColor: block ? M.color(source, block) === null && M.hasStyle(source, block) : false,
      arrow: flowchart ? M.arrow(source, line) : null,
      flowchart,
    };
  }

  setShape(shape: M.Shape): void {
    const block = this.properties()?.block;
    if (block) this.editCurrent((s) => M.settingShape(s, block, shape));
  }

  setColor(color: M.Color | null): void {
    const block = this.properties()?.block;
    if (block) this.editCurrent((s) => M.settingColor(s, block, color));
  }

  setArrow(kind: M.Arrow): void {
    const r = this.currentRange();
    if (!r) return;
    const line = this.lineInDiagram(r);
    this.editCurrent((s) => M.settingArrow(s, line, kind));
  }

  /** The cursor's block, for the orange outline in the picture. */
  cursorBlock(): { source: string; id: string } | null {
    const r = this.currentRange();
    if (!r) return null;
    const source = this.editor.text.slice(r.from, r.to);
    const id = M.block(source, this.lineInDiagram(r));
    return id ? { source, id } : null;
  }

  // ---------------------------------------------------------------- from the picture

  /** A click on a block: the cursor goes to the line that defines it. */
  reveal(source: string, id: string, label: string): void {
    const r = this.rangeOf(source);
    if (!r) return;
    const line = M.nodeLineSpan(this.editor.text.slice(r.from, r.to), id, label);
    if (line) this.editor.select(r.from + line.from, r.from + line.to);
  }

  /** Mermaid could not read the diagram: underline the line with the mistake. */
  markError(source: string, line: number | null): void {
    const r = this.rangeOf(source);
    if (!r || !line) return;
    const span = M.lineSpan(this.editor.text.slice(r.from, r.to), line);
    if (span) this.editor.markError({ from: r.from + span.from, to: r.from + span.to });
  }

  rename(source: string, id: string, text: string): void {
    const r = this.rangeOf(source);
    if (r) this.apply(r, M.renaming(this.editor.text.slice(r.from, r.to), id, text));
  }

  connect(source: string, from: string, to: string): void {
    const r = this.rangeOf(source);
    if (r) this.apply(r, M.connecting(this.editor.text.slice(r.from, r.to), from, to));
  }

  nodeAction(source: string, id: string, action: string): void {
    const r = this.rangeOf(source);
    if (!r) return;
    const s = this.editor.text.slice(r.from, r.to);
    if (action === "next") {
      const next = M.addingNext(s, id);
      if (next) this.apply(r, next.source, next.select);
    } else if (action === "duplicate") {
      this.apply(r, M.duplicating(s, id)?.source ?? null);
    } else if (action === "delete") {
      if (!this.apply(r, M.deleting(s, id))) this.host.notify("A group is deleted in the text");
    }
  }

  // ---------------------------------------------------------------- completion

  /** Words for the grey suggestion and the list while the cursor is in a diagram. */
  completions(state: EditorState, prefix: string, linePrefix: string): string[] | null {
    if (!this.allowed) return null;
    const text = state.doc.toString();
    const cursor = state.selection.main.head;
    const r = M.diagramRange(text, cursor, this.host.kind());
    if (!r || cursor < r.from) return null;
    const source = text.slice(r.from, r.to);
    const line = text.slice(r.from, cursor).split("\n").length - 1;
    return M.completions(prefix, linePrefix, source, line);
  }
}
