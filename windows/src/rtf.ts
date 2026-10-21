// RTF ↔ Markdown, so .rtf files open as Markdown text and save back as RTF.
// The same idea as RTFMarkdown.swift on the Mac: bold, italic, strikethrough, headings (by
// font size), bullet and numbered lists, quotes, links and monospaced code survive;
// fonts, colours, underline, images and tables do not, and `lost` names what was there.

// ------------------------------------------------------------ Markdown → RTF

const HEADING_SIZE = [0, 48, 36, 30, 26, 26, 26]; // half-points; the body is 24 (12 pt)
const BODY_SIZE = 24;
const LIST_INDENT = 720;

/** Text as RTF: control characters escaped, everything outside ASCII as \uN?. */
function escapeRtf(text: string): string {
  let out = "";
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    const code = text.charCodeAt(i);
    if (c === "\\" || c === "{" || c === "}") out += `\\${c}`;
    else if (c === "\t") out += "\\tab ";
    else if (code > 126) out += `\\u${code > 32767 ? code - 65536 : code}?`;
    else out += c;
  }
  return out;
}

type InlineRule = { pattern: RegExp; render: (m: RegExpExecArray) => string };

const INLINE_RULES: InlineRule[] = [
  { pattern: /`([^`]+)`/, render: (m) => `{\\f1 ${escapeRtf(m[1])}}` },
  {
    pattern: /\[([^\]]+)\]\(([^)\s]+)\)/,
    render: (m) =>
      `{\\field{\\*\\fldinst{HYPERLINK "${m[2].replace(/["\\{}]/g, "")}"}}{\\fldrslt{\\ul ${inlineToRtf(m[1])}}}}`,
  },
  { pattern: /(\*\*|__)(?=\S)(.+?)(?<=\S)\1/, render: (m) => `{\\b ${inlineToRtf(m[2])}}` },
  { pattern: /~~(?=\S)(.+?)(?<=\S)~~/, render: (m) => `{\\strike ${inlineToRtf(m[1])}}` },
  { pattern: /\*(?=\S)(.+?)(?<=\S)\*/, render: (m) => `{\\i ${inlineToRtf(m[1])}}` },
  { pattern: /(?<![\p{L}\p{N}])_(?=\S)(.+?)(?<=\S)_(?![\p{L}\p{N}])/u, render: (m) => `{\\i ${inlineToRtf(m[1])}}` },
];

function inlineToRtf(text: string): string {
  let out = "";
  let rest = text;
  while (rest) {
    let best: { match: RegExpExecArray; rule: InlineRule } | null = null;
    for (const rule of INLINE_RULES) {
      const match = rule.pattern.exec(rest);
      if (match && (!best || match.index < best.match.index)) best = { match, rule };
    }
    if (!best) return out + escapeRtf(rest);
    out += escapeRtf(rest.slice(0, best.match.index)) + best.rule.render(best.match);
    rest = rest.slice(best.match.index + best.match[0].length);
  }
  return out;
}

export function markdownToRtf(markdown: string): string {
  const lines = markdown.replace(/\r\n?/g, "\n").split("\n");
  const body: string[] = [];
  let paragraph: string[] = [];
  let fence = false;

  const flush = () => {
    if (paragraph.length) body.push(`\\pard\\sa160 ${inlineToRtf(paragraph.join(" "))}\\par`);
    paragraph = [];
  };

  for (const line of lines) {
    if (/^\s*(```|~~~)/.test(line)) {
      flush();
      fence = !fence;
      continue;
    }
    if (fence) {
      body.push(`\\pard\\sa0 {\\f1 ${escapeRtf(line)}}\\par`);
      continue;
    }
    if (line.trim() === "") {
      flush();
      continue;
    }
    const heading = /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(line);
    const item = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(line);
    const quote = /^>\s?(.*)$/.exec(line);
    if (heading) {
      flush();
      const level = heading[1].length;
      body.push(`\\pard\\sb120\\sa120 {\\b\\fs${HEADING_SIZE[level]} ${inlineToRtf(heading[2])}}\\par`);
    } else if (item) {
      flush();
      const depth = Math.floor(item[1].replace(/\t/g, "  ").length / 2);
      const marker = /\d/.test(item[2]) ? item[2] : "•";
      body.push(`\\pard\\fi-360\\li${LIST_INDENT * (depth + 1)}\\sa60 ${escapeRtf(marker)}\\tab ${inlineToRtf(item[3])}\\par`);
    } else if (quote) {
      flush();
      body.push(`\\pard\\li${LIST_INDENT}\\sa160 ${inlineToRtf(quote[1])}\\par`);
    } else {
      paragraph.push(line.trim());
    }
  }
  flush();
  return (
    `{\\rtf1\\ansi\\ansicpg1252\\deff0\\uc1{\\fonttbl{\\f0\\fswiss Helvetica;}{\\f1\\fmodern Courier New;}}` +
    `\\f0\\fs${BODY_SIZE}\n${body.join("\n")}\n}`
  );
}

// ------------------------------------------------------------ RTF → Markdown

interface Style {
  bold: boolean;
  italic: boolean;
  strike: boolean;
  size: number;
  font: number;
  link: string | null;
  skip: boolean;
  fonttbl: boolean;
  fldinst: boolean;
}

interface Run {
  text: string;
  bold: boolean;
  italic: boolean;
  strike: boolean;
  mono: boolean;
  size: number;
  link: string | null;
}

interface Para {
  runs: Run[];
  left: number;
  first: number;
}

/** Destinations whose content is not text of the document. */
const IGNORED = new Set(["colortbl", "stylesheet", "info", "generator", "listtable", "listoverridetable", "revtbl", "pict", "header", "footer", "private"]);

export interface RtfImport {
  markdown: string;
  /** Human-readable names of formatting the conversion could not keep. */
  lost: string[];
}

export function rtfToMarkdown(rtf: string): RtfImport {
  const lost = new Set<string>();
  const paragraphs: Para[] = [];
  const monoFonts = new Set<number>();
  let current: Para = { runs: [], left: 0, first: 0 };
  let stack: Style[] = [];
  let style: Style = { bold: false, italic: false, strike: false, size: BODY_SIZE, font: 0, link: null, skip: false, fonttbl: false, fldinst: false };
  let skipChars = 0;
  let unicodeSkip = 1;
  let fontId = 0;
  let fontName = "";
  let fontModern = false;
  let fieldText = "";
  let fieldLink: string | null = null;
  let tableCells = false;

  const finishFont = () => {
    if (fontName.trim() && (fontModern || /courier|menlo|monaco|consolas|mono/i.test(fontName))) monoFonts.add(fontId);
    else if (fontName.trim() && fontId > 0) lost.add("fonts");
    fontName = "";
    fontModern = false;
  };

  const emit = (text: string) => {
    if (!text) return;
    if (style.fonttbl) {
      if (text === ";") finishFont();
      else fontName += text;
      return;
    }
    if (style.fldinst) {
      fieldText += text;
      return;
    }
    if (style.skip) return;
    const run: Run = { text, bold: style.bold, italic: style.italic, strike: style.strike, mono: monoFonts.has(style.font), size: style.size, link: style.link };
    const last = current.runs[current.runs.length - 1];
    if (last && last.bold === run.bold && last.italic === run.italic && last.strike === run.strike && last.mono === run.mono && last.size === run.size && last.link === run.link) last.text += text;
    else current.runs.push(run);
  };

  const endParagraph = () => {
    paragraphs.push(current);
    current = { runs: [], left: 0, first: 0 };
  };

  let i = 0;
  const n = rtf.length;
  while (i < n) {
    const c = rtf[i];
    if (c === "{") {
      stack.push({ ...style });
      i++;
    } else if (c === "}") {
      if (style.fonttbl && fontName.trim()) finishFont();
      style = stack.pop() ?? style;
      i++;
    } else if (c === "\\") {
      i++;
      const next = rtf[i] ?? "";
      if (!/[a-zA-Z]/.test(next)) {
        i++;
        if (next === "'") {
          const byte = parseInt(rtf.slice(i, i + 2), 16);
          i += 2;
          if (skipChars > 0) skipChars--;
          else if (!Number.isNaN(byte)) emit(new TextDecoder("windows-1252").decode(new Uint8Array([byte])));
        } else if (next === "*") {
          // Ignorable destination, unless it is the hyperlink instruction of a field.
          if (!/^\\fldinst/.test(rtf.slice(i, i + 8))) style.skip = true;
        } else if (next === "~") emit("\u00a0");
        else if (next === "-" || next === "_") emit(next === "_" ? "-" : "");
        else if (next === "\n" || next === "\r") endParagraph();
        else emit(next); // \\ \{ \}
        continue;
      }
      let word = "";
      while (i < n && /[a-zA-Z]/.test(rtf[i])) word += rtf[i++];
      let param: number | null = null;
      if (rtf[i] === "-" || /\d/.test(rtf[i] ?? "")) {
        let digits = rtf[i] === "-" ? "-" : "";
        if (digits) i++;
        while (i < n && /\d/.test(rtf[i])) digits += rtf[i++];
        param = parseInt(digits, 10);
      }
      if (rtf[i] === " ") i++; // the delimiter space belongs to the control word
      switch (word) {
        case "par":
          endParagraph();
          break;
        case "pard":
          current.left = 0;
          current.first = 0;
          break;
        case "line":
          emit("\n");
          break;
        case "tab":
          emit("\t");
          break;
        case "bullet":
          emit("•");
          break;
        case "b":
          style.bold = param !== 0;
          break;
        case "i":
          style.italic = param !== 0;
          break;
        case "strike":
          style.strike = param !== 0;
          break;
        case "fs":
          if (param !== null) style.size = param;
          break;
        case "f":
          if (param !== null) {
            if (style.fonttbl) {
              if (fontName.trim()) finishFont();
              fontId = param;
            }
            style.font = param;
          }
          break;
        case "fmodern":
          fontModern = true;
          break;
        case "fonttbl":
          style.fonttbl = true;
          style.skip = false;
          break;
        case "li":
          current.left = param ?? 0;
          break;
        case "fi":
          current.first = param ?? 0;
          break;
        case "uc":
          unicodeSkip = param ?? 1;
          break;
        case "u":
          if (param !== null) {
            emit(String.fromCharCode(param < 0 ? param + 65536 : param));
            skipChars = unicodeSkip;
          }
          break;
        case "ul":
        case "uldb":
          if (param !== 0 && !style.link) lost.add("underline");
          break;
        case "cf":
          if (param !== null && param > 0) lost.add("colours");
          break;
        case "trowd":
        case "cell":
          tableCells = true;
          break;
        case "fldinst":
          style.fldinst = true;
          style.skip = false;
          fieldText = "";
          break;
        case "fldrslt": {
          const url = /HYPERLINK\s+"([^"]+)"/i.exec(fieldText);
          fieldLink = url ? url[1] : null;
          style.link = fieldLink;
          style.skip = false;
          break;
        }
        default:
          if (IGNORED.has(word)) {
            style.skip = true;
            if (word === "pict") lost.add("images");
          }
      }
    } else {
      i++;
      if (c === "\r" || c === "\n") continue;
      if (skipChars > 0) {
        skipChars--;
        continue;
      }
      emit(c);
    }
  }
  if (current.runs.length) paragraphs.push(current);
  if (tableCells) lost.add("tables");

  return { markdown: paragraphsToMarkdown(paragraphs), lost: [...lost] };
}

const BULLET = /^[•·◦▪\-–]\t/;
const NUMBER = /^(\d+)[.)]\t/;

function stripPrefix(runs: Run[], length: number): Run[] {
  let rest = length;
  const out: Run[] = [];
  for (const run of runs) {
    if (rest >= run.text.length) rest -= run.text.length;
    else {
      out.push({ ...run, text: run.text.slice(rest) });
      rest = 0;
    }
  }
  return out;
}

function runsToMarkdown(runs: Run[], plainBold: boolean): string {
  return runs
    .map((run) => {
      const lead = /^\s*/.exec(run.text)![0];
      const trail = /\s*$/.exec(run.text.slice(lead.length))![0];
      let core = run.text.slice(lead.length, run.text.length - trail.length);
      if (!core) return run.text;
      if (run.mono) core = `\`${core}\``;
      else {
        if (run.strike) core = `~~${core}~~`;
        if (run.italic) core = `*${core}*`;
        if (run.bold && !plainBold) core = `**${core}**`;
      }
      if (run.link) core = `[${core}](${run.link})`;
      return lead + core + trail;
    })
    .join("");
}

function paragraphsToMarkdown(paragraphs: Para[]): string {
  const sizes = new Map<number, number>();
  for (const p of paragraphs) for (const r of p.runs) sizes.set(r.size, (sizes.get(r.size) ?? 0) + r.text.length);
  // The body text is the smallest size that carries a fair share of the text: headings are
  // short, so the most common size alone can be a heading's.
  const total = [...sizes.values()].reduce((a, b) => a + b, 0);
  const body = Math.min(...[...sizes.entries()].filter(([, count]) => count >= total * 0.15).map(([size]) => size), BODY_SIZE * 100);

  const out: string[] = [];
  let previous: string | null = null;
  let inCode = false;

  // Items of the same kind of list, and lines of one code block, stay together.
  const push = (line: string, kind: string) => {
    if (out.length && !(kind.startsWith("list") && previous === kind) && !(kind === "code" && previous === "code")) out.push("");
    out.push(line);
    previous = kind;
  };

  for (const p of paragraphs) {
    const text = p.runs.map((r) => r.text).join("");
    if (text.trim() === "") continue;
    const visible = p.runs.filter((r) => r.text.trim() !== "");

    if (visible.every((r) => r.mono)) {
      if (!inCode || previous !== "code") {
        push("```", "code");
        inCode = true;
      }
      out.push(text);
      continue;
    }
    if (inCode) {
      out.push("```");
      inCode = false;
    }

    const bullet = BULLET.exec(text);
    const numbered = NUMBER.exec(text);
    if (bullet || numbered) {
      const marker = (bullet ?? numbered)![0];
      const depth = Math.max(0, Math.round(p.left / LIST_INDENT) - 1);
      const item = runsToMarkdown(stripPrefix(p.runs, marker.length), false).trim();
      push(`${"  ".repeat(depth)}${numbered ? `${numbered[1]}.` : "-"} ${item}`, numbered ? "list:ol" : "list:ul");
      continue;
    }
    const size = Math.max(...visible.map((r) => r.size));
    const ratio = size / body;
    if (ratio >= 1.2 && visible.every((r) => r.size === size)) {
      const level = ratio >= 1.8 ? 1 : ratio >= 1.45 ? 2 : 3;
      push(`${"#".repeat(level)} ${runsToMarkdown(p.runs, true).trim()}`, "other");
      continue;
    }
    const line = runsToMarkdown(p.runs, false).trim();
    push(p.left > 0 && p.first === 0 ? `> ${line}` : line, "other");
  }
  if (inCode) out.push("```");
  return out.join("\n");
}

/** The names of formatting lost on import, as one phrase ("fonts and colours"). */
export function describeLost(lost: string[]): string {
  if (lost.length <= 1) return lost[0] ?? "";
  return `${lost.slice(0, -1).join(", ")} and ${lost[lost.length - 1]}`;
}
