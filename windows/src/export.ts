// Export: a standalone HTML page, copy as HTML, and printing (the print dialog
// of Windows also saves a PDF).

import { renderMarkdown } from "./markdown-html";

const escapeHtml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const STYLE = `
  :root { color-scheme: light; }
  body { font: 16px/1.65 "Segoe UI", system-ui, -apple-system, sans-serif; color: #1c1c1f; background: #fff;
         max-width: 720px; margin: 40px auto; padding: 0 24px; }
  h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.5em 0 .5em; }
  h1:first-child { margin-top: 0; }
  a { color: #2f7deb; }
  blockquote { margin: 0 0 1em; padding-left: 1em; border-left: 3px solid #d8d8dc; color: #6b6b70; }
  code { font-family: "Cascadia Mono", Consolas, monospace; font-size: .9em; background: rgba(127,127,127,.15);
         padding: .1em .35em; border-radius: 4px; }
  pre { background: rgba(127,127,127,.12); padding: 12px 14px; border-radius: 8px; overflow: auto; }
  pre code { background: none; padding: 0; }
  table { border-collapse: collapse; margin-bottom: 1em; }
  th, td { border: 1px solid #d8d8dc; padding: 5px 12px; }
  th { background: rgba(127,127,127,.12); }
  hr { border: 0; border-top: 1px solid #d8d8dc; margin: 1.5em 0; }
  li.task { list-style: none; margin-left: -1.3em; }
  .image { color: #6b6b70; font-style: italic; }
`;

/** A complete, self-contained HTML page for the document. */
export function htmlDocument(markdown: string, title: string): string {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>${STYLE}</style></head>
<body>
${renderMarkdown(markdown)}</body></html>
`;
}

/** The file name without its extension, for the page title. */
export function titleOf(name: string): string {
  return name.replace(/\.[^.]+$/, "") || name;
}

/** Put the rendered document on the clipboard as HTML (and the HTML source as plain text). */
export async function copyAsHtml(markdown: string): Promise<boolean> {
  const html = renderMarkdown(markdown);
  try {
    await navigator.clipboard.write([
      new ClipboardItem({
        "text/html": new Blob([html], { type: "text/html" }),
        "text/plain": new Blob([html], { type: "text/plain" }),
      }),
    ]);
    return true;
  } catch {
    try {
      await navigator.clipboard.writeText(html);
      return true;
    } catch {
      return false;
    }
  }
}

/** Open the print dialog for the rendered document (everything else on the page is hidden while printing). */
export function printMarkdown(root: HTMLElement, markdown: string): void {
  root.innerHTML = renderMarkdown(markdown);
  document.body.classList.add("printing");
  const done = () => {
    document.body.classList.remove("printing");
    root.replaceChildren();
  };
  window.addEventListener("afterprint", done, { once: true });
  window.print();
}
