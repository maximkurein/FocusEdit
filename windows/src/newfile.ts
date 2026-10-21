// New file: what the three-step "New file…" dialog offers and builds.
// Step 1 picks the format, step 2 what to start from, step 3 the name and the folder.
// Pure functions only (no DOM, no files), so the rules are easy to test.

import { markdownToRtf } from "./rtf";

export type FileFormat = "txt" | "md" | "rtf";
export type TemplateId = "blank" | "note" | "todo" | "meeting";

export interface FormatInfo {
  id: FileFormat;
  extension: string;
  title: string;
  description: string;
}

export interface TemplateInfo {
  id: TemplateId;
  title: string;
  description: string;
}

export const FORMATS: FormatInfo[] = [
  { id: "txt", extension: ".txt", title: "Plain text", description: "Just words, no formatting. Opens in any program." },
  { id: "md", extension: ".md", title: "Markdown", description: "Headings, lists and links written with simple marks. Has a live preview." },
  { id: "rtf", extension: ".rtf", title: "Rich text", description: "Bold, italic and headings that Word, WordPad and TextEdit show formatted." },
];

export const TEMPLATES: TemplateInfo[] = [
  { id: "blank", title: "Blank", description: "An empty file." },
  { id: "note", title: "Note", description: "A title, today's date and room to write." },
  { id: "todo", title: "To-do list", description: "A short checklist to tick off." },
  { id: "meeting", title: "Meeting notes", description: "Date, people, agenda, decisions and next steps." },
];

export const formatInfo = (id: FileFormat): FormatInfo => FORMATS.find((f) => f.id === id) ?? FORMATS[0];

/** Today as 2026-10-21, in local time. */
export function isoDate(now: Date = new Date()): string {
  const two = (n: number) => String(n).padStart(2, "0");
  return `${now.getFullYear()}-${two(now.getMonth() + 1)}-${two(now.getDate())}`;
}

/** The name offered in step 3 for a template. */
export function defaultName(template: TemplateId, date: string): string {
  return { blank: "Untitled", note: `Note ${date}`, todo: `To-do ${date}`, meeting: `Meeting ${date}` }[template];
}

/** The characters Windows does not allow in a file name, and those no one wants. */
// eslint-disable-next-line no-control-regex
const FORBIDDEN = /[<>:"/\\|?*\u0000-\u001f]/g;
const RESERVED = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/i;
const KNOWN_EXTENSION = /\.(txt|md|markdown|rtf)$/i;

/** A name typed by the user, cleaned up for a file name (without the extension). */
export function cleanName(input: string): string {
  let name = input.replace(FORBIDDEN, " ").replace(/\s+/g, " ").trim();
  name = name.replace(KNOWN_EXTENSION, "").replace(/[. ]+$/, "").trim();
  if (name.length > 100) name = name.slice(0, 100).trim();
  if (name === "") return "Untitled";
  return RESERVED.test(name) ? `_${name}` : name;
}

/** The file name for what was typed and the chosen format: "notes" + md → "notes.md". */
export function fileName(input: string, format: FileFormat): string {
  return cleanName(input) + formatInfo(format).extension;
}

/** `name` if free, else "name (2).ext", "name (3).ext"… `exists` tells which names are taken. */
export async function freeName(name: string, exists: (candidate: string) => Promise<boolean>): Promise<string> {
  if (!(await exists(name))) return name;
  const dot = name.lastIndexOf(".");
  const stem = dot > 0 ? name.slice(0, dot) : name;
  const extension = dot > 0 ? name.slice(dot) : "";
  for (let n = 2; n < 1000; n++) {
    const candidate = `${stem} (${n})${extension}`;
    if (!(await exists(candidate))) return candidate;
  }
  return `${stem} (${Date.now()})${extension}`;
}

// ------------------------------------------------------------------ contents

type Block = { heading: string } | { text: string } | { list: string[] } | { todo: string[] };

function blocks(template: TemplateId, title: string, date: string): Block[] {
  switch (template) {
    case "blank":
      return [];
    case "note":
      return [{ heading: title }, { text: date }, { text: "" }];
    case "todo":
      return [{ heading: title }, { todo: ["First thing", "Second thing", "Third thing"] }];
    case "meeting":
      return [
        { heading: title },
        { text: `Date: ${date}` },
        { text: "People: " },
        { heading: "Agenda" },
        { list: ["", ""] },
        { heading: "Decisions" },
        { list: [""] },
        { heading: "Next steps" },
        { todo: ["", ""] },
      ];
  }
}

/** The text a new file starts with, as the editor shows it: Markdown for md and rtf, plain text for txt. */
export function startingText(template: TemplateId, format: FileFormat, title: string, date: string): string {
  const plain = format === "txt";
  const out: string[] = [];
  for (const block of blocks(template, cleanName(title), date)) {
    if ("heading" in block) out.push(plain ? `${block.heading.toUpperCase()}\n` : `${out.length === 0 ? "#" : "##"} ${block.heading}\n`);
    else if ("text" in block) out.push(block.text);
    else if ("list" in block) out.push(block.list.map((item) => `- ${item}`).join("\n") + "\n");
    else out.push(block.todo.map((item) => (plain ? `[ ] ${item}` : `- [ ] ${item}`)).join("\n") + "\n");
  }
  const text = out.join("\n").replace(/\n{3,}/g, "\n\n").replace(/^\n+/, "").replace(/\n+$/, "");
  return text === "" ? "" : `${text}\n`;
}

/** What goes into the file on disk: the text itself, or RTF made from the Markdown. */
export function fileContents(format: FileFormat, text: string): string {
  return format === "rtf" ? markdownToRtf(text) : text;
}

/** The three steps, for the "Step 2 of 3" line. */
export const STEP_TITLES = ["Format", "Start from", "Name and place"] as const;

/** Joins a folder and a file name with the folder's own separator. */
export function joinPath(folder: string, name: string): string {
  const separator = folder.includes("\\") && !folder.includes("/") ? "\\" : "/";
  return folder.endsWith("/") || folder.endsWith("\\") ? folder + name : folder + separator + name;
}
