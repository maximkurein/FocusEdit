// Word completion, ported from the macOS CompletionEngine.swift.
// Suggests words already used in the document (most frequent first). Fountain
// documents also get scene-heading prefixes and known character cues.
// The browser has no system dictionary API, so there is no dictionary fallback.

export type DocKind = "plain" | "markdown" | "fountain";

export function kindForPath(path: string | null): DocKind {
  const ext = (path ?? "").toLowerCase().split(".").pop() ?? "";
  if (["md", "markdown", "mdown", "mkd", "mdwn"].includes(ext)) return "markdown";
  if (ext === "fountain") return "fountain";
  return "plain";
}

const WORD = /[\p{L}\p{N}'’-]/u;
const SCENE_HEADINGS = ["INT. ", "EXT. ", "INT./EXT. ", "EST. "];

export function isWordChar(c: string): boolean {
  return WORD.test(c);
}

export class CompletionEngine {
  private _kind: DocKind = "plain";
  private text = "";
  private dirty = true;
  private counts = new Map<string, number>(); // lowercased word → uses
  private forms = new Map<string, string>(); // lowercased word → spelling as written
  private characters: string[] = []; // Fountain character cues, in order of use

  get kind(): DocKind {
    return this._kind;
  }
  set kind(k: DocKind) {
    this._kind = k;
    this.dirty = true;
  }

  update(text: string): void {
    this.text = text;
    this.dirty = true;
  }

  /** Characters to append after `prefix` for the best suggestion, or null. */
  suffix(prefix: string, linePrefix: string): string | null {
    const best = this.best(prefix, linePrefix);
    if (!best || [...best].length <= [...prefix].length) return null;
    return [...best].slice([...prefix].length).join("");
  }

  /** Full candidates for the completion list (Ctrl+Space). */
  completions(prefix: string, linePrefix: string, limit = 8): string[] {
    this.reindex();
    const out: string[] = [];
    for (const s of [...this.fountain(prefix, linePrefix), ...this.document(prefix)]) {
      if (!out.includes(s)) out.push(s);
    }
    return out.slice(0, limit);
  }

  private best(prefix: string, linePrefix: string): string | null {
    this.reindex();
    const f = this.fountain(prefix, linePrefix)[0];
    if (f) return f;
    if ([...prefix].length < 2) return null;
    return this.document(prefix)[0] ?? null;
  }

  private document(prefix: string): string[] {
    const p = prefix.toLowerCase();
    return [...this.counts.keys()]
      .filter((w) => [...w].length > [...p].length + 1 && w.startsWith(p))
      .sort((a, b) => {
        const byUse = (this.counts.get(b) ?? 0) - (this.counts.get(a) ?? 0);
        return byUse !== 0 ? byUse : [...a].length - [...b].length;
      })
      .map((w) => adapt(this.forms.get(w) ?? w, prefix));
  }

  private fountain(prefix: string, linePrefix: string): string[] {
    if (this._kind !== "fountain") return [];
    if (linePrefix.trim() !== prefix || prefix !== prefix.toUpperCase()) return [];
    if (!/\p{L}/u.test(prefix)) return [];
    const longer = (s: string) => s.startsWith(prefix) && s.length > prefix.length;
    return [...SCENE_HEADINGS.filter(longer), ...this.characters.filter(longer)];
  }

  private reindex(): void {
    if (!this.dirty) return;
    this.dirty = false;
    this.counts.clear();
    this.forms.clear();
    this.characters = [];

    for (const token of this.text.split(/[^\p{L}\p{N}'’-]+/u)) {
      if ([...token].length < 4) continue;
      const key = token.toLowerCase();
      this.counts.set(key, (this.counts.get(key) ?? 0) + 1);
      this.forms.set(key, token);
    }

    if (this._kind !== "fountain") return;
    const seen = new Set<string>();
    for (const raw of this.text.split("\n")) {
      const t = raw.trim();
      if (t.length < 2 || t !== t.toUpperCase() || !/\p{L}/u.test(t)) continue;
      if (t.endsWith("TO:") || isSceneHeading(t)) continue;
      const name = t.split("(")[0].trim();
      if (name && !seen.has(name)) {
        seen.add(name);
        this.characters.push(name);
      }
    }
  }
}

/** Keep what the user typed (its case) and append the rest of the candidate. */
function adapt(candidate: string, prefix: string): string {
  const c = [...candidate];
  const p = [...prefix];
  return c.length < p.length ? candidate : prefix + c.slice(p.length).join("");
}

function isSceneHeading(line: string): boolean {
  const upper = line.toUpperCase();
  return ["INT", "EXT", "EST", "I/E"].some((h) => upper.startsWith(h)) ||
    (line.startsWith(".") && !line.startsWith(".."));
}
