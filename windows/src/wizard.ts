// The "New file…" dialog: three steps — format, what to start from, name and place.

import {
  defaultName,
  fileName,
  FORMATS,
  type FileFormat,
  joinPath,
  STEP_TITLES,
  TEMPLATES,
  type TemplateId,
} from "./newfile";

export interface WizardResult {
  format: FileFormat;
  template: TemplateId;
  /** The name as typed (cleaned up by `fileName` when the file is made). */
  name: string;
  /** null in the browser, where the file is downloaded instead. */
  folder: string | null;
}

export interface WizardOptions {
  date: string;
  /** Where files go unless changed; null when there are no folders (browser). */
  folder: string | null;
  chooseFolder: () => Promise<string | null>;
}

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, className?: string, text?: string): HTMLElementTagNameMap[K] => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

export class NewFileWizard {
  private step = 1;
  private format: FileFormat = "md";
  private template: TemplateId = "blank";
  private name = "";
  private nameEdited = false;
  private folder: string | null = null;
  private options!: WizardOptions;
  private done: ((result: WizardResult | null) => void) | null = null;

  private readonly panel: HTMLElement;
  private readonly stepLine: HTMLElement;
  private readonly body: HTMLElement;
  private readonly back: HTMLButtonElement;
  private readonly next: HTMLButtonElement;
  private readonly dots: HTMLElement;

  constructor(
    private readonly root: HTMLElement,
    private readonly onClose: () => void,
  ) {
    this.panel = el("div", "wizard-panel");
    const head = el("div", "wizard-head");
    head.append(el("h2", "wizard-title", "New file"));
    this.stepLine = el("div", "wizard-step");
    this.dots = el("div", "wizard-dots");
    head.append(this.stepLine, this.dots);
    this.body = el("div", "wizard-body");
    const foot = el("div", "wizard-foot");
    const cancel = el("button", "wizard-button", "Cancel");
    cancel.type = "button";
    cancel.addEventListener("click", () => this.finish(null));
    this.back = el("button", "wizard-button", "Back");
    this.back.type = "button";
    this.back.addEventListener("click", () => this.go(this.step - 1));
    this.next = el("button", "wizard-button primary", "Next");
    this.next.type = "button";
    this.next.addEventListener("click", () => this.advance());
    const spacer = el("span", "wizard-spacer");
    foot.append(cancel, spacer, this.back, this.next);
    this.panel.append(head, this.body, foot);
    root.append(this.panel);
    root.addEventListener("pointerdown", (e) => {
      if (e.target === root) this.finish(null);
    });
    root.addEventListener("keydown", (e) => this.onKey(e));
  }

  get isOpen(): boolean {
    return !this.root.hidden;
  }

  /** Shows the dialog; resolves with the choices, or null when cancelled. */
  ask(options: WizardOptions): Promise<WizardResult | null> {
    this.options = options;
    this.folder = options.folder;
    this.format = "md";
    this.template = "blank";
    this.name = "";
    this.nameEdited = false;
    this.step = 1;
    this.root.hidden = false;
    this.render();
    return new Promise((resolve) => (this.done = resolve));
  }

  private finish(result: WizardResult | null): void {
    if (!this.done) return;
    const done = this.done;
    this.done = null;
    this.root.hidden = true;
    done(result);
    this.onClose();
  }

  private go(step: number): void {
    this.step = Math.min(3, Math.max(1, step));
    if (this.step === 3 && !this.nameEdited) this.name = defaultName(this.template, this.options.date);
    this.render();
  }

  private advance(): void {
    if (this.step < 3) this.go(this.step + 1);
    else this.create();
  }

  private create(): void {
    this.finish({ format: this.format, template: this.template, name: this.name, folder: this.folder });
  }

  private onKey(e: KeyboardEvent): void {
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      this.finish(null);
    } else if (e.key === "Enter" && !(e.target instanceof HTMLButtonElement && e.target !== this.next && !e.target.classList.contains("wizard-option"))) {
      e.preventDefault();
      this.advance();
    } else if ((e.key === "ArrowDown" || e.key === "ArrowUp") && this.step < 3) {
      e.preventDefault();
      const ids = this.step === 1 ? FORMATS.map((f) => f.id as string) : TEMPLATES.map((t) => t.id as string);
      const current = ids.indexOf(this.step === 1 ? this.format : this.template);
      const target = ids[(current + (e.key === "ArrowDown" ? 1 : ids.length - 1)) % ids.length];
      if (this.step === 1) this.format = target as FileFormat;
      else this.template = target as TemplateId;
      this.render();
    }
    e.stopPropagation(); // the editor behind must not see these keys
  }

  private render(): void {
    this.stepLine.textContent = `Step ${this.step} of 3 · ${STEP_TITLES[this.step - 1]}`;
    this.dots.replaceChildren(
      ...[1, 2, 3].map((n) => el("span", "wizard-dot" + (n === this.step ? " current" : n < this.step ? " past" : ""))),
    );
    this.back.hidden = this.step === 1;
    this.next.textContent = this.step === 3 ? "Create" : "Next";
    this.body.replaceChildren();
    if (this.step === 1) this.renderChoices(FORMATS.map((f) => ({ id: f.id, title: `${f.title}  ${f.extension}`, description: f.description })), this.format, (id) => (this.format = id as FileFormat));
    else if (this.step === 2) this.renderChoices(TEMPLATES, this.template, (id) => (this.template = id as TemplateId));
    else this.renderName();
  }

  private renderChoices(
    items: { id: string; title: string; description: string }[],
    selected: string,
    select: (id: string) => void,
  ): void {
    const group = el("div", "wizard-options");
    group.setAttribute("role", "radiogroup");
    for (const item of items) {
      const option = el("button", "wizard-option" + (item.id === selected ? " selected" : ""));
      option.type = "button";
      option.setAttribute("role", "radio");
      option.setAttribute("aria-checked", String(item.id === selected));
      option.append(el("span", "wizard-option-title", item.title), el("span", "wizard-option-text", item.description));
      option.addEventListener("click", () => {
        select(item.id);
        this.render();
      });
      option.addEventListener("dblclick", () => this.advance());
      group.append(option);
    }
    this.body.append(group);
    group.querySelector<HTMLElement>(".selected")?.focus();
  }

  private renderName(): void {
    const label = el("label", "wizard-label", "File name");
    const input = el("input", "wizard-input");
    input.type = "text";
    input.value = this.name;
    input.spellcheck = false;
    input.setAttribute("aria-label", "File name");
    const preview = el("div", "wizard-preview");
    const showPreview = () => {
      const name = fileName(input.value, this.format);
      preview.textContent = this.folder ? joinPath(this.folder, name) : name;
    };
    input.addEventListener("input", () => {
      this.name = input.value;
      this.nameEdited = true;
      showPreview();
    });
    label.append(input);
    this.body.append(label);
    if (this.options.folder !== null) {
      const row = el("div", "wizard-folder");
      row.append(el("span", "wizard-label", "Folder"));
      const path = el("span", "wizard-folder-path", this.folder ?? "");
      const change = el("button", "wizard-button", "Change…");
      change.type = "button";
      change.addEventListener("click", async () => {
        const chosen = await this.options.chooseFolder();
        if (chosen) {
          this.folder = chosen;
          path.textContent = chosen;
          showPreview();
        }
      });
      row.append(path, change);
      this.body.append(row);
    }
    this.body.append(el("div", "wizard-label", "Will be saved as"), preview);
    showPreview();
    input.focus();
    input.select();
  }
}
