// Copies the diagram scripts (and the Excalidraw board) from the Mac app's
// Resources/ into public/fe/, which Vite serves in dev and copies into dist/.
// Runs before `npm run dev` and `npm run build`; public/fe/ is not committed.
import { cpSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const resources = join(here, "..", "..", "Resources");
const target = join(here, "..", "public", "fe");

const files = [
  "mermaid.min.js",
  "mermaid-LICENSE.txt",
  "mermaid-layout-elk.min.js",
  "mermaid-layout-elk-LICENSE.txt",
  "diagrams.js",
];

rmSync(target, { recursive: true, force: true });
mkdirSync(target, { recursive: true });
for (const file of files) cpSync(join(resources, file), join(target, file));

// The Excalidraw board (Excalidraw 0.18.1, MIT): the Mac's files, with a page of our own
// whose setup is a script file (the window's CSP allows no inline scripts) and which hands
// the board's messages to the app around it (the board runs in an iframe).
const board = join(target, "excalidraw");
mkdirSync(board, { recursive: true });
for (const file of ["board.js", "board.css", "THIRD-PARTY-LICENSES.txt", "fonts"]) {
  cpSync(join(resources, "excalidraw", file), join(board, file), { recursive: true });
}
writeFileSync(
  join(board, "setup.js"),
  `// Fonts come from fonts/ next to this page, never from the network.
window.EXCALIDRAW_ASSET_PATH = new URL("./", location.href).href;
// The board's messages (boardChanged) go to the app that holds this frame.
window.webkit = { messageHandlers: { boardChanged: { postMessage: function (b) {
  try { window.parent.__feBoardMessage && window.parent.__feBoardMessage("boardChanged", b); } catch (e) {}
} } } };
// Ctrl+S saves the board (the app's shortcuts do not reach into this frame).
window.addEventListener("keydown", function (e) {
  if ((e.ctrlKey || e.metaKey) && !e.shiftKey && !e.altKey && e.key.toLowerCase() === "s") {
    e.preventDefault();
    try { window.parent.__feBoardMessage("save"); } catch (err) {}
  }
}, true);
`,
);
writeFileSync(
  join(board, "board.html"),
  `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Board</title>
<link rel="stylesheet" href="board.css">
<style>html, body, #board { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; }</style>
<script src="setup.js"></script>
</head>
<body>
<div id="board"></div>
<script src="board.js"></script>
</body>
</html>
`,
);
console.log(`copy-resources: ${files.length} files and the Excalidraw board → public/fe/`);
