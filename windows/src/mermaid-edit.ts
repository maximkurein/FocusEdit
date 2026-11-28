// Text edits behind the Diagram commands, on Mermaid source: the port of the Mac's
// MermaidEdit.swift. Pure functions on strings, tested in tests/mermaid-edit.test.ts
// (the same cases as the Mac's --selftest).
//
// Settings that change how a diagram looks (hand-drawn, ELK layout, theme) go in the
// diagram's own front matter, the way Mermaid documents them, so the file keeps them
// and other Mermaid viewers (GitHub, mermaid.live) show the same thing:
//
//     ---
//     config:
//       look: handDrawn
//     ---
//     flowchart LR
//
// Offsets are JavaScript string indices (UTF-16), like NSString on the Mac.

import type { DocKind } from "./completion";

export interface Span {
  from: number;
  to: number;
}

// ---------------------------------------------------------------- templates

export interface Template {
  title: string;
  source: string;
}

const t = (lines: string[]) => lines.join("\n");

export const templates: Template[] = [
  {
    title: "Flowchart",
    source: t([
      "flowchart LR",
      '    start(["Start"]) --> step["Step"]',
      '    step --> check{"OK?"}',
      '    check -- "yes" --> done[("Done")]',
      '    check -. "no" .-> step',
    ]),
  },
  {
    title: "Flowchart with Groups",
    source: t([
      "flowchart TB",
      '    subgraph client["Client"]',
      '        app["App"]',
      "    end",
      '    subgraph server["Server"]',
      '        api["API"] --> db[("Database")]',
      "    end",
      '    app -->|"HTTPS"| api',
    ]),
  },
  {
    title: "Sequence",
    source: t([
      "sequenceDiagram",
      "    participant U as User",
      "    participant A as App",
      "    participant S as Server",
      "    U->>A: Click",
      "    A->>S: Request",
      "    S-->>A: Response",
      "    A-->>U: Result",
    ]),
  },
  {
    title: "Class",
    source: t([
      "classDiagram",
      "    class Document {",
      "        +String text",
      "        +save()",
      "    }",
      "    class Editor {",
      "        +open(Document)",
      "    }",
      "    Editor --> Document",
    ]),
  },
  {
    title: "State",
    source: t([
      "stateDiagram-v2",
      "    [*] --> Draft",
      "    Draft --> Review",
      "    Review --> Draft: changes",
      "    Review --> Published",
      "    Published --> [*]",
    ]),
  },
  {
    title: "Entity Relationship",
    source: t([
      "erDiagram",
      "    USER ||--o{ ORDER : places",
      "    ORDER ||--|{ ITEM : contains",
      "    USER {",
      "        int id",
      "        string name",
      "    }",
    ]),
  },
  {
    title: "Gantt",
    source: t([
      "gantt",
      "    title Plan",
      "    dateFormat YYYY-MM-DD",
      "    section Work",
      "    Design   :a1, 2026-12-01, 7d",
      "    Build    :a2, after a1, 14d",
      "    Release  :milestone, after a2, 0d",
    ]),
  },
  {
    title: "Mindmap",
    source: t(["mindmap", "  root((Idea))", "    Goals", "      First", "      Second", "    Questions", "    People"]),
  },
  {
    title: "Timeline",
    source: t(["timeline", "    title Project", "    2026 : Start", "         : First version", "    2027 : Release"]),
  },
  {
    title: "Architecture",
    source: t([
      "architecture-beta",
      "    group cloud(cloud)[Cloud]",
      "    service web(internet)[Web] in cloud",
      "    service api(server)[API] in cloud",
      "    service db(database)[Database] in cloud",
      "    web:R --> L:api",
      "    api:R --> L:db",
    ]),
  },
];

/** What the Diagram commands insert: the bare source in a diagram file, a fenced block in Markdown. */
export function insertion(template: Template, kind: DocKind): string {
  return kind === "mermaid" ? template.source + "\n" : "```mermaid\n" + template.source + "\n```\n";
}

// ---------------------------------------------------------------- helpers

const W = "[\\p{L}\\p{N}_]"; // \w as the Mac's regular expressions read it (Unicode)
const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const trimWs = (s: string) => s.replace(/^[ \t]+|[ \t]+$/g, "");
const leadOf = (s: string) => /^[ \t]*/.exec(s)![0];
const splitLines = (s: string) => s.split("\n");

/** Each line of `text` with its start, end (before the newline) and next line's start. */
function lineSpans(text: string): { start: number; end: number; next: number; text: string }[] {
  const out: { start: number; end: number; next: number; text: string }[] = [];
  let at = 0;
  while (at < text.length) {
    const nl = text.indexOf("\n", at);
    const next = nl < 0 ? text.length : nl + 1;
    let end = nl < 0 ? text.length : nl;
    if (end > at && text[end - 1] === "\r") end -= 1;
    out.push({ start: at, end, next, text: text.slice(at, end) });
    at = next;
  }
  return out;
}

const FENCE = /^ {0,3}(`{3,}|~{3,})\s*([^\s`]*)/;

/** The ```mermaid blocks of a Markdown text: body span and the 1-based line of the body. */
function mermaidBlocks(text: string): { open: number; body: Span; line: number; closeEnd: number }[] {
  const found: { open: number; body: Span; line: number; closeEnd: number }[] = [];
  let open: { marker: string; mermaid: boolean; lineStart: number; bodyStart: number; line: number } | null = null;
  lineSpans(text).forEach((l, index) => {
    const m = FENCE.exec(l.text);
    if (!m) return;
    const marker = m[1];
    if (open) {
      if (marker[0] === open.marker[0] && marker.length >= open.marker.length && trimWs(l.text) === marker) {
        if (open.mermaid) {
          let end = l.start;
          if (end > open.bodyStart && text[end - 1] === "\n") end -= 1;
          if (end > open.bodyStart && text[end - 1] === "\r") end -= 1;
          found.push({ open: open.lineStart, body: { from: open.bodyStart, to: Math.max(open.bodyStart, end) }, line: open.line, closeEnd: l.next });
        }
        open = null;
      }
    } else {
      open = { marker, mermaid: m[2].toLowerCase() === "mermaid", lineStart: l.start, bodyStart: l.next, line: index + 2 };
    }
  });
  const o = open as { mermaid: boolean; lineStart: number; bodyStart: number; line: number } | null;
  if (o && o.mermaid) found.push({ open: o.lineStart, body: { from: o.bodyStart, to: text.length }, line: o.line, closeEnd: text.length });
  return found;
}

// ---------------------------------------------------------------- which diagram

/** The source of the diagram the cursor is in: the whole text of a diagram file, or the
 *  inside of the ```mermaid block around the cursor (its fence lines included in the hit
 *  area) in Markdown. null when the cursor is not in a diagram. */
export function diagramRange(text: string, cursor: number, kind: DocKind): Span | null {
  if (kind === "mermaid") return { from: 0, to: text.length };
  if (kind !== "markdown" && kind !== "plain") return null;
  for (const b of mermaidBlocks(text)) {
    if (cursor >= b.open && cursor <= b.closeEnd) return b.body;
  }
  return null;
}

// ---------------------------------------------------------------- front matter

/** Where the front matter block ends (index after the closing `---`), or null. */
function frontMatter(lines: string[]): number | null {
  if (trimWs(lines[0] ?? "") !== "---") return null;
  for (let i = 1; i < lines.length; i++) if (trimWs(lines[i]) === "---") return i + 1;
  return null;
}

/** `look`, `layout`, `theme`… under `config:` in the front matter. */
export function configValue(source: string, key: string): string | null {
  const lines = splitLines(source);
  const end = frontMatter(lines);
  if (end === null) return null;
  let inConfig = false;
  for (const line of lines.slice(1, end - 1)) {
    const indent = /^ */.exec(line)![0].length;
    const body = trimWs(line);
    if (indent === 0) {
      inConfig = body === "config:";
      continue;
    }
    if (inConfig && body.startsWith(key + ":")) {
      return trimWs(body.slice(key.length + 1)).replace(/^["']+|["']+$/g, "");
    }
  }
  return null;
}

/** Set (or with null remove) `config.key` in the front matter, adding or dropping the block as needed. */
export function settingConfig(source: string, key: string, value: string | null): string {
  const lines = splitLines(source);
  const entry = value === null ? null : `  ${key}: ${value}`;
  const end = frontMatter(lines);
  if (end === null) {
    if (entry === null) return source;
    return ["---", "config:", entry, "---", ...lines].join("\n");
  }
  let configLine: number | null = null;
  let lastConfigLine: number | null = null;
  let keyLine: number | null = null;
  let inConfig = false;
  for (let i = 1; i < end - 1; i++) {
    const line = lines[i];
    const indent = /^ */.exec(line)![0].length;
    const body = trimWs(line);
    if (body === "") continue;
    if (indent === 0) {
      inConfig = body === "config:";
      if (inConfig) configLine = lastConfigLine = i;
      continue;
    }
    if (inConfig) {
      lastConfigLine = i;
      if (indent === 2 && body.startsWith(key + ":")) keyLine = i;
    }
  }
  if (keyLine !== null) {
    if (entry !== null) lines[keyLine] = entry;
    else lines.splice(keyLine, 1);
  } else if (entry !== null) {
    if (lastConfigLine !== null) lines.splice(lastConfigLine + 1, 0, entry);
    else lines.splice(end - 1, 0, "config:", entry);
  } else {
    return source;
  }
  if (configLine !== null && configLine < lines.length && trimWs(lines[configLine]) === "config:") {
    const next = configLine + 1 < lines.length ? lines[configLine + 1] : "";
    if (!next.startsWith(" ")) lines.splice(configLine, 1);
  }
  if (frontMatter(lines) === 2) lines.splice(0, 2);
  return lines.join("\n");
}

// ---------------------------------------------------------------- direction

const HEADER = /^(\s*)(flowchart|graph)(?:[ \t]+(TB|TD|BT|RL|LR))?(?=\s|$)/;

function headerLine(lines: string[]): number | null {
  for (let i = frontMatter(lines) ?? 0; i < lines.length; i++) {
    const body = trimWs(lines[i]);
    if (body !== "" && !body.startsWith("%%")) return i;
  }
  return null;
}

/** TB, LR, BT or RL of a flowchart (TD reads as TB); null for other diagram kinds. */
export function direction(source: string): string | null {
  const lines = splitLines(source);
  const i = headerLine(lines);
  if (i === null) return null;
  const m = HEADER.exec(lines[i]);
  if (!m) return null;
  if (!m[3]) return "TB";
  return m[3] === "TD" ? "TB" : m[3];
}

/** The flowchart turned to `dir`; null when the diagram is not a flowchart. */
export function settingDirection(source: string, dir: string): string | null {
  const lines = splitLines(source);
  const i = headerLine(lines);
  if (i === null) return null;
  const m = HEADER.exec(lines[i]);
  if (!m) return null;
  lines[i] = m[1] + m[2] + " " + dir + lines[i].slice(m[0].length);
  return lines.join("\n");
}

// ---------------------------------------------------------------- from the picture

const idRe = (id: string, flags = "u") => new RegExp(`(?<![\\p{L}\\p{N}_-])${escapeRe(id)}(?![\\p{L}\\p{N}_-])`, flags);

/** Line `number` (1-based) of `source` as a span. */
export function lineSpan(source: string, number: number): Span | null {
  const lines = splitLines(source);
  if (number < 1 || number > lines.length) return null;
  let from = 0;
  for (let i = 0; i < number - 1; i++) from += lines[i].length + 1;
  return { from, to: from + lines[number - 1].length };
}

/** The line that defines a clicked block: the first line where its id stands as a word,
 *  else the first line with its label. */
export function nodeLineSpan(source: string, nodeID: string, label: string): Span | null {
  const candidates: RegExp[] = [];
  if (nodeID) candidates.push(idRe(nodeID));
  if (label) candidates.push(new RegExp(escapeRe(label), "u"));
  const lines = splitLines(source);
  const skip = frontMatter(lines) ?? 0;
  for (const re of candidates) {
    let from = 0;
    for (let i = 0; i < lines.length; i++) {
      if (i >= skip && re.test(lines[i])) return { from, to: from + lines[i].length };
      from += lines[i].length + 1;
    }
  }
  return null;
}

// ---------------------------------------------------------------- the diagrams of a document

export interface DiagramItem {
  title: string;
  body: Span;
  /** 1-based line of the diagram's first line. */
  line: number;
}

/** Every diagram: the whole text of a diagram file, or each ```mermaid block of a Markdown document. */
export function diagrams(text: string, kind: DocKind): DiagramItem[] {
  if (kind === "mermaid") {
    if (text.trim() === "") return [];
    return [{ title: summary(text), body: { from: 0, to: text.length }, line: 1 }];
  }
  if (kind !== "markdown" && kind !== "plain") return [];
  return mermaidBlocks(text).map((b) => ({ title: summary(text.slice(b.body.from, b.body.to)), body: b.body, line: b.line }));
}

/** "Network · flowchart LR": the diagram's title, if it has one, and its kind line. */
export function summary(source: string): string {
  const lines = splitLines(source.replace(/\r/g, ""));
  let title: string | null = null;
  const end = frontMatter(lines);
  if (end !== null) {
    for (const line of lines.slice(1, end - 1)) {
      if (line.startsWith("title:")) title = line.slice(6).replace(/^[\s"']+|[\s"']+$/g, "");
    }
  }
  const h = headerLine(lines);
  const head = h === null ? "" : trimWs(lines[h]);
  if (title === null && h !== null) {
    for (const line of lines.slice(h + 1)) {
      const body = trimWs(line);
      if (body.startsWith("title ")) {
        title = trimWs(body.slice(6));
        break;
      }
    }
  }
  const kind = head === "" ? "empty diagram" : head;
  return title ? `${title} · ${kind}` : kind;
}

// ---------------------------------------------------------------- inserting elements

export type Element = "block" | "arrow" | "group";

/** The diagram's kind word: `flowchart`, `sequenceDiagram`, `classDiagram`… */
export function diagramType(source: string): string | null {
  const lines = splitLines(source);
  const i = headerLine(lines);
  if (i === null) return null;
  return trimWs(lines[i]).split(/[ \t]/)[0] || null;
}

/** Can the Block / Arrow / Group buttons add to this kind of diagram? */
export function canInsertElements(source: string): boolean {
  return ["flowchart", "graph", "sequenceDiagram"].includes(diagramType(source) ?? "");
}

const FLOW_KEYWORDS = new Set(["subgraph", "end", "direction", "flowchart", "graph", "TB", "TD", "BT", "RL", "LR"]);
const FLOW_SKIP = /^\s*(?:%%|classDef\b|class\b|style\b|linkStyle\b|click\b|direction\b|accTitle|accDescr)/;
const FLOW_STRIP: [RegExp, string][] = [
  [/"[^"]*"/gu, " "], // quoted labels
  [/\|[^|]*\|/gu, " "], // |edge labels|
  [/(?:--|==|-\.)\s+[^>\n]*?\s+(?:-->|==>|\.->|---)/gu, " --> "], // -- text -->
  [new RegExp(`\\[[^\\]]*\\]|\\([^)]*\\)|\\{[^}]*\\}|(?<=${W})>[^\\]\\n]*\\]`, "gu"), " "], // shapes
  [new RegExp(`:::[\\p{L}\\p{N}_-]+`, "gu"), " "],
  [/@\{[^}]*\}/gu, " "],
];
const ID_WORD = new RegExp(`(?<![\\p{L}\\p{N}_-])[A-Za-z_]${W}*(?:-${W}+)*`, "gu");

/** Node ids of a flowchart in `line`, in order. */
function flowIDs(line: string): string[] {
  if (FLOW_SKIP.test(line)) return [];
  let text = line;
  for (const [re, by] of FLOW_STRIP) text = text.replace(re, by);
  return [...text.matchAll(ID_WORD)].map((m) => m[0]).filter((w) => !FLOW_KEYWORDS.has(w));
}

/** Node ids of a flowchart, in order of first appearance. */
export function nodeIDs(source: string): string[] {
  const lines = splitLines(source);
  const header = headerLine(lines);
  if (header === null) return [];
  const ids: string[] = [];
  for (const line of lines.slice(header + 1)) for (const id of flowIDs(line)) if (!ids.includes(id)) ids.push(id);
  return ids;
}

const PARTICIPANT = /^\s*(?:participant|actor)\s+(\S+)/;
const MESSAGE = /^\s*([^\s:+-][^:]*?)\s*(?:->>|-->>|->|-->|-x|--x|-\)|--\))\s*[+-]?\s*([^:]+?)\s*:/;

function participantsIn(line: string): string[] {
  const p = PARTICIPANT.exec(line);
  if (p) return [p[1]];
  const m = MESSAGE.exec(line);
  return m ? [m[1], m[2]] : [];
}

/** Participants of a sequence diagram, in order of first appearance. */
export function participants(source: string): string[] {
  const list: string[] = [];
  for (const line of splitLines(source)) for (const p of participantsIn(line)) if (!list.includes(p)) list.push(p);
  return list;
}

function unique(prefix: string, taken: string[], source: string): string {
  let n = 1;
  while (taken.includes(prefix + n) || source.includes(prefix + n)) n++;
  return prefix + n;
}

/** The diagram with a new line after line `line` (0-based) and what to select in it
 *  (the placeholder text). null for diagram kinds the buttons don't know. */
export function inserting(element: Element, source: string, afterLine: number): { source: string; select: Span } | null {
  const lines = splitLines(source);
  const header = headerLine(lines);
  const type = diagramType(source);
  if (header === null || type === null) return null;
  const at = Math.min(Math.max(afterLine, header), lines.length - 1);
  const current = lines[at];
  const lead = leadOf(current);
  const body = trimWs(current);
  let indent = at === header ? lead + "    " : lead === "" ? "    " : lead;
  if (body.startsWith("subgraph ") || ["loop", "alt", "opt", "par", "rect", "critical", "box"].some((w) => body.startsWith(w + " "))) {
    indent = lead + "    ";
  }
  let newLines: string[];
  let placeholder: string;
  if (type === "flowchart" || type === "graph") {
    const ids = nodeIDs(source);
    if (element === "block") {
      const id = unique("n", ids, source);
      placeholder = "Block";
      newLines = [`${indent}${id}["${placeholder}"]`];
    } else if (element === "arrow") {
      const from = (at === header ? undefined : flowIDs(current)[0]) ?? ids[ids.length - 1];
      const to = unique("n", ids, source);
      placeholder = "Next";
      if (from) newLines = [`${indent}${from} --> ${to}["${placeholder}"]`];
      else {
        const start = unique("n", [...ids, to], source + to);
        newLines = [`${indent}${to}["Start"] --> ${start}["${placeholder}"]`];
      }
    } else {
      const id = unique("g", ids, source);
      placeholder = "Group";
      newLines = [`${indent}subgraph ${id}["${placeholder}"]`, `${indent}    `, `${indent}end`];
    }
  } else if (type === "sequenceDiagram") {
    const people = participants(source);
    if (element === "block") {
      const id = unique("P", people, source);
      placeholder = "Name";
      newLines = [`${indent}participant ${id} as ${placeholder}`];
    } else if (element === "arrow") {
      const here = at === header ? [] : participantsIn(current);
      const from = here[0] ?? people[0] ?? "A";
      const to = people.find((p) => p !== from) ?? (from === "B" ? "A" : "B");
      placeholder = "Message";
      newLines = [`${indent}${from}->>${to}: ${placeholder}`];
    } else {
      placeholder = "Every minute";
      newLines = [`${indent}loop ${placeholder}`, `${indent}    `, `${indent}end`];
    }
  } else {
    return null;
  }
  lines.splice(at + 1, 0, ...newLines);
  let start = 0;
  for (let i = 0; i <= at; i++) start += lines[i].length + 1;
  const offset = newLines[0].indexOf(placeholder);
  return { source: lines.join("\n"), select: { from: start + offset, to: start + offset + placeholder.length } };
}

// ---------------------------------------------------------------- renaming from the picture

const OPENERS = ["(((", "[[", "[(", "[/", "[\\", "((", "([", "{{", "[", "(", "{", ">"];

function outsideQuotes(line: string, at: number): boolean {
  let quotes = 0;
  for (let i = 0; i < at; i++) if (line[i] === '"') quotes++;
  return quotes % 2 === 0;
}

function idMatches(line: string, id: string): { index: number; end: number }[] {
  return [...line.matchAll(idRe(id, "gu"))]
    .filter((m) => outsideQuotes(line, m.index!))
    .map((m) => ({ index: m.index!, end: m.index! + m[0].length }));
}

/** After `subgraph id`, the label may follow a space. */
function afterId(line: string, index: number, end: number): number {
  let at = end;
  if (trimWs(line.slice(0, index)) === "subgraph") while (at < line.length && line[at] === " ") at++;
  return at;
}

/** The flowchart with block `id` labelled `text`: the label where the block is first given
 *  one is replaced, or one is added to its first mention. null if `id` is not there. */
export function renaming(source: string, id: string, text: string): string | null {
  if (!id) return null;
  const label = '"' + text.replace(/"/g, "#quot;") + '"';
  const lines = splitLines(source);
  const header = headerLine(lines);
  if (header === null) return null;
  let first: { line: number; end: number } | null = null;
  for (let i = header + 1; i < lines.length; i++) {
    const line = lines[i];
    if (FLOW_SKIP.test(line)) continue;
    for (const m of idMatches(line, id)) {
      first ??= { line: i, end: m.end };
      const at = afterId(line, m.index, m.end);
      const rest = line.slice(at);
      const opener = OPENERS.find((o) => rest.startsWith(o));
      if (!opener) continue;
      const contentStart = at + opener.length;
      let contentEnd: number | null = null;
      if (line[contentStart] === '"') {
        const close = line.indexOf('"', contentStart + 1);
        if (close >= 0) contentEnd = close + 1;
      } else {
        const rel = line.slice(contentStart).search(/[\])}]/);
        if (rel >= 0) contentEnd = contentStart + rel;
      }
      if (contentEnd === null) continue;
      lines[i] = line.slice(0, contentStart) + label + line.slice(contentEnd);
      return lines.join("\n");
    }
  }
  if (!first) return null;
  const line = lines[first.line];
  lines[first.line] = line.slice(0, first.end) + "[" + label + "]" + line.slice(first.end);
  return lines.join("\n");
}

// ---------------------------------------------------------------- blocks: shape, colour, arrows

export const shapes = [
  { title: "Rectangle", open: "[", close: "]" },
  { title: "Rounded", open: "(", close: ")" },
  { title: "Stadium", open: "([", close: "])" },
  { title: "Subroutine", open: "[[", close: "]]" },
  { title: "Database", open: "[(", close: ")]" },
  { title: "Circle", open: "((", close: "))" },
  { title: "Decision", open: "{", close: "}" },
  { title: "Hexagon", open: "{{", close: "}}" },
  { title: "Parallelogram", open: "[/", close: "/]" },
  { title: "Flag", open: ">", close: "]" },
] as const;

/** Index into `shapes`. */
export type Shape = number;
const CIRCLE = 5;
const PARALLELOGRAM = 8;

/** The shape an opener starts (the longest that fits). */
function shapeStarting(rest: string): Shape | null {
  if (rest.startsWith("(((")) return CIRCLE;
  const order = shapes.map((_, i) => i).sort((a, b) => shapes[b].open.length - shapes[a].open.length);
  return order.find((i) => rest.startsWith(shapes[i].open)) ?? null;
}

/** Where a block gets its shape and label: line, id span, the span from the id through the
 *  closing bracket, the label inside (with its quotes) and the shape. Spans are in the line. */
export interface Definition {
  line: number;
  id: Span;
  span: Span;
  label: Span;
  shape: Shape;
}

function blockLines(lines: string[]): [number, number] | null {
  const header = headerLine(lines);
  return header === null ? null : [header + 1, lines.length];
}

function shapeAfter(line: string, idEnd: number): { shape: Shape; label: Span; end: number } | null {
  const rest = line.slice(idEnd);
  const shape = shapeStarting(rest);
  if (shape === null) return null;
  const triple = shape === CIRCLE && rest.startsWith("(((");
  const open = triple ? "(((" : shapes[shape].open;
  const close = triple ? ")))" : shapes[shape].close;
  const start = idEnd + open.length;
  if (start > line.length) return null;
  if (line[start] === '"') {
    const q = line.indexOf('"', start + 1);
    if (q < 0) return null;
    const c = line.indexOf(close, q + 1);
    if (c < 0) return null;
    return { shape, label: { from: start, to: q + 1 }, end: c + close.length };
  }
  let c = line.indexOf(close, start);
  if (shape === PARALLELOGRAM && c < 0) c = line.indexOf("\\]", start);
  if (c < 0) return null;
  return { shape, label: { from: start, to: c }, end: c + close.length };
}

/** Where block `id` gets its shape and label; null if it never does (a bare `A --> B`). */
export function definition(source: string, id: string): Definition | null {
  const lines = splitLines(source);
  const range = blockLines(lines);
  if (!range || !id) return null;
  for (let i = range[0]; i < range[1]; i++) {
    const line = lines[i];
    if (FLOW_SKIP.test(line)) continue;
    for (const m of idMatches(line, id)) {
      const found = shapeAfter(line, afterId(line, m.index, m.end));
      if (!found) continue;
      return { line: i, id: { from: m.index, to: m.end }, span: { from: m.index, to: found.end }, label: found.label, shape: found.shape };
    }
  }
  return null;
}

function firstMention(lines: string[], id: string): { line: number; id: Span } | null {
  const range = blockLines(lines);
  if (!range || !id) return null;
  for (let i = range[0]; i < range[1]; i++) {
    if (FLOW_SKIP.test(lines[i])) continue;
    const m = idMatches(lines[i], id)[0];
    if (m) return { line: i, id: { from: m.index, to: m.end } };
  }
  return null;
}

/** The shape of block `id` (a bare id is a rectangle); null if it is not in the diagram. */
export function shape(source: string, id: string): Shape | null {
  const d = definition(source, id);
  if (d) return d.shape;
  return firstMention(splitLines(source), id) ? 0 : null;
}

/** Block `id` drawn as `shape`, its label kept (a bare id gets itself as the label). */
export function settingShape(source: string, id: string, to: Shape): string | null {
  const lines = splitLines(source);
  const s = shapes[to];
  const d = definition(source, id);
  if (d) {
    const line = lines[d.line];
    const text = line.slice(d.id.from, d.id.to) + s.open + line.slice(d.label.from, d.label.to) + s.close;
    lines[d.line] = line.slice(0, d.span.from) + text + line.slice(d.span.to);
    return lines.join("\n");
  }
  const m = firstMention(lines, id);
  if (!m) return null;
  const line = lines[m.line];
  lines[m.line] = line.slice(0, m.id.to) + s.open + '"' + id + '"' + s.close + line.slice(m.id.to);
  return lines.join("\n");
}

/** Fill colours for the Properties colour menu (light fills, readable text). */
export const colors = [
  { title: "Blue", style: "fill:#dbeafe,stroke:#2563eb,color:#1e3a8a" },
  { title: "Green", style: "fill:#dcfce7,stroke:#16a34a,color:#14532d" },
  { title: "Yellow", style: "fill:#fef9c3,stroke:#ca8a04,color:#713f12" },
  { title: "Red", style: "fill:#fee2e2,stroke:#dc2626,color:#7f1d1d" },
  { title: "Purple", style: "fill:#f3e8ff,stroke:#9333ea,color:#581c87" },
  { title: "Gray", style: "fill:#f3f4f6,stroke:#6b7280,color:#111827" },
] as const;

/** Index into `colors`. */
export type Color = number;

function styleParts(line: string): string[] {
  const body = trimWs(line);
  const parts: string[] = [];
  let rest = body;
  for (let k = 0; k < 2; k++) {
    const sp = rest.indexOf(" ");
    if (sp < 0) break;
    parts.push(rest.slice(0, sp));
    rest = rest.slice(sp + 1);
  }
  parts.push(rest);
  return parts.filter((p) => p !== "");
}

function styleLines(lines: string[], id: string): number[] {
  return lines.map((l, i) => [l, i] as const).filter(([l]) => {
    const p = styleParts(l);
    return p.length >= 2 && p[0] === "style" && p[1] === id;
  }).map(([, i]) => i);
}

/** The colour of block `id` from its `style` line: one of ours, or null (none or another). */
export function color(source: string, id: string): Color | null {
  const lines = splitLines(source);
  const all = styleLines(lines, id);
  if (all.length === 0) return null;
  const p = styleParts(lines[all[all.length - 1]]);
  if (p.length !== 3) return null;
  const i = colors.findIndex((c) => c.style === p[2]);
  return i < 0 ? null : i;
}

/** Does block `id` have a `style` line of any colour? */
export const hasStyle = (source: string, id: string) => styleLines(splitLines(source), id).length > 0;

/** `text` as a new last line of the diagram, indented like its first statement. */
function appendingLine(text: string, lines: string[]): string {
  const out = [...lines];
  let end = out.length;
  while (end > 0 && trimWs(out[end - 1]) === "") end--;
  const header = headerLine(out) ?? 0;
  const first = out.findIndex((l, i) => i > header && trimWs(l) !== "");
  let lead = first >= 0 ? leadOf(out[first]) : "    ";
  if (lead === "") lead = "    ";
  out.splice(end, 0, lead + text);
  return out.join("\n");
}

/** Block `id` filled with `color` (null removes its `style` lines). */
export function settingColor(source: string, id: string, to: Color | null): string {
  const lines = splitLines(source);
  const existing = styleLines(lines, id);
  if (to !== null && existing.length > 0) {
    const last = existing[existing.length - 1];
    lines[last] = leadOf(lines[last]) + `style ${id} ` + colors[to].style;
    for (const i of existing.slice(0, -1).reverse()) lines.splice(i, 1);
    return lines.join("\n");
  }
  for (const i of [...existing].reverse()) lines.splice(i, 1);
  if (to === null) return lines.join("\n");
  return appendingLine(`style ${id} ` + colors[to].style, lines);
}

/** Arrow A → B as a new last line. */
export function connecting(source: string, from: string, to: string): string | null {
  if (!from || !to || from === to) return null;
  return appendingLine(`${from} --> ${to}`, splitLines(source));
}

/** A new block after block `id`, joined to it by an arrow; with the placeholder to select. */
export function addingNext(source: string, id: string): { source: string; select: Span } | null {
  const lines = splitLines(source);
  const at = definition(source, id)?.line ?? firstMention(lines, id)?.line;
  if (at === undefined) return null;
  const fresh = unique("n", nodeIDs(source), source);
  let lead = leadOf(lines[at]);
  if (lead === "") lead = "    ";
  const line = lead + `${id} --> ${fresh}["Next"]`;
  lines.splice(at + 1, 0, line);
  let start = 0;
  for (let i = 0; i <= at; i++) start += lines[i].length + 1;
  const offset = start + line.indexOf("Next");
  return { source: lines.join("\n"), select: { from: offset, to: offset + 4 } };
}

/** A copy of block `id` (same shape and label) on the line after its definition. */
export function duplicating(source: string, id: string): { source: string; id: string } | null {
  const lines = splitLines(source);
  const fresh = unique("n", nodeIDs(source), source);
  const d = definition(source, id);
  if (d) {
    const line = lines[d.line];
    const lead = leadOf(line);
    lines.splice(d.line + 1, 0, (lead === "" ? "    " : lead) + fresh + line.slice(d.id.to, d.span.to));
    return { source: lines.join("\n"), id: fresh };
  }
  const m = firstMention(lines, id);
  if (!m) return null;
  let lead = leadOf(lines[m.line]);
  if (lead === "") lead = "    ";
  lines.splice(m.line + 1, 0, lead + fresh + `["${id}"]`);
  return { source: lines.join("\n"), id: fresh };
}

/** The diagram without block `id`: lines that only define or link it go; another block
 *  defined on such a line keeps its definition on a line of its own; its `style`, `class`
 *  and `click` lines go too. null for a group (subgraph) or an unknown id. */
export function deleting(source: string, id: string): string | null {
  const lines = splitLines(source);
  const range = blockLines(lines);
  if (!range || !firstMention(lines, id)) return null;
  const out = lines.slice(0, range[0]);
  for (let i = range[0]; i < range[1]; i++) {
    const line = lines[i];
    const words = trimWs(line).split(" ").filter((w) => w !== "");
    if (words.length >= 2 && ["style", "class", "click"].includes(words[0]) && words[1].split(",").includes(id)) continue;
    if (words[0] === "subgraph" && words.length >= 2 && words[1].startsWith(id) && flowIDs(line)[0] === id) return null;
    if (FLOW_SKIP.test(line)) {
      out.push(line);
      continue;
    }
    if (idMatches(line, id).length === 0) {
      out.push(line);
      continue;
    }
    const lead = leadOf(line);
    for (const other of flowIDs(line)) {
      if (other === id) continue;
      for (const m of idMatches(line, other)) {
        const found = shapeAfter(line, m.end);
        if (found) {
          out.push(lead + line.slice(m.index, found.end));
          break;
        }
      }
    }
  }
  return out.join("\n");
}

// ---------------------------------------------------------------- arrow kinds

export const arrows = [
  { title: "Arrow  -->", text: "-->" },
  { title: "Dotted  -.->", text: "-.->" },
  { title: "Thick  ==>", text: "==>" },
  { title: "Line  ---", text: "---" },
  { title: "Both Ways  <-->", text: "<-->" },
] as const;

/** Index into `arrows`. */
export type Arrow = number;
const ARROW = 0, DOTTED = 1, THICK = 2, LINE = 3, BOTH = 4;

const LABELLED_LINK = /(?<![<\-=.])(--|==|-\.)\s+([^>\n|]*?)\s+(-->|==>|\.->|---)/g;
const PLAIN_LINK = /<?(?:-\.+->|-\.+-|={2,}>|-{2,}>|-{3,}|={3,})/g;

function firstArrow(line: string): { arrow: Arrow; span: Span; label: string | null } | null {
  let best: { arrow: Arrow; span: Span; label: string | null } | null = null;
  const l = [...line.matchAll(LABELLED_LINK)].find((m) => outsideQuotes(line, m.index!));
  if (l) {
    const kind = l[1] === "==" ? THICK : l[1] === "-." ? DOTTED : ARROW;
    best = { arrow: kind, span: { from: l.index!, to: l.index! + l[0].length }, label: l[2] };
  }
  const p = [...line.matchAll(PLAIN_LINK)].find((m) => outsideQuotes(line, m.index!));
  if (p && (!best || p.index! < best.span.from)) {
    const s = p[0];
    const kind = s.startsWith("<") ? BOTH : s.includes(".") ? DOTTED : s.startsWith("=") ? THICK : s.endsWith(">") ? ARROW : LINE;
    best = { arrow: kind, span: { from: p.index!, to: p.index! + s.length }, label: null };
  }
  return best;
}

/** The arrow on line `line` (0-based) of a flowchart, if there is one. */
export function arrow(source: string, line: number): Arrow | null {
  const lines = splitLines(source);
  const range = blockLines(lines);
  if (!range || line < range[0] || line >= range[1] || FLOW_SKIP.test(lines[line])) return null;
  return firstArrow(lines[line])?.arrow ?? null;
}

/** The first arrow on line `line` turned into `kind` (a `-- text -->` label moves to `|text|`). */
export function settingArrow(source: string, line: number, kind: Arrow): string | null {
  const lines = splitLines(source);
  const range = blockLines(lines);
  if (!range || line < range[0] || line >= range[1] || FLOW_SKIP.test(lines[line])) return null;
  const found = firstArrow(lines[line]);
  if (!found) return null;
  const text = found.label !== null ? arrows[kind].text + "|" + found.label + "|" : arrows[kind].text;
  const l = lines[line];
  lines[line] = l.slice(0, found.span.from) + text + l.slice(found.span.to);
  return lines.join("\n");
}

/** The block a line is about: the first id on it (for Properties). */
export function block(source: string, line: number): string | null {
  const lines = splitLines(source);
  const range = blockLines(lines);
  if (!range || line < range[0] || line >= range[1]) return null;
  const body = trimWs(lines[line]);
  if (body.startsWith("style ") || body.startsWith("class ")) return body.split(" ").filter((w) => w)[1] ?? null;
  return flowIDs(lines[line])[0] ?? null;
}

// ---------------------------------------------------------------- completion

export const diagramKinds = [
  "flowchart", "graph", "sequenceDiagram", "classDiagram", "stateDiagram-v2", "erDiagram", "gantt",
  "mindmap", "timeline", "architecture-beta", "pie", "journey", "gitGraph", "quadrantChart",
  "xychart-beta", "block-beta", "kanban", "sankey-beta", "requirementDiagram",
];

const KEYWORDS: Record<string, string[]> = {
  flowchart: ["subgraph", "end", "direction", "style", "classDef", "class", "click", "linkStyle"],
  sequenceDiagram: ["participant", "actor", "loop", "alt", "else", "opt", "par", "and", "critical",
    "break", "rect", "end", "Note", "activate", "deactivate", "autonumber", "over"],
  classDiagram: ["class", "namespace", "note", "direction"],
  "stateDiagram-v2": ["state", "note", "direction", "end"],
  gantt: ["title", "dateFormat", "axisFormat", "section", "excludes", "todayMarker", "done", "active",
    "crit", "milestone", "after"],
  timeline: ["title", "section"],
  pie: ["title", "showData"],
  journey: ["title", "section"],
  "architecture-beta": ["group", "service", "junction", "cloud", "database", "server", "internet", "disk"],
};

const CONFIG_WORDS = ["config", "look", "layout", "theme", "title", "handDrawn", "classic",
  "elk", "dagre", "default", "neutral", "dark", "forest", "base"];

/** Words to offer for `prefix` while typing on line `line` (0-based) of a diagram: the kinds
 *  on its first line, config words in its front matter, else its block ids (or participants)
 *  and then Mermaid's words for its kind. */
export function completions(prefix: string, linePrefix: string, source: string, line: number): string[] {
  if (!prefix) return [];
  const lines = splitLines(source);
  const matching = (words: string[], caseSensitive: boolean) => {
    const p = caseSensitive ? prefix : prefix.toLowerCase();
    return words.filter((word) => {
      const w = caseSensitive ? word : word.toLowerCase();
      return w.startsWith(p) && w !== p;
    });
  };
  const end = frontMatter(lines);
  if (end !== null && line < end) return matching(CONFIG_WORDS, false);
  if (trimWs(lines[0] ?? "") === "---" && end === null) return matching(CONFIG_WORDS, false);
  const header = headerLine(lines);
  if (header === null || header === line) {
    return trimWs(linePrefix) === prefix ? matching(diagramKinds, false) : [];
  }
  let type = diagramType(source) ?? "";
  if (type === "graph") type = "flowchart";
  const names = type === "flowchart" ? nodeIDs(source) : type === "sequenceDiagram" ? participants(source) : [];
  const out: string[] = [];
  for (const w of [...matching(names, true), ...matching(KEYWORDS[type] ?? [], false)]) if (!out.includes(w)) out.push(w);
  return out;
}
