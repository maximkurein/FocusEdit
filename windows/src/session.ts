// A writing session: words written since the document was opened (or the
// goal was set), and the time actually spent writing.

/** Words as the word count shows them: runs of non-space characters. */
export function countWords(text: string): number {
  const match = text.match(/\S+/g);
  return match ? match.length : 0;
}

/** Typing counts as writing for this long after the last change. */
export const IDLE_MS = 30_000;

export class Session {
  private baseline = 0;
  private words = 0;
  private active = 0;
  private lastActivity = Number.NEGATIVE_INFINITY;
  private lastTick: number | null = null;

  /** Start over from a document with `words` words in it. */
  reset(words: number, now = Date.now()): void {
    this.baseline = words;
    this.words = words;
    this.active = 0;
    this.lastActivity = Number.NEGATIVE_INFINITY;
    this.lastTick = now;
  }

  /** The text changed: it now has `words` words. */
  note(words: number, now = Date.now()): void {
    this.words = words;
    this.lastActivity = now;
  }

  /** Call about once a second; adds the time since the last call if writing is going on. */
  tick(now = Date.now()): void {
    const since = this.lastTick === null ? 0 : now - this.lastTick;
    this.lastTick = now;
    // A long gap means the computer slept, not that the user wrote: ignore it.
    if (now - this.lastActivity <= IDLE_MS && since > 0 && since <= 5000) this.active += since;
  }

  /** Words added since the start (never negative: deleting does not count against you). */
  get written(): number {
    return Math.max(0, this.words - this.baseline);
  }

  get activeMs(): number {
    return this.active;
  }

  /** 0…1 */
  progress(goal: number): number {
    return goal > 0 ? Math.min(1, this.written / goal) : 0;
  }
}

/** 75 s → "1:15", 3725 s → "1:02:05" */
export function formatDuration(ms: number): string {
  const total = Math.floor(ms / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const two = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${two(m)}:${two(s)}` : `${m}:${two(s)}`;
}
