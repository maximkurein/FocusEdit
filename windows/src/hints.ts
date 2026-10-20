// The hints cheat sheet (F1 / Ctrl+?), per document type — HintsViewController on macOS.

import type { DocKind } from "./completion";

type Row = [keys: string, text: string];

export function hintSections(kind: DocKind, mod: string): { title: string; rows: Row[] }[] {
  const sections: { title: string; rows: Row[] }[] = [
    {
      title: "Writing",
      rows: [
        ["Tab  →", "Accept the grey suggestion"],
        ["Esc", `Dismiss it  ·  ${mod}Space lists all completions`],
        ["Enter", "Continue a list or quote; on an empty item, end it"],
        ['( [ { " `', "Close automatically; select text first to wrap it"],
      ],
    },
    {
      title: "Focus",
      rows: [
        ["◎ toolbar", "Highlight off · sentence · paragraph — click to cycle"],
        [`${mod}T`, "Keep the active line centred"],
        ["F11", "Full screen"],
        [`${mod}+  ${mod}−`, "Text size"],
      ],
    },
    {
      title: "View (eye button in the toolbar)",
      rows: [
        [`${mod}Shift+P`, "Switch: Edit → Split → Preview → Edit"],
        ["Split", "Editor and live preview side by side"],
        ["Preview", "Reading view; Esc goes back to editing"],
      ],
    },
  ];
  sections.push({
    title: "Vim mode (Vim button in the toolbar)",
    rows: [
      ["Esc  i  v  :", "Normal · insert · select · command line"],
      ["h j k l  w b e", "Move by character, line, word"],
      ["0 ^ $  gg G", "Line start · first text · end · first / last line"],
      ["d c y + motion", "dw, ciw, y$ — dd, cc, yy for whole lines"],
      ["x  p  u  .", `Delete a character · put · undo · repeat (redo: ${mod}R)`],
      [":w :q :wq :novim", "Save · close · both · leave Vim mode"],
    ],
  });
  if (kind === "markdown") {
    sections.push({
      title: "Markdown",
      rows: [
        ["# Title", "Heading"],
        ["**b**  *i*", `Bold ${mod}B · italic ${mod}I`],
        ["- item  1. item", "Lists · - [ ] task"],
        ["> quote", "Blockquote"],
        ["[text](url)", `Link · ${mod}K`],
      ],
    });
  }
  sections.push({
    title: "Files",
    rows: [
      [`${mod}N  ${mod}O`, "New · open"],
      ["⋯ toolbar", "Recent files · export HTML · copy as HTML"],
      [`${mod}P`, "Print, or save as PDF from the print dialog"],
      [`${mod}Shift+O`, "Outline: headings of the document"],
      ["drag a file", "Drop .md, .txt or .fountain on the window to open it"],
      [`${mod}S  ${mod}⇧S`, "Save · save as"],
      [`${mod}F`, "Find and replace"],
    ],
  });
  return sections;
}

export function appendAbout(container: HTMLElement, version: string, openPage: () => void): void {
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
  about.append(title, author, link);
  container.append(about);
}

export function renderHints(container: HTMLElement, kind: DocKind, mod: string): void {
  container.replaceChildren();
  for (const section of hintSections(kind, mod)) {
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
