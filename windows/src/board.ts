// Excalidraw boards: free drawing with a hand-drawn look, in .excalidraw files — the
// Windows side of the Mac's Board.swift. The board (Excalidraw 0.18.1, MIT, built into
// Resources/excalidraw/board.js, copied to public/fe/excalidraw/) runs in an iframe that
// covers the window, with its own bar: Save, Save As, PNG, SVG, Copy PNG, Close. The text
// document stays open behind it. The page's API is `window.__feBoard` (load, save,
// fromMermaid, svg, png, setTheme); it reports unsaved changes as `boardChanged`.

import * as platform from "./platform";

interface FeBoard {
  load(json: string): void;
  save(): string;
  fromMermaid(source: string): Promise<{ ok: boolean; count?: number; error?: string }>;
  svg(): Promise<string>;
  png(): Promise<string>;
  setTheme(dark: boolean): void;
  isEmpty(): boolean;
  ready(): boolean;
}

const PAGE = "./fe/excalidraw/board.html";

/** "Diagram.excalidraw" for a name with another extension or none. */
export function boardName(name: string): string {
  const base = name.replace(/\.[^.]+$/, "") || "Board";
  return `${base}.excalidraw`;
}

const BUTTONS: [string, string, string][] = [
  ["save", "Save", "Save the board (Ctrl+S)"],
  ["save-as", "Save As…", "Save the board under a new name"],
  ["png", "PNG…", "Export the board as a PNG picture"],
  ["svg", "SVG…", "Export the board as an SVG picture"],
  ["copy", "Copy PNG", "Copy the board as a picture"],
  ["close", "Close", "Close the board and go back to the text (Esc)"],
];

export class BoardLayer {
  private frame: HTMLIFrameElement | null = null;
  private loaded: Promise<FeBoard | null> | null = null;
  private readonly nameEl: HTMLElement;
  path: string | null = null;
  name = "Board.excalidraw";
  dirty = false;

  constructor(
    private readonly root: HTMLElement,
    private readonly host: { notify(message: string): void; dark(): boolean; closed(): void },
  ) {
    const bar = document.createElement("div");
    bar.className = "board-bar";
    this.nameEl = document.createElement("span");
    this.nameEl.className = "board-name";
    bar.append(this.nameEl);
    const tools = document.createElement("span");
    tools.className = "board-tools";
    for (const [action, label, tip] of BUTTONS) {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "board-button";
      b.textContent = label;
      b.title = tip.replace("Ctrl+", platform.modKey);
      b.addEventListener("click", () => void this.run(action));
      tools.append(b);
    }
    bar.append(tools);
    root.append(bar);
    (window as unknown as { __feBoardMessage: (name: string, body: unknown) => void }).__feBoardMessage = (name, body) => {
      if (name === "boardChanged") this.setDirty(body === true);
      else if (name === "save") void this.save();
    };
  }

  get isOpen(): boolean {
    return !this.root.hidden;
  }

  /** The page, loaded once and kept while the app runs. */
  private board(): Promise<FeBoard | null> {
    this.loaded ??= new Promise((resolve) => {
      const frame = document.createElement("iframe");
      frame.className = "board-frame";
      frame.title = "Excalidraw board";
      frame.src = PAGE;
      frame.addEventListener("load", () => {
        const api = (frame.contentWindow as unknown as { __feBoard?: FeBoard } | null)?.__feBoard ?? null;
        resolve(api);
      });
      frame.addEventListener("error", () => resolve(null));
      this.root.append(frame);
      this.frame = frame;
    });
    return this.loaded;
  }

  private show(): void {
    this.root.hidden = false;
    this.render();
  }

  private render(): void {
    this.nameEl.textContent = (this.dirty ? "• " : "") + this.name;
  }

  private setDirty(dirty: boolean): void {
    this.dirty = dirty;
    this.render();
  }

  /** Before the board is replaced or closed: Save / Don't Save / Cancel. */
  async canDiscard(): Promise<boolean> {
    if (!this.isOpen || !this.dirty) return true;
    const choice = await platform.confirmClose(this.name);
    if (choice === "cancel") return false;
    if (choice === "save") return this.save();
    return true;
  }

  /** A board: an empty one, or a saved file's JSON. */
  async open(json = "", path: string | null = null, name = "Board.excalidraw"): Promise<boolean> {
    if (!(await this.canDiscard())) return false;
    this.show();
    const api = await this.board();
    if (!api) {
      this.host.notify("The Excalidraw board is missing from this build");
      this.root.hidden = true;
      return false;
    }
    try {
      api.setTheme(this.host.dark());
      api.load(json);
    } catch (error) {
      await platform.showError(`Could not open ${name}: ${String(error)}`);
      return false;
    }
    this.path = path;
    this.name = name;
    this.setDirty(false);
    this.frame?.focus();
    return true;
  }

  /** A new board drawn from a Mermaid diagram. */
  async openMermaid(source: string, name = "Diagram.excalidraw"): Promise<void> {
    if (!(await this.open("", null, name))) return;
    const api = await this.board();
    const result = await api!.fromMermaid(source);
    if (!result.ok) await platform.showError(`This diagram could not be turned into a drawing.\n\n${result.error ?? ""}`);
    else this.setDirty(true);
  }

  setTheme(dark: boolean): void {
    void this.loaded?.then((api) => api?.setTheme(dark));
  }

  /** Close the board (asking about unsaved changes); false when the user cancelled. */
  async close(): Promise<boolean> {
    if (!this.isOpen) return true;
    if (!(await this.canDiscard())) return false;
    this.root.hidden = true;
    this.dirty = false;
    this.host.closed();
    return true;
  }

  /** Save to the board's file (or ask where); true when saved. */
  async save(forceAsk = false): Promise<boolean> {
    const api = await this.board();
    if (!api) return false;
    const json = api.save();
    if (this.path && !forceAsk && platform.isTauri) {
      if (!(await platform.writeFile(this.path, json))) {
        this.setDirty(true);
        return false;
      }
    } else {
      const path = await platform.saveAs(this.name, json, platform.BOARD_FILTERS, "application/json");
      if (path === null) {
        this.setDirty(true);
        return false;
      }
      if (platform.isTauri) {
        this.path = path;
        this.name = platform.baseName(path);
      }
    }
    this.setDirty(false);
    this.host.notify(`Saved ${this.name}`);
    return true;
  }

  private async picture(type: "png" | "svg"): Promise<void> {
    const api = await this.board();
    if (!api) return;
    const base = this.name.replace(/\.excalidraw$/i, "");
    if (type === "svg") {
      const svg = await api.svg();
      if (await platform.saveAs(`${base}.svg`, svg, platform.SVG_FILTERS, "image/svg+xml")) this.host.notify("Exported as SVG");
      return;
    }
    const bytes = Uint8Array.from(atob(await api.png()), (c) => c.charCodeAt(0));
    if (await platform.saveAs(`${base}.png`, bytes, platform.PNG_FILTERS, "image/png")) this.host.notify("Exported as PNG");
  }

  private async copy(): Promise<void> {
    const api = await this.board();
    if (!api) return;
    try {
      const bytes = Uint8Array.from(atob(await api.png()), (c) => c.charCodeAt(0));
      await navigator.clipboard.write([new ClipboardItem({ "image/png": new Blob([bytes], { type: "image/png" }) })]);
      this.host.notify("Board copied as a picture");
    } catch {
      this.host.notify("Could not copy the picture");
    }
  }

  async run(action: string): Promise<void> {
    if (action === "save") await this.save();
    else if (action === "save-as") await this.save(true);
    else if (action === "png") await this.picture("png");
    else if (action === "svg") await this.picture("svg");
    else if (action === "copy") await this.copy();
    else if (action === "close") await this.close();
    else if (action === "escape" && !this.dirty) await this.close();
  }
}
