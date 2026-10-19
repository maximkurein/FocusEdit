// Focus highlighting and typewriter scrolling for CodeMirror 6 — the
// equivalents of FocusTextView's focus and typewriter layers on macOS.
//
// "Paragraph" is the line holding the cursor (a soft-wrapped paragraph in
// prose), "sentence" narrows that to the sentence around the cursor.
// Dimming is a CSS class on lines/marks, so markup styling (bold, italic,
// code) survives and only the colour fades; a CSS transition smooths it.

import { EditorState, type Extension, RangeSetBuilder, type Transaction } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from "@codemirror/view";
import type { FocusMode } from "./settings";

const dimLine = Decoration.line({ class: "cm-dim" });
const dimText = Decoration.mark({ class: "cm-dim-text" });

/** [start, end) of the sentence containing `offset` within `text`. */
export function sentenceRange(text: string, offset: number): [number, number] {
  const segmenter = new Intl.Segmenter(undefined, { granularity: "sentence" });
  let last: [number, number] = [0, text.length];
  for (const s of segmenter.segment(text)) {
    const start = s.index;
    const end = s.index + s.segment.length;
    last = [start, end];
    if (offset >= start && offset < end) return [start, end];
  }
  return last; // cursor at the very end of the line
}

function buildDecorations(view: EditorView, mode: FocusMode): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const { doc } = view.state;
  const head = view.state.selection.main.head;
  const active = doc.lineAt(head);

  for (const { from, to } of view.visibleRanges) {
    for (let pos = from; pos <= to; ) {
      const line = doc.lineAt(pos);
      if (line.number !== active.number) {
        builder.add(line.from, line.from, dimLine);
      } else if (mode === "sentence" && line.length > 0) {
        const [s, e] = sentenceRange(line.text, head - line.from);
        if (s > 0) builder.add(line.from, line.from + s, dimText);
        if (e < line.length) builder.add(line.from + e, line.to, dimText);
      }
      pos = line.to + 1;
    }
  }
  return builder.finish();
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
