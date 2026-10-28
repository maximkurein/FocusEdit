// Markdown → HTML for the preview, built from the same CommonMark + GFM parse
// tree the editor uses (tables, task lists, strikethrough, autolinks).
// Raw HTML in the document is shown as text, never run, and links are limited
// to web addresses.

import { markdownLanguage } from "@codemirror/lang-markdown";
import type { SyntaxNode } from "@lezer/common";

const escapeHtml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/** The text a click in a preview code block should copy. Trailing whitespace is
 *  dropped so a command pastes ready to run. A drag-selection is left alone. */
export function copyableFence(text: string, selected = false): string | null {
  if (selected) return null;
  const trimmed = text.replace(/\s+$/g, "");
  return trimmed === "" ? null : trimmed;
}

/** Only addresses the app is willing to open; everything else renders as plain text. */
export function safeHref(href: string): string | null {
  const h = href.trim();
  return /^https?:\/\/[^\s]+$/i.test(h) ? h : null;
}

const MARKS = new Set([
  "HeaderMark", "QuoteMark", "ListMark", "EmphasisMark", "StrikethroughMark",
  "CodeMark", "LinkMark", "TaskMarker", "TableDelimiter", "CodeInfo",
]);

export function renderMarkdown(source: string): string {
  const text = source.replace(/\r\n?/g, "\n");
  const tree = markdownLanguage.parser.parse(text);
  const slice = (n: { from: number; to: number }) => text.slice(n.from, n.to);
  const children = (n: SyntaxNode): SyntaxNode[] => {
    const out: SyntaxNode[] = [];
    for (let c = n.firstChild; c; c = c.nextSibling) out.push(c);
    return out;
  };

  // [label]: url "title" definitions, for [text][label] links.
  const definitions = new Map<string, string>();
  for (let c = tree.topNode.firstChild; c; c = c.nextSibling) {
    if (c.name !== "LinkReference") continue;
    const label = c.getChild("LinkLabel");
    const url = c.getChild("URL");
    if (label && url) definitions.set(slice(label).slice(1, -1).trim().toLowerCase(), slice(url));
  }

  // ----------------------------------------------------------------- inline

  /** The text of `node`, with its child nodes rendered and the gaps escaped. */
  function inline(node: SyntaxNode, from = node.from, to = node.to): string {
    let out = "";
    let pos = from;
    for (const child of children(node)) {
      if (child.to <= from || child.from >= to) continue;
      if (child.from > pos) out += escapeHtml(text.slice(pos, child.from));
      out += inlineNode(child);
      pos = Math.max(pos, child.to);
    }
    if (pos < to) out += escapeHtml(text.slice(pos, to));
    return out;
  }

  function link(node: SyntaxNode): string {
    const marks = node.getChildren("LinkMark");
    // Link text sits between the first two marks: [ … ]
    const inner = marks.length >= 2 ? inline(node, marks[0].to, marks[1].from) : inline(node);
    let href = node.getChild("URL") ? slice(node.getChild("URL") as SyntaxNode) : null;
    const label = node.getChild("LinkLabel");
    if (href === null && label) href = definitions.get(slice(label).slice(1, -1).trim().toLowerCase()) ?? null;
    else if (href === null && marks.length >= 2) href = definitions.get(text.slice(marks[0].to, marks[1].from).trim().toLowerCase()) ?? null;
    const safe = href ? safeHref(href) : null;
    return safe ? `<a href="${escapeHtml(safe)}">${inner}</a>` : inner;
  }

  function inlineNode(n: SyntaxNode): string {
    switch (n.name) {
      case "Emphasis": return `<em>${inline(n)}</em>`;
      case "StrongEmphasis": return `<strong>${inline(n)}</strong>`;
      case "Strikethrough": return `<del>${inline(n)}</del>`;
      case "InlineCode": {
        const marks = n.getChildren("CodeMark");
        const body = marks.length >= 2 ? text.slice(marks[0].to, marks[marks.length - 1].from) : slice(n);
        return `<code>${escapeHtml(body)}</code>`;
      }
      case "Link": return link(n);
      case "Image": {
        const marks = n.getChildren("LinkMark");
        const alt = marks.length >= 2 ? text.slice(marks[0].to, marks[1].from) : "";
        return `<span class="image" title="Images are not shown in the preview">🖼 ${escapeHtml(alt)}</span>`;
      }
      case "Autolink": {
        const url = n.getChild("URL");
        const href = url ? slice(url) : "";
        const safe = safeHref(href);
        return safe ? `<a href="${escapeHtml(safe)}">${escapeHtml(href)}</a>` : escapeHtml(href);
      }
      case "URL": {
        const safe = safeHref(slice(n));
        return safe ? `<a href="${escapeHtml(safe)}">${escapeHtml(slice(n))}</a>` : escapeHtml(slice(n));
      }
      case "HardBreak": return "<br>\n";
      case "Escape": return escapeHtml(slice(n).slice(1));
      case "Entity": return /^&#?\w+;$/.test(slice(n)) ? slice(n) : escapeHtml(slice(n));
      default:
        return MARKS.has(n.name) ? "" : escapeHtml(slice(n));
    }
  }

  // ------------------------------------------------------------------ blocks

  const blocks = (n: SyntaxNode): string => children(n).map(block).join("");

  function listItem(n: SyntaxNode): string {
    const kids = children(n).filter((c) => c.name !== "ListMark");
    const task = kids.find((c) => c.name === "Task");
    if (task) {
      const marker = task.getChild("TaskMarker");
      const checked = marker ? /x/i.test(slice(marker)) : false;
      const rest = kids.filter((c) => c !== task).map(block).join("");
      return `<li class="task"><input type="checkbox" disabled${checked ? " checked" : ""}> ${inline(task).trim()}${rest}</li>\n`;
    }
    return `<li>${kids.map(block).join("")}</li>\n`;
  }

  function table(n: SyntaxNode): string {
    const header = n.getChild("TableHeader");
    // The |:--|--:| row is one delimiter node of the table; its cells say how to align each column.
    const rule = n.getChildren("TableDelimiter").map(slice).find((d) => /-/.test(d)) ?? "";
    const align = rule
      .split("|")
      .map((c) => c.trim())
      .filter((c) => c !== "")
      .map((c) => (/^:-+:$/.test(c) ? "center" : /-:$/.test(c) ? "right" : /^:/.test(c) ? "left" : ""));
    const row = (r: SyntaxNode, tag: "th" | "td") =>
      "<tr>" +
      r.getChildren("TableCell")
        .map((c, i) => `<${tag}${align[i] ? ` style="text-align:${align[i]}"` : ""}>${inline(c).trim()}</${tag}>`)
        .join("") +
      "</tr>\n";
    const body = n.getChildren("TableRow").map((r) => row(r, "td")).join("");
    return `<table>\n<thead>${header ? row(header, "th") : ""}</thead>\n<tbody>\n${body}</tbody>\n</table>\n`;
  }

  function block(n: SyntaxNode): string {
    const heading = /^(?:ATX|Setext)Heading([1-6])$/.exec(n.name);
    if (heading) return `<h${heading[1]}>${inline(n).trim()}</h${heading[1]}>\n`;
    switch (n.name) {
      case "Paragraph": return `<p>${inline(n).trim()}</p>\n`;
      case "Task": return `<p>${inline(n).trim()}</p>\n`;
      case "Blockquote": return `<blockquote>\n${blocks(n)}</blockquote>\n`;
      case "BulletList": return `<ul>\n${children(n).map(listItem).join("")}</ul>\n`;
      case "OrderedList": {
        const first = n.getChild("ListItem")?.getChild("ListMark");
        const start = first ? parseInt(slice(first), 10) : 1;
        return `<ol${start > 1 ? ` start="${start}"` : ""}>\n${children(n).map(listItem).join("")}</ol>\n`;
      }
      case "FencedCode": {
        const info = n.getChild("CodeInfo");
        const lang = info ? slice(info).trim().split(/\s+/)[0] : "";
        const code = children(n).filter((c) => c.name === "CodeText").map(slice).join("\n");
        return `<pre><code${/^[\w+#.-]+$/.test(lang) ? ` class="language-${lang}"` : ""}>${escapeHtml(code)}</code></pre>\n`;
      }
      case "CodeBlock":
        return `<pre><code>${escapeHtml(children(n).filter((c) => c.name === "CodeText").map(slice).join("\n"))}</code></pre>\n`;
      case "HorizontalRule": return "<hr>\n";
      case "Table": return table(n);
      case "LinkReference": return "";
      case "HTMLBlock":
      case "CommentBlock":
      case "ProcessingInstructionBlock":
        return `<pre class="raw">${escapeHtml(slice(n))}</pre>\n`;
      default:
        // Containers the parser adds (and unknown blocks): show what is inside.
        return n.firstChild ? blocks(n) : "";
    }
  }

  return blocks(tree.topNode);
}
