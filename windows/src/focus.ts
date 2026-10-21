// Focus highlighting and typewriter scrolling for CodeMirror 6 — the
// equivalents of FocusTextView's focus and typewriter layers on macOS.
//
// "Paragraph" is the block of text around the cursor up to the blank lines
// (a heading and a list item, with its continuation lines, count as blocks of
// their own); "sentence" narrows that to the sentence around the cursor.
// Dimming is a CSS class on lines/marks, so markup styling (bold, italic,
// code) survives and only the colour fades; a CSS transition smooths it.

import { EditorState, type Extension, type Range, type Transaction } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from "@codemirror/view";
import type { FocusMode } from "./settings";

const dimLine = Decoration.line({ class: "cm-dim" });
const dimText = Decoration.mark({ class: "cm-dim-text" });

/** [start, end) of the sentence containing `offset` within `text`. */
export function sentenceRange(text: string, offset: number): [number, number] {
  const segmenter = new Intl.Segmenter(undefined, { granularity: "sentence" });
  let last: [number, number] = [0, text.length];
  // A line break ends a sentence for the segmenter; in a hard-wrapped paragraph it does not.
  // A space has the same length, so the offsets stay valid.
  for (const s of segmenter.segment(text.replace(/\n/g, " "))) {
    const start = s.index;
    const end = s.index + s.segment.length;
    last = [start, end];
    if (offset >= start && offset < end) return [start, end];
  }
  return last; // cursor at the very end of the line
}

const LIST_ITEM = /^\s*([-*+]|\d+[.)])\s+/;
const HEADING = /^\s{0,3}#{1,6}\s/;

/**
 * The first and last line (1-based, inclusive) of the block around `line`: text up to the blank
 * lines. A heading is a block of its own, and so is each list item with the lines that continue it.
 * The same rule as `FocusUnit` in FocusTextView.swift.
 */
export function focusUnit(text: (line: number) => string, count: number, line: number): [number, number] {
  const blank = (n: number) => text(n).trim() === "";
  const starts = (n: number) => LIST_ITEM.test(text(n)) || HEADING.test(text(n));
  if (blank(line)) return [line, line];
  let first = line;
  while (!starts(first) && first > 1 && !blank(first - 1) && !HEADING.test(text(first - 1))) first--;
  let last = line;
  if (!HEADING.test(text(first))) {
    while (last < count && !blank(last + 1) && !starts(last + 1)) last++;
  } else last = first;
  return [first, last];
}

function buildDecorations(view: EditorView, mode: FocusMode): DecorationSet {
  const { doc } = view.state;
  const head = view.state.selection.main.head;
  const [first, last] = focusUnit((n) => doc.line(n).text, doc.lines, doc.lineAt(head).number);
  const ranges: Range<Decoration>[] = [];

  for (const { from, to } of view.visibleRanges) {
    for (let pos = from; pos <= to; ) {
      const line = doc.lineAt(pos);
      if (line.number < first || line.number > last) ranges.push(dimLine.range(line.from));
      pos = line.to + 1;
    }
  }
  if (mode === "sentence") {
    const from = doc.line(first).from;
    const to = doc.line(last).to;
    if (to > from) {
      const [s, e] = sentenceRange(doc.sliceString(from, to), head - from);
      if (s > 0) ranges.push(dimText.range(from, from + s));
      if (e < to - from) ranges.push(dimText.range(from + e, to));
    }
  }
  return Decoration.set(ranges, true);
}

export function focusHighlighting(mode: FocusMode): Extension {
  if (mode === "off") return [];
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;
      constructor(view: EditorView) {
        this.decorations = buildDecorations(view, mode);
      }
      update(u: ViewUpdate) {
        if (u.docChanged || u.selectionSet || u.viewportChanged) {
          this.decorations = buildDecorations(u.view, mode);
        }
      }
    },
    { decorations: (v) => v.decorations },
  );
}

/** Pointer selections (clicks, drags) must not yank the text around. */
function movesCaretByKeyboardOrTyping(tr: Transaction): boolean {
  if (tr.docChanged) return true;
  return !!tr.selection && !tr.isUserEvent("select.pointer");
}

/**
 * Keep the cursor line at the vertical centre of the window. Extra padding
 * (see styles.css, `.typewriter`) lets the first and last lines reach it.
 */
export function typewriterScrolling(): Extension {
  return [
    EditorView.editorAttributes.of({ class: "typewriter" }),
    EditorState.transactionExtender.of((tr) =>
      movesCaretByKeyboardOrTyping(tr)
        ? { effects: EditorView.scrollIntoView(tr.newSelection.main.head, { y: "center" }) }
        : null,
    ),
  ];
}
