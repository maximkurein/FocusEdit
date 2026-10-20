// Pasting a web address over selected text makes a Markdown link, as in
// Obsidian and Notion: select a word, paste the address, get [word](address).

const WEB_ADDRESS = /^https?:\/\/[^\s<>]+$/i;

/** The Markdown link for `selected` pasted over with `clipboard`, or null when it is not that gesture. */
export function linkFromPaste(selected: string, clipboard: string): string | null {
  const url = clipboard.trim();
  const text = selected.trim();
  if (!WEB_ADDRESS.test(url) || text === "" || /\n/.test(selected)) return null;
  // Brackets in the text would end the link early; parentheses in the address would end it too.
  const label = text.replace(/([[\]])/g, "\\$1");
  const target = url.replace(/\(/g, "%28").replace(/\)/g, "%29");
  // Spaces that came with the selection stay outside the link.
  const lead = /^\s*/.exec(selected)?.[0] ?? "";
  const trail = /\s*$/.exec(selected)?.[0] ?? "";
  return `${lead}[${label}](${target})${trail}`;
}
