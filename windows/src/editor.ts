// The CodeMirror editor: Markdown language, highlight style, focus and
// typewriter layers, inline completion, automatic pairing and formatting
// commands. Settings change at runtime through compartments.

import { autocompletion, closeBrackets, closeBracketsKeymap, type CompletionContext, completionKeymap } from "@codemirror/autocomplete";
import { defaultKeymap, history, historyKeymap, insertTab } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { search, searchKeymap } from "@codemirror/search";
import { Compartment, EditorSelection, EditorState, type Extension, type StateCommand, type Text } from "@codemirror/state";
import { drawSelection, dropCursor, EditorView, highlightSpecialChars, keymap, placeholder } from "@codemirror/view";
import { tags as t } from "@lezer/highlight";
import { CompletionEngine, type DocKind } from "./completion";
import { focusHighlighting, typewriterScrolling } from "./focus";
import { inlineCompletion } from "./ghost";
import type { Settings } from "./settings";

export type LineSeparator = "\n" | "\r\n";

// Markdown marks (#, *, -, >, `) are muted so the words stand out; bold and
// italic keep their weight and slant even in dimmed lines.
const highlightStyle = HighlightStyle.define([
  { tag: [t.heading, t.heading1, t.heading2, t.heading3, t.heading4, t.heading5, t.heading6], fontWeight: "700" },
  { tag: t.strong, fontWeight: "700" },
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: t.strikethrough, textDecoration: "line-through" },
  { tag: t.monospace, fontFamily: "var(--mono-font)", color: "var(--muted)" },
  { tag: t.quote, color: "var(--muted)" },
  { tag: [t.link, t.url], color: "var(--accent)" },
  { tag: [t.processingInstruction, t.contentSeparator], color: "var(--muted)" },
]);

// Pairs that close themselves. No apostrophe (it's / don't), no curly “ (CodeMirror
// would close it with the same character).
const pairing = EditorState.languageData.of(() => [{ closeBrackets: { brackets: ["(", "[", "{", '"', "`", "«"] } }]);

/** Wrap the selection (or the cursor) in Markdown markers. */
export function wrapWith(before: string, after: string): StateCommand {
  return ({ state, dispatch }) => {
    dispatch(
      state.update(
        state.changeByRange((range) =>
          range.empty
            ? {
                changes: { from: range.from, insert: before + after },
                range: EditorSelection.cursor(range.from + before.length),
              }
            : {
                changes: [
                  { from: range.from, insert: before },
                  { from: range.to, insert: after },
                ],
                range: EditorSelection.range(range.from + before.length, range.to + before.length),
              },
        ),
        { userEvent: "input.format", scrollIntoView: true },
      ),
    );
    return true;
  };
}

const formatKeymap = [
  { key: "Mod-b", run: wrapWith("**", "**") },
  { key: "Mod-i", run: wrapWith("*", "*") },
  { key: "Mod-k", run: wrapWith("[", "](https://)") },
];

export function placeholderFor(kind: DocKind, hintsKey: string): string {
  const hints = `   ·   ${hintsKey} hints`;
  if (kind === "markdown") return `Start writing — # heading, **bold**, - list${hints}`;
  if (kind === "fountain") return `INT. LOCATION - DAY${hints}`;
  return `Start writing…${hints}`;
}

export interface EditorOptions {
  settings: Settings;
  hintsKey: string;
  onChange: (doc: Text) => void;
}

export class Editor {
  readonly view: EditorView;
  readonly engine = new CompletionEngine();
  private kind: DocKind = "plain";
  private separator: LineSeparator = "\n";
  private engineDoc: Text | null = null;

  private readonly focus = new Compartment();
  private readonly typewriter = new Compartment();
  private readonly pairs = new Compartment();
  private readonly language = new Compartment();
  private readonly hint = new Compartment();
  private readonly lineSep = new Compartment();

  constructor(
    parent: HTMLElement,
    private readonly options: EditorOptions,
  ) {
    this.view = new EditorView({ parent, state: this.createState("") });
  }

  private get settings(): Settings {
    return this.options.settings;
  }

  private createState(doc: string): EditorState {
    const s = this.settings;
    const extensions: Extension[] = [
      this.lineSep.of(EditorState.lineSeparator.of(this.separator)),
      history(),
      drawSelection(),
      dropCursor(),
      highlightSpecialChars(),
      EditorView.lineWrapping,
      EditorView.contentAttributes.of({ spellcheck: "true", autocorrect: "off", autocapitalize: "sentences" }),
      this.hint.of(placeholder(placeholderFor(this.kind, this.options.hintsKey))),
      this.language.of(this.languageFor(this.kind)),
      syntaxHighlighting(highlightStyle),
      pairing,
      this.pairs.of(s.pairing ? closeBrackets() : []),
      autocompletion({ override: [(ctx) => this.wordCompletions(ctx)], activateOnTyping: false, icons: false }),
      inlineCompletion({
        enabled: () => this.settings.autocomplete,
        provider: (prefix, linePrefix, state) => {
          this.syncEngine(state.doc);
          return this.engine.suffix(prefix, linePrefix);
        },
      }),
      this.focus.of(focusHighlighting(s.focusMode)),
      this.typewriter.of(s.typewriter ? typewriterScrolling() : []),
      search({ top: true }),
      keymap.of([
        ...closeBracketsKeymap,
        ...formatKeymap,
        ...completionKeymap,
        ...searchKeymap,
        ...historyKeymap,
        ...defaultKeymap,
        { key: "Tab", run: insertTab },
      ]),
      EditorView.updateListener.of((u) => {
        if (u.docChanged) this.options.onChange(u.state.doc);
      }),
    ];
    return EditorState.create({ doc, extensions });
  }

  private languageFor(kind: DocKind): Extension {
    // GFM: task lists and strikethrough; Enter continues lists, quotes and tasks.
    return kind === "markdown" ? markdown({ base: markdownLanguage }) : [];
  }

  private syncEngine(doc: Text): void {
    if (doc !== this.engineDoc) {
      this.engine.update(doc.toString());
      this.engineDoc = doc;
    }
  }

  private wordCompletions(ctx: CompletionContext) {
    const word = ctx.matchBefore(/[\p{L}\p{N}'’-]+/u);
    if (!word || (word.from === word.to && !ctx.explicit)) return null;
    this.syncEngine(ctx.state.doc);
    const line = ctx.state.doc.lineAt(ctx.pos);
    const options = this.engine
      .completions(word.text, line.text.slice(0, ctx.pos - line.from))
      .map((label) => ({ label, type: "text" }));
    return options.length ? { from: word.from, options, validFor: /^[\p{L}\p{N}'’-]*$/u } : null;
  }

  /** Replace the whole document (open / new); resets undo history. */
  load(text: string, kind: DocKind, separator: LineSeparator): void {
    this.kind = kind;
    this.separator = separator;
    this.engine.kind = kind;
    this.engineDoc = null;
    this.view.setState(this.createState(text));
  }

  /** Save As to another extension: switch language without touching the text. */
  setKind(kind: DocKind): void {
    if (kind === this.kind) return;
    this.kind = kind;
    this.engine.kind = kind;
    this.engineDoc = null;
    this.view.dispatch({
      effects: [
        this.language.reconfigure(this.languageFor(kind)),
        this.hint.reconfigure(placeholder(placeholderFor(kind, this.options.hintsKey))),
      ],
    });
  }

  /** Apply changed settings (focus mode, typewriter, pairing). */
  applySettings(): void {
    const s = this.settings;
    this.view.dispatch({
      effects: [
        this.focus.reconfigure(focusHighlighting(s.focusMode)),
        this.typewriter.reconfigure(s.typewriter ? typewriterScrolling() : []),
        this.pairs.reconfigure(s.pairing ? closeBrackets() : []),
      ],
    });
  }

  get text(): string {
    return this.view.state.doc.toString();
  }

  get lineSeparator(): LineSeparator {
    return this.separator;
  }

  focusEditor(): void {
    this.view.focus();
  }
}
