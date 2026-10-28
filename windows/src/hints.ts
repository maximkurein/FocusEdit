// The hints cheat sheet (F1 / Ctrl+? / ⌘?), per document type.
// Keys follow the app that is running: Ctrl on Windows, ⌘ when this build is on a Mac.
// The native Mac app has its own list (HintsViewController) with Apple shortcuts (⌥⌘P, …).

import type { DocKind } from "./completion";

type Row = [keys: string, text: string];

/** Shortcuts for the Windows app on the OS it is running on. */
export type HintKeys = {
  mod: string;
  palette: string;
  view: string;
  outline: string;
  hints: string;
  fullscreen: string;
  complete: string;
  zoom: string;
  typewriter: string;
  print: string;
  find: string;
  close: string;
  save: string;
  saveAs: string;
  open: string;
  neu: string;
  newFile: string;
  bold: string;
  italic: string;
  link: string;
  redo: string;
};

export function hintKeys(isMac: boolean): HintKeys {
  const mod = isMac ? "⌘" : "Ctrl+";
  return {
    mod,
    palette: `${mod}Shift+P`,
    view: `${mod}Shift+V`,
    outline: `${mod}Shift+O`,
    hints: isMac ? "⌘?" : "F1",
    fullscreen: isMac ? "⌃⌘F" : "F11",
    complete: `${mod}Space`,
    zoom: isMac ? "⌘+  ⌘−  ⌘0" : "Ctrl++  Ctrl+−  Ctrl+0",
    typewriter: `${mod}T`,
    print: `${mod}P`,
    find: `${mod}F`,
    close: `${mod}W`,
    save: `${mod}S`,
    saveAs: `${mod}Shift+S`,
    open: `${mod}O`,
    neu: `${mod}N`,
    newFile: `${mod}Shift+N`,
    bold: `${mod}B`,
    italic: `${mod}I`,
    link: `${mod}K`,
    redo: `${mod}R`,
  };
}

export function hintSections(kind: DocKind, keys: HintKeys): { title: string; rows: Row[] }[] {
  const k = keys;
  const sections: { title: string; rows: Row[] }[] = [
    {
      title: "Commands",
      rows: [
        [k.palette, "Command palette: type what you want to do"],
        [k.hints, "This sheet — also the toolbar ?"],
        ["a number", "In the palette: set a word goal, or go to a line"],
        ["Word goal", "Palette: progress bar under the toolbar, writing time"],
        ["Select + paste URL", "Makes a Markdown link"],
        ["Markup", "Palette: hide the marks (#, **, [ ]) away from the cursor"],
      ],
    },
    {
      title: "Writing",
      rows: [
        ["Tab  →", "Accept the grey suggestion"],
        ["Esc", `Dismiss it  ·  ${k.complete} lists all completions`],
        ["Enter", "Continue a list or quote; on an empty item, end it"],
        ['( [ { " `', "Close automatically; select text first to wrap it"],
      ],
    },
    {
      title: "Focus",
      rows: [
        ["◎ toolbar", "Highlight off · sentence · paragraph — click to cycle"],
        [k.typewriter, "Typewriter: keep the caret line centred (starts off)"],
        [k.zoom, k.mod === "⌘"
          ? "Text size, also ⌘-scroll; the preview follows"
          : "Text size, also Ctrl-scroll; the preview follows"],
        [k.fullscreen, "Full screen"],
      ],
    },
  ];
  if (kind !== "fountain") {
    const viewRows: Row[] = [
      [k.view, "Edit → Split (live preview) → Preview — or the toolbar; Esc leaves Preview"],
      [k.outline, "Outline of the headings"],
      ["Preview theme", "Palette: same as the editor, or its own"],
    ];
    if (kind === "markdown") viewRows.push(["Click a code block", "In the preview, copies the command"]);
    sections.push({ title: "View", rows: viewRows });
  }
  sections.push({
    title: "Vim mode (Vim button in the toolbar)",
    rows: [
      ["Esc  i  v  :", "Normal · insert · select · command line"],
      ["h j k l  w b e", "Move by character, line, word"],
      ["0 ^ $  gg G", "Line start · first text · end · first / last line"],
      ["d c y + motion", "dw, ciw, y$ — dd, cc, yy for whole lines"],
      ["x  p  u  .", `Delete a character · put · undo · repeat (redo: ${k.redo})`],
      [":w :q :wq :novim", "Save · close · both · leave Vim mode"],
    ],
  });
  if (kind === "markdown") {
    sections.push({
      title: "Markdown",
      rows: [
        ["# Title", "Heading — see the outline"],
        ["**b**  *i*", `Bold ${k.bold} · italic ${k.italic}`],
        ["- item  1. item", "Lists · - [ ] task"],
        ["> quote", "Blockquote"],
        ["[text](url)", `Link · ${k.link}`],
      ],
    });
  }
  if (kind === "fountain") {
    sections.push({
      title: "Fountain",
      rows: [
        ["INT. / EXT.", "Scene heading — type IN, press Tab"],
        ["MARY", "Character — names you used are suggested"],
        ["(quietly)", "Parenthetical"],
        ["CUT TO:", "Transition"],
        ["# Act  = note", "Section · synopsis"],
      ],
    });
  }
  sections.push({
    title: "Files",
    rows: [
      [`${k.newFile}  ${k.neu}`, "New file… · empty document"],
      [`${k.open}  ${k.save}  ${k.saveAs}`, "Open · save · save as"],
      [k.close, "Close the file; the window stays with a start screen"],
      [k.print, "Print, or save as PDF from the print dialog"],
      ["⋯ toolbar", "Recent files · export HTML · copy as HTML"],
      [k.find, "Find and replace"],
      ["drag a file", "Drop .md, .txt, .rtf or .fountain on the window"],
    ],
  });
  return sections;
}

export function appendAbout(
  container: HTMLElement,
  version: string,
  openPage: () => void,
  openSupport: () => void,
): void {
  const about = document.createElement("div");
  about.className = "about";
  const title = document.createElement("div");
  title.className = "about-title";
  title.textContent = `FocusEdit ${version}`;
  const author = document.createElement("div");
  author.textContent = "Developer: Kurein M.N.";
  const link = document.createElement("button");
  link.type = "button";
  link.className = "about-link";
  link.textContent = "github.com/maximkurein/FocusEdit";
  link.addEventListener("click", openPage);
  // Optional and quiet: one line, only here.
  const coffee = document.createElement("button");
  coffee.type = "button";
  coffee.className = "about-link about-coffee";
  coffee.textContent = "☕ Buy the developer a coffee";
  coffee.addEventListener("click", openSupport);
  about.append(title, author, link, document.createElement("br"), coffee);
  container.append(about);
}

export function renderHints(container: HTMLElement, kind: DocKind, keys: HintKeys): void {
  container.replaceChildren();
  for (const section of hintSections(kind, keys)) {
    const h = document.createElement("h3");
    h.textContent = section.title;
    container.append(h);
    const dl = document.createElement("dl");
    for (const [keys, text] of section.rows) {
      const dt = document.createElement("dt");
      dt.textContent = keys;
      const dd = document.createElement("dd");
      dd.textContent = text;
      dl.append(dt, dd);
    }
    container.append(dl);
  }
}
