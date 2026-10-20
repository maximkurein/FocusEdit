// The command palette: type a few letters of what you want to do, press Enter.

export interface Command {
  title: string;
  /** Shown dimmed on the right. */
  shortcut?: string;
  /** Extra words that find the command ("dark", "night" for a theme). */
  keywords?: string;
  run: () => void;
}

/** How well `query` matches `text`: lower is better, null = no match. Every word of the query must match. */
export function matchScore(query: string, text: string): number | null {
  const haystack = text.toLowerCase();
  let total = 0;
  for (const word of query.toLowerCase().split(/\s+/).filter(Boolean)) {
    const at = haystack.indexOf(word);
    if (at >= 0) {
      // Earlier is better, and the start of a word is better than the middle of one.
      const wordStart = at === 0 || /[\s:/\-.]/.test(haystack[at - 1]);
      total += at + (wordStart ? 0 : 20);
      continue;
    }
    // Letters in order ("tdark" → "Theme: Dark"): a weaker match.
    let from = 0;
    let ok = true;
    for (const ch of word) {
      const found = haystack.indexOf(ch, from);
      if (found < 0) {
        ok = false;
        break;
      }
      from = found + 1;
    }
    if (!ok) return null;
    total += 100 + from;
  }
  return total;
}

/** The commands that match, best first; with an empty query all of them in their own order. */
export function filterCommands(commands: Command[], query: string): Command[] {
  if (query.trim() === "") return commands;
  const scored: { command: Command; score: number; index: number }[] = [];
  commands.forEach((command, index) => {
    const score = matchScore(query, `${command.title} ${command.keywords ?? ""}`);
    if (score !== null) scored.push({ command, score, index });
  });
  scored.sort((a, b) => a.score - b.score || a.index - b.index);
  return scored.map((s) => s.command);
}

/** The overlay: an input and the list under it. */
export class Palette {
  private readonly input: HTMLInputElement;
  private readonly list: HTMLElement;
  private shown: Command[] = [];
  private selected = 0;
  private provider: (query: string) => Command[] = () => [];

  constructor(
    private readonly root: HTMLElement,
    private readonly onClose: () => void,
  ) {
    this.input = root.querySelector("input") as HTMLInputElement;
    this.list = root.querySelector("ul") as HTMLElement;
    this.input.addEventListener("input", () => this.refresh());
    this.input.addEventListener("keydown", (e) => this.onKey(e));
    // A click outside the panel closes it.
    root.addEventListener("pointerdown", (e) => {
      if (e.target === root) this.close();
    });
  }

  get isOpen(): boolean {
    return !this.root.hidden;
  }

  /** `commands(query)` returns what to list for what has been typed so far. */
  open(commands: (query: string) => Command[]): void {
    this.provider = commands;
    this.root.hidden = false;
    this.input.value = "";
    this.refresh();
    this.input.focus();
  }

  close(): void {
    if (!this.isOpen) return;
    this.root.hidden = true;
    this.onClose();
  }

  private refresh(): void {
    this.shown = this.provider(this.input.value);
    this.selected = 0;
    this.render();
  }

  private render(): void {
    this.list.replaceChildren();
    if (this.shown.length === 0) {
      const empty = document.createElement("li");
      empty.className = "palette-empty";
      empty.textContent = "No matching command";
      this.list.append(empty);
      return;
    }
    this.shown.forEach((command, i) => {
      const item = document.createElement("li");
      item.className = "palette-item" + (i === this.selected ? " selected" : "");
      const title = document.createElement("span");
      title.textContent = command.title;
      item.append(title);
      if (command.shortcut) {
        const key = document.createElement("span");
        key.className = "palette-key";
        key.textContent = command.shortcut;
        item.append(key);
      }
      item.addEventListener("pointermove", () => this.select(i, false));
      item.addEventListener("click", () => this.run(i));
      this.list.append(item);
    });
  }

  private select(i: number, scroll = true): void {
    if (i === this.selected || this.shown.length === 0) return;
    this.list.children[this.selected]?.classList.remove("selected");
    this.selected = i;
    const el = this.list.children[i];
    el?.classList.add("selected");
    if (scroll) el?.scrollIntoView({ block: "nearest" });
  }

  private run(i: number): void {
    const command = this.shown[i];
    if (!command) return;
    this.close();
    command.run();
  }

  private onKey(e: KeyboardEvent): void {
    // Nothing typed here may reach the shortcuts of the page.
    e.stopPropagation();
    const n = this.shown.length;
    if (e.key === "Escape") {
      e.preventDefault();
      this.close();
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      if (n > 0) this.select((this.selected + 1) % n);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      if (n > 0) this.select((this.selected - 1 + n) % n);
    } else if (e.key === "Enter") {
      e.preventDefault();
      this.run(this.selected);
    }
  }
}
