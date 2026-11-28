// Cases from the Mac's --selftest (SelfTest.swift, "Diagram menu (MermaidEdit)" onwards).
import { describe, expect, it } from "vitest";
import * as M from "../src/mermaid-edit";
import { diagramFileMarkdown, hasDiagram, hexColor, isDark } from "../src/diagrams";

const flow = "flowchart LR\n  A --> B";
const hand = M.settingConfig(flow, "look", "handDrawn");
const seq = "sequenceDiagram\n  participant A as Alice\n  A->>B: hi";
const blocks = 'flowchart LR\n  A["Start"] --> B(Go)\n  B --> C';
const slice = (s: string, r: M.Span | null) => (r ? s.slice(r.from, r.to) : null);

describe("front matter", () => {
  it("adds, reads, joins, replaces and removes settings", () => {
    expect(hand).toBe("---\nconfig:\n  look: handDrawn\n---\nflowchart LR\n  A --> B");
    expect(M.configValue(hand, "look")).toBe("handDrawn");
    expect(M.configValue(flow, "look")).toBeNull();
    expect(M.settingConfig(hand, "layout", "elk")).toBe("---\nconfig:\n  look: handDrawn\n  layout: elk\n---\nflowchart LR\n  A --> B");
    expect(M.settingConfig(hand, "look", "classic")).toBe("---\nconfig:\n  look: classic\n---\nflowchart LR\n  A --> B");
    expect(M.settingConfig(hand, "look", null)).toBe(flow);
    expect(M.settingConfig(flow, "look", null)).toBe(flow);
  });
  it("keeps the title", () => {
    const titled = "---\ntitle: Net\n---\ngraph TD\n  A --> B";
    const themed = M.settingConfig(titled, "theme", "forest");
    expect(themed).toBe("---\ntitle: Net\nconfig:\n  theme: forest\n---\ngraph TD\n  A --> B");
    expect(M.settingConfig(themed, "theme", null)).toBe(titled);
  });
});

describe("direction", () => {
  it("reads and sets a flowchart's direction", () => {
    expect(M.direction("graph TD\n  A --> B")).toBe("TB");
    expect(M.direction(hand)).toBe("LR");
    expect(M.direction("flowchart\n  A --> B")).toBe("TB");
    expect(M.direction("sequenceDiagram\n  A->>B: hi")).toBeNull();
    expect(M.settingDirection("graph TD\n  A --> B", "LR")).toBe("graph LR\n  A --> B");
    expect(M.settingDirection("flowchart\n  A", "RL")).toBe("flowchart RL\n  A");
    expect(M.settingDirection(hand, "BT")).toBe("---\nconfig:\n  look: handDrawn\n---\nflowchart BT\n  A --> B");
    expect(M.settingDirection("sequenceDiagram", "LR")).toBeNull();
  });
});

describe("which diagram", () => {
  const doc = "intro\n```mermaid\ngraph LR\n  A --> B\n```\nafter";
  const at = (cursor: number, kind: "markdown" | "mermaid" = "markdown") => slice(doc, M.diagramRange(doc, cursor, kind));
  it("finds the block around the cursor", () => {
    expect(at(20)).toBe("graph LR\n  A --> B");
    expect(at(8)).toBe("graph LR\n  A --> B");
    expect(at(2)).toBeNull();
    expect(at(doc.length)).toBeNull();
    expect(at(0, "mermaid")).toBe(doc);
  });
  it("handles unclosed and other blocks", () => {
    const unclosed = "x\n```mermaid\ngraph LR";
    expect(slice(unclosed, M.diagramRange(unclosed, unclosed.length, "markdown"))).toBe("graph LR");
    expect(M.diagramRange("```python\nx = 1\n```", 12, "markdown")).toBeNull();
    expect(M.diagramRange(doc, 20, "fountain")).toBeNull();
  });
  it("handles Windows line endings", () => {
    const crlf = "a\r\n```mermaid\r\ngraph LR\r\n  A\r\n```\r\n";
    expect(slice(crlf, M.diagramRange(crlf, 16, "markdown"))).toBe("graph LR\r\n  A");
  });
});

describe("from the picture", () => {
  it("finds lines", () => {
    expect(slice(flow, M.nodeLineSpan(flow, "B", ""))).toBe("  A --> B");
    expect(slice(seq, M.nodeLineSpan(seq, "", "Alice"))).toBe("  participant A as Alice");
    expect(M.nodeLineSpan(hand, "look", "")).toBeNull();
    expect(slice(flow, M.lineSpan(flow, 2))).toBe("  A --> B");
    expect(M.lineSpan(flow, 3)).toBeNull();
  });
});

describe("templates and the diagram list", () => {
  it("has ten templates", () => {
    expect(M.templates.length).toBe(10);
    expect(M.insertion(M.templates[0], "markdown").startsWith("```mermaid\nflowchart LR\n")).toBe(true);
    expect(M.insertion(M.templates[0], "mermaid").startsWith("flowchart LR\n")).toBe(true);
  });
  it("lists the diagrams of a document", () => {
    const several = "# A\n```mermaid\n---\ntitle: Net\n---\nflowchart LR\n  A --> B\n```\ntext\n```mermaid\nsequenceDiagram\n  A->>B: hi\n```\n";
    const listed = M.diagrams(several, "markdown");
    expect(listed.map((d) => d.title).join("|")).toBe("Net · flowchart LR|sequenceDiagram");
    expect(listed.map((d) => d.line).join(",")).toBe("3,11");
    expect(slice(several, listed[1].body)).toBe("sequenceDiagram\n  A->>B: hi");
    expect(M.diagrams("graph TD\n  A", "mermaid")[0].title).toBe("graph TD");
    expect(M.diagrams("\n", "mermaid").length).toBe(0);
    expect(M.summary(M.templates[6].source)).toBe("Plan · gantt");
  });
});

describe("block, arrow, group", () => {
  const added = (e: M.Element, source: string, line: number) => {
    const r = M.inserting(e, source, line);
    return r ? `${r.source} <${r.source.slice(r.select.from, r.select.to)}>` : null;
  };
  it("reads ids", () => {
    expect(M.diagramType(hand)).toBe("flowchart");
    expect(M.nodeIDs(M.templates[0].source).join(",")).toBe("start,step,check,done");
    expect(M.nodeIDs(M.templates[1].source).join(",")).toBe("client,app,server,api,db");
    expect(M.participants(seq).join(",")).toBe("A,B");
  });
  it("adds to flowcharts", () => {
    expect(added("block", flow, 1)).toBe('flowchart LR\n  A --> B\n  n1["Block"] <Block>');
    expect(added("arrow", flow, 1)).toBe('flowchart LR\n  A --> B\n  A --> n1["Next"] <Next>');
    expect(added("arrow", flow, 0)).toBe('flowchart LR\n    B --> n1["Next"]\n  A --> B <Next>');
    expect(added("group", flow, 1)).toBe('flowchart LR\n  A --> B\n  subgraph g1["Group"]\n      \n  end <Group>');
    expect(added("arrow", "flowchart LR", 0)).toBe('flowchart LR\n    n1["Start"] --> n2["Next"] <Next>');
  });
  it("adds to sequence diagrams", () => {
    expect(added("arrow", seq, 2)).toBe(seq + "\n  A->>B: Message <Message>");
    expect(added("block", seq, 0)).toBe("sequenceDiagram\n    participant P1 as Name\n  participant A as Alice\n  A->>B: hi <Name>");
    expect(added("group", seq, 2)).toBe(seq + "\n  loop Every minute\n      \n  end <Every minute>");
  });
  it("knows which kinds it can add to", () => {
    expect(added("block", "classDiagram\n  class A", 1)).toBeNull();
    expect(M.canInsertElements(flow)).toBe(true);
  });
});

describe("renaming", () => {
  it("renames labels", () => {
    expect(M.renaming('flowchart LR\n  A["Old"] --> B', "A", "New")).toBe('flowchart LR\n  A["New"] --> B');
    expect(M.renaming("graph TD\n  A(Hi) --> B", "A", "New")).toBe('graph TD\n  A("New") --> B');
    expect(M.renaming(flow, "B", "New")).toBe('flowchart LR\n  A --> B["New"]');
    expect(M.renaming("flowchart LR\n  A --> B\n  B{Ask}", "B", "New")).toBe('flowchart LR\n  A --> B\n  B{"New"}');
    expect(M.renaming("flowchart TB\n  subgraph s1 [Old]\n  end", "s1", "New")).toBe('flowchart TB\n  subgraph s1 ["New"]\n  end');
    expect(M.renaming("flowchart LR\n  A[x]", "A", 'Say "hi"')).toBe('flowchart LR\n  A["Say #quot;hi#quot;"]');
    expect(M.renaming('flowchart LR\n  X["A note"] --> A', "A", "New")).toBe('flowchart LR\n  X["A note"] --> A["New"]');
    expect(M.renaming(flow, "Z", "New")).toBeNull();
  });
  it("works with Cyrillic labels", () => {
    expect(M.renaming("flowchart LR\n  A[Роутер] --> B", "A", "Свитч")).toBe('flowchart LR\n  A["Свитч"] --> B');
  });
});

describe("mouse editing and properties", () => {
  const title = (i: number | null) => (i === null ? null : M.shapes[i].title);
  it("reads and sets shapes", () => {
    expect(title(M.shape(blocks, "A"))).toBe("Rectangle");
    expect(title(M.shape(blocks, "B"))).toBe("Rounded");
    expect(title(M.shape(blocks, "C"))).toBe("Rectangle");
    expect(M.shape(blocks, "Z")).toBeNull();
    expect(M.settingShape(blocks, "A", 6)).toBe('flowchart LR\n  A{"Start"} --> B(Go)\n  B --> C');
    expect(M.settingShape(blocks, "B", 4)).toBe('flowchart LR\n  A["Start"] --> B[(Go)]\n  B --> C');
    expect(M.settingShape(blocks, "C", 5)).toBe('flowchart LR\n  A["Start"] --> B(Go)\n  B --> C(("C"))');
  });
  it("reads and sets colours", () => {
    const blue = M.settingColor(blocks, "A", 0);
    expect(blue).toBe(blocks + "\n  style A fill:#dbeafe,stroke:#2563eb,color:#1e3a8a");
    expect(M.color(blue, "A")).toBe(0);
    expect(M.settingColor(blue, "A", 3)).toBe(blocks + "\n  style A fill:#fee2e2,stroke:#dc2626,color:#7f1d1d");
    expect(M.settingColor(blue, "A", null)).toBe(blocks);
    expect(M.color(blocks + "\n  style A fill:#fff", "A")).toBeNull();
    expect(M.hasStyle(blue, "A")).toBe(true);
    expect(M.block(blue, 3)).toBe("A");
  });
  it("connects, adds, duplicates and deletes", () => {
    expect(M.connecting(blocks, "C", "A")).toBe(blocks + "\n  C --> A");
    expect(M.connecting(blocks, "A", "A")).toBeNull();
    const next = M.addingNext(blocks, "B")!;
    expect(`${next.source} <${next.source.slice(next.select.from, next.select.to)}>`).toBe(
      'flowchart LR\n  A["Start"] --> B(Go)\n  B --> n1["Next"]\n  B --> C <Next>',
    );
    const dup = M.duplicating(blocks, "A")!;
    expect(`${dup.source} ${dup.id}`).toBe('flowchart LR\n  A["Start"] --> B(Go)\n  n1["Start"]\n  B --> C n1');
    expect(M.duplicating(blocks, "C")!.source).toBe('flowchart LR\n  A["Start"] --> B(Go)\n  B --> C\n  n1["C"]');
    expect(M.deleting(blocks + "\n  style B fill:#fff", "B")).toBe('flowchart LR\n  A["Start"]');
    expect(M.deleting('flowchart TB\n  subgraph s1["G"]\n    A\n  end', "s1")).toBeNull();
    expect(M.deleting(blocks, "Z")).toBeNull();
  });
  it("reads and sets arrows", () => {
    const title = (i: number | null) => (i === null ? null : M.arrows[i].title);
    expect(title(M.arrow(blocks, 1))).toBe("Arrow  -->");
    expect(M.arrow(blocks, 0)).toBeNull();
    expect(M.settingArrow(blocks, 1, 1)).toBe('flowchart LR\n  A["Start"] -.-> B(Go)\n  B --> C');
    const worded = "flowchart LR\n  A -- yes --> B";
    expect(title(M.arrow(worded, 1))).toBe("Arrow  -->");
    expect(M.settingArrow(worded, 1, 2)).toBe("flowchart LR\n  A ==>|yes| B");
    expect(title(M.arrow("graph TD\n  A -.-> B", 1))).toBe("Dotted  -.->");
    expect(title(M.arrow("graph TD\n  A --- B", 1))).toBe("Line  ---");
    expect(title(M.arrow("graph TD\n  A <--> B", 1))).toBe("Both Ways  <-->");
    expect(M.block(blocks, 2)).toBe("B");
  });
});

describe("completion", () => {
  it("offers kinds, ids, words and config words", () => {
    expect(M.completions("fl", "fl", "fl", 0).join(",")).toBe("flowchart");
    expect(M.completions("st", "  st", "flowchart LR\n  start --> stop\n  st", 2).join(",")).toBe("start,stop,style");
    expect(M.completions("pa", "  pa", seq + "\n  pa", 3).join(",")).toBe("participant,par");
    expect(M.completions("lo", "  lo", "---\nconfig:\n  lo\n---\nflowchart LR", 2).join(",")).toBe("look");
  });
});

describe("preview helpers", () => {
  it("wraps a diagram file in one block", () => {
    expect(diagramFileMarkdown("graph TD\n  A\n")).toBe("```mermaid\ngraph TD\n  A\n```\n");
    expect(diagramFileMarkdown("graph TD\n  A[```]")).toBe("````mermaid\ngraph TD\n  A[```]\n````\n");
  });
  it("finds diagrams and reads colours", () => {
    expect(hasDiagram("x\n```mermaid\ngraph TD")).toBe(true);
    expect(hasDiagram("```js\nx")).toBe(false);
    expect(hexColor("rgb(255, 0, 16)")).toBe("#ff0010");
    expect(hexColor("#ABC")).toBe("#aabbcc");
    expect(isDark("#1e1e1e")).toBe(true);
    expect(isDark("#fdf6e3")).toBe(false);
  });
});
