import { describe, expect, it } from "vitest";
import { htmlDocument, titleOf } from "../src/export";

describe("HTML export", () => {
  it("makes a complete page with the rendered document", () => {
    const page = htmlDocument("# Hello\n\nworld", "notes");
    expect(page).toMatch(/^<!doctype html>/);
    expect(page).toContain("<title>notes</title>");
    expect(page).toContain("<h1>Hello</h1>");
    expect(page).toContain("<p>world</p>");
    expect(page).toContain("</html>");
  });

  it("escapes the title and never lets raw HTML through", () => {
    const page = htmlDocument("<script>alert(1)</script>", "a <b> & c");
    expect(page).toContain("<title>a &lt;b&gt; &amp; c</title>");
    expect(page).not.toContain("<script>");
  });

  it("names the page after the file without its extension", () => {
    expect(titleOf("notes.md")).toBe("notes");
    expect(titleOf("a.b.txt")).toBe("a.b");
    expect(titleOf("README")).toBe("README");
  });
});
