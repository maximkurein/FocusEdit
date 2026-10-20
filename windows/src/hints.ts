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
      [`${mod}S  ${mod}⇧S`, "Save · save as"],
      [`${mod}F`, "Find and replace"],
    ],
  });
  return sections;
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
