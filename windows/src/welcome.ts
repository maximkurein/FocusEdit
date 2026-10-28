// The welcome document: shown once on the first start, and again from the
// command palette ("Open the welcome tour"). It teaches by being edited.

const KEY = "focusedit.welcomed.v1";

type Store = Pick<Storage, "getItem" | "setItem">;

const defaultStore = (): Store | null => {
  try {
    return localStorage;
  } catch {
    return null;
  }
};

export function wasWelcomed(store: Store | null = defaultStore()): boolean {
  try {
    return store?.getItem(KEY) === "1";
  } catch {
    return true; // storage blocked: don't show it on every start
  }
}

export function markWelcomed(store: Store | null = defaultStore()): void {
  try {
    store?.setItem(KEY, "1");
  } catch {
    // Not remembered: it may show again next time.
  }
}

export function welcomeText(mod: string): string {
  return `# Welcome to FocusEdit

A quiet place to write. Everything you are not working on fades away, and your
file stays plain text.

## Try this

- Move the caret between paragraphs: the **focus** fades smoothly. The target button in the toolbar switches Off · Sentence · Paragraph.
- Start a word and see the grey suggestion: press Tab to take it.
- Select a word and paste a web address: you get a link.
- Type \`- \` and a list item, press Enter: the list continues.
- Press ${mod}Shift+P and type "theme": every command is in the palette.

## Look around

| Keys | What it does |
|---|---|
| ${mod}Shift+P | Command palette: find anything by typing |
| ${mod}Shift+V | View: Edit → Split → Preview |
| ${mod}Shift+O | Outline of the headings |
| ${mod}T | Keep the line you are writing in the middle |
| ${mod === "⌘" ? "⌘?" : "F1"} | Hints and shortcuts |

> Set a word goal from the palette ("Word goal") for a thin progress bar and a timer
> that counts only the time you actually write.

## Learn Vim while you write

The Vim button in the toolbar turns on Vim mode with a coach under the text that
explains every command. :novim turns it off again.

---

Save this document with ${mod}S, or start a new one with ${mod}N. Ready? Press ${mod}A and start typing over all of this.
`;
}
