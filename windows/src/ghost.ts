// Inline completion: a grey suffix after the cursor, the CodeMirror version of
// FocusTextView's "ghost" text. Shown only right after typing a letter, at the
// end of a line, once at least two letters of the word are typed.
// Tab or → accepts, Esc dismisses.

import {
  EditorSelection,
  type EditorState,
  type Extension,
  Facet,
  Prec,
  StateEffect,
  StateField,
  type StateCommand,
  type Transaction,
} from "@codemirror/state";
import { Decoration, EditorView, keymap, WidgetType } from "@codemirror/view";
import { isWordChar } from "./completion";

export interface Ghost {
  pos: number;
  text: string;
}

export interface GhostConfig {
  enabled: () => boolean;
  /** Text to append after `prefix`, or null. `state` already holds the typed letter. */
  provider: (prefix: string, linePrefix: string, state: EditorState) => string | null;
}

export const ghostConfig = Facet.define<GhostConfig, GhostConfig>({
  combine: (values) => values[values.length - 1] ?? { enabled: () => false, provider: () => null },
});

export const clearGhost = StateEffect.define<null>();

/** A single letter or digit typed with an empty selection. */
function typedOneWordChar(tr: Transaction): boolean {
  if (!tr.isUserEvent("input.type")) return false;
  let ok = true;
  let inserted = 0;
  tr.changes.iterChanges((fromA, toA, _fromB, _toB, text) => {
    inserted++;
    const s = text.toString();
    if (toA !== fromA || [...s].length !== 1 || !/[\p{L}\p{N}]/u.test(s)) ok = false;
  });
  return ok && inserted === 1;
}

export function computeGhost(state: EditorState): Ghost | null {
  const config = state.facet(ghostConfig);
  if (!config.enabled()) return null;
  const sel = state.selection;
  if (sel.ranges.length !== 1 || !sel.main.empty) return null;
  const pos = sel.main.head;
  const line = state.doc.lineAt(pos);
  if (pos !== line.to) return null; // only at the end of a line

  const before = line.text.slice(0, pos - line.from);
  let start = before.length;
  while (start > 0 && isWordChar(before[start - 1])) start--;
  const prefix = before.slice(start);
  if ([...prefix].length < 2) return null;

  const text = config.provider(prefix, before, state);
  return text ? { pos, text } : null;
}

export const ghostField = StateField.define<Ghost | null>({
  create: () => null,
  update(value, tr) {
    if (tr.effects.some((e) => e.is(clearGhost))) return null;
    if (tr.docChanged) return typedOneWordChar(tr) ? computeGhost(tr.state) : null;
    if (value && tr.selection) {
      const main = tr.state.selection.main;
      if (!main.empty || main.head !== value.pos) return null;
    }
    return value;
  },
  provide: (field) =>
    EditorView.decorations.from(field, (g) =>
      g ? Decoration.set([Decoration.widget({ widget: new GhostWidget(g.text), side: 1 }).range(g.pos)]) : Decoration.none,
    ),
});

class GhostWidget extends WidgetType {
  constructor(readonly text: string) {
    super();
  }
  eq(other: GhostWidget) {
    return other.text === this.text;
  }
  toDOM() {
    const span = document.createElement("span");
    span.className = "cm-ghost";
    span.textContent = this.text;
    span.setAttribute("aria-hidden", "true");
    return span;
  }
  ignoreEvent() {
    return true;
  }
}

/** Insert the suggestion; false when there is none (the key falls through). */
export const acceptGhost: StateCommand = ({ state, dispatch }) => {
  const g = state.field(ghostField, false);
  if (!g || state.selection.main.head !== g.pos) return false;
  dispatch(
    state.update({
      changes: { from: g.pos, insert: g.text },
      selection: EditorSelection.cursor(g.pos + g.text.length),
      effects: clearGhost.of(null),
      userEvent: "input.complete",
      scrollIntoView: true,
    }),
  );
  return true;
};

export const dismissGhost: StateCommand = ({ state, dispatch }) => {
  if (!state.field(ghostField, false)) return false;
  dispatch(state.update({ effects: clearGhost.of(null) }));
  return true;
};

export function inlineCompletion(config: GhostConfig): Extension {
  return [
    ghostConfig.of(config),
    ghostField,
    Prec.highest(
      keymap.of([
        { key: "Tab", run: acceptGhost },
        { key: "ArrowRight", run: acceptGhost },
        { key: "Escape", run: dismissGhost },
      ]),
    ),
  ];
}
