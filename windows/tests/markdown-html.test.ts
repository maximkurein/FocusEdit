// The preview's Markdown renderer.

import { describe, expect, it } from "vitest";
import { copyableFence, renderMarkdown, safeHref } from "../src/markdown-html";

const html = (md: string) => renderMarkdown(md).trim();

describe("Markdown preview", () => {
  it("renders headings and paragraphs", () => {
    expect(html("# Title\n\nbody text")).toBe("<h1>Title</h1>\n<p>body text</p>");
    expect(html("Setext\n======")).toBe("<h1>Setext</h1>");
  });

  it("renders bold, italic, strikethrough and code", () => {
    expect(html("**b** *i* ~~s~~ `c<d>`")).toBe("<p><strong>b</strong> <em>i</em> <del>s</del> <code>c&lt;d&gt;</code></p>");
  });

  it("shows raw HTML as text instead of running it", () => {
    expect(html("<script>alert(1)</script>")).not.toContain("<script>");
    expect(html("a <b>x</b> b")).toContain("&lt;b&gt;x&lt;/b&gt;");
  });

  it("links only to web addresses", () => {
    expect(html("[x](https://example.com/a?b=1&c=2)")).toBe('<p><a href="https://example.com/a?b=1&amp;c=2">x</a></p>');
    expect(html("[x](javascript:alert(1))")).toBe("<p>x</p>");
    expect(html("[x](file:///C:/secret.txt)")).toBe("<p>x</p>");
    expect(safeHref("https://a.b")).toBe("https://a.b");
    expect(safeHref("ftp://a.b")).toBeNull();
  });

  it("resolves reference links and bare URLs", () => {
    expect(html("[see][r]\n\n[r]: https://ref.example.com")).toContain('<a href="https://ref.example.com">see</a>');
    expect(html("go to https://auto.example.com now")).toContain('<a href="https://auto.example.com">');
  });

  it("renders lists, numbered starts and tasks", () => {
    expect(html("- a\n- b")).toContain("<ul>");
    expect(html("3. x\n4. y")).toContain('<ol start="3">');
    const tasks = html("- [x] done\n- [ ] todo");
    expect(tasks).toContain('<input type="checkbox" disabled checked> done');
    expect(tasks).toContain('<input type="checkbox" disabled> todo');
  });

  it("renders quotes, rules and code blocks", () => {
    expect(html("> quoted")).toContain("<blockquote>");
    expect(html("---")).toBe("<hr>");
    expect(html("```ts\nconst a = 1 < 2;\n```")).toBe('<pre><code class="language-ts">const a = 1 &lt; 2;</code></pre>');
    expect(html("    indented")).toBe("<pre><code>indented</code></pre>");
    expect(copyableFence("sftp hiplet-1967\n")).toBe("sftp hiplet-1967");
    expect(copyableFence("cmd", true)).toBeNull();
  });

  it("renders tables with alignment", () => {
    const t = html("| a | b |\n|:--|--:|\n| 1 | 2 |");
    expect(t).toContain('<th style="text-align:left">a</th><th style="text-align:right">b</th>');
    expect(t).toContain(`<td style="text-align:left">1</td>`);
  });

  it("keeps hard breaks and replaces images with their alt text", () => {
    expect(html("one  \ntwo")).toContain("<br>");
    expect(html("![alt text](pic.png)")).toContain("alt text");
    expect(html("![alt text](pic.png)")).not.toContain("<img");
  });

  it("handles an empty document", () => expect(html("")).toBe(""));
});
