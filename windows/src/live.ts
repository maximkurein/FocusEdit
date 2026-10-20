// Live Markdown: the marks of formatting (#, **, *, `, [ ](…)) are hidden while
// the cursor is somewhere else and appear when it comes close, so the text reads
// almost like the finished page and the file stays plain Markdown.

import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { type EditorState, type Extension, type Range } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from "@codemirror/view";

export type LiveItem =
  | { type: "hide"; from: number; to: number }
  | { type: "mark"; from: number; to: number; cls: string }
  | { type: "line"; from: number; cls: string };

/** What to hide or style between `from` and `to`, given where the selection is. */
export function liveItems(state: EditorState, from: number, to: number): LiveItem[] {
  const tree = ensureSyntaxTree(state, Math.min(to, state.doc.length), 30) ?? syntaxTree(state);
  const selection = state.selection.ranges;
  const touches = (a: number, b: number) => selection.some((r) => r.from <= b && r.to >= a);
  const text = (a: number, b: number) => state.sliceDoc(a, b);
  const items: LiveItem[] = [];
  const hide = (a: number, b: number) => {
    if (b > a) items.push({ type: "hide", from: a, to: b });
  };

  tree.iterate({
    from,
    to,
    enter: (node) => {
      const name = node.name;
      const heading = /^(ATX|Setext)Heading([1-6])$/.exec(name);
      if (heading) {
        // The size of a heading stays the same wherever the cursor is, so the line does not jump.
        items.push({ type: "line", from: node.from, cls: `cm-md-h${heading[2]}` });
        if (heading[1] === "ATX") {
          const line = state.doc.lineAt(node.from);
          if (!touches(line.from, line.to)) {
            node.node.getChildren("HeaderMark").forEach((mark, i) => {
              // "# " : the space after the opening mark goes with it.
              const space = i === 0 && text(mark.to, mark.to + 1) === " " ? 1 : 0;
              hide(mark.from, mark.to + space);
            });
          }
        }
        return;
      }
      switch (name) {
        case "Emphasis":
        case "StrongEmphasis":
        case "Strikethrough":
        case "InlineCode":
          if (!touches(node.from, node.to)) {
            for (const mark of node.node.getChildren(name === "InlineCode" ? "CodeMark" : name === "Strikethrough" ? "StrikethroughMark" : "EmphasisMark")) {
              hide(mark.from, mark.to);
            }
          }
          break;
        case "Link":
        case "Image": {
          const marks = node.node.getChildren("LinkMark");
          if (marks.length >= 2) {
            if (name === "Image") items.push({ type: "mark", from: marks[0].to, to: marks[1].from, cls: "cm-md-image" });
            if (!touches(node.from, node.to)) {
              hide(node.from, marks[0].to); // [  or  ![
              hide(marks[1].from, node.to); // ](address "title")  or  ][label]
            }
          }
          break;
        }
        case "Autolink":
          if (!touches(node.from, node.to)) node.node.getChildren("LinkMark").forEach((m) => hide(m.from, m.to));
          break;
      }
    },
  });
  return items;
}

class LivePlugin {
  decorations: DecorationSet = Decoration.none;
  /** Only the hidden ranges: the cursor steps over them instead of stopping inside. */
  hidden: DecorationSet = Decoration.none;

  constructor(view: EditorView) {
    this.build(view);
  }

  update(u: ViewUpdate): void {
    if (u.docChanged || u.selectionSet || u.viewportChanged || syntaxTree(u.startState) !== syntaxTree(u.state)) this.build(u.view);
  }

  private build(view: EditorView): void {
    const seen = new Set<string>();
    const all: Range<Decoration>[] = [];
    const hidden: Range<Decoration>[] = [];
    for (const range of view.visibleRanges) {
      for (const item of liveItems(view.state, range.from, range.to)) {
        const key = `${item.type}:${item.from}:${"to" in item ? item.to : ""}:${"cls" in item ? item.cls : ""}`;
        if (seen.has(key)) continue; // visible ranges can overlap at their edges
        seen.add(key);
        if (item.type === "hide") {
          const r = Decoration.replace({}).range(item.from, item.to);
          all.push(r);
          hidden.push(r);
        } else if (item.type === "mark") {
          if (item.to > item.from) all.push(Decoration.mark({ class: item.cls }).range(item.from, item.to));
        } else {
          all.push(Decoration.line({ class: item.cls }).range(item.from));
        }
      }
    }
    this.decorations = Decoration.set(all, true);
    this.hidden = Decoration.set(hidden, true);
  }
}

export function liveMarkdown(): Extension {
  const plugin = ViewPlugin.fromClass(LivePlugin, {
    decorations: (v) => v.decorations,
    provide: (p) => EditorView.atomicRanges.of((view) => view.plugin(p)?.hidden ?? Decoration.none),
  });
  return plugin;
}
