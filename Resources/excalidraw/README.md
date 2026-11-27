# Excalidraw board (FocusEdit)

The `.excalidraw` board window (`Sources/FocusEdit/Board.swift`) loads `index.html`
from this folder through the `fe-board:` scheme. Everything is offline.

- `board.js`: `source/board.jsx` bundled with esbuild: Excalidraw 0.18.1, React 18.3.1,
  @excalidraw/mermaid-to-excalidraw 2.2.2 with mermaid pinned to 11.12.3 (11.17 renames
  subgraph ids and breaks the converter). About 8 MB.
- `board.css`: `@excalidraw/excalidraw/dist/prod/index.css`.
- `fonts/`: `@excalidraw/excalidraw/dist/prod/fonts` without `Xiaolai` (CJK, 13 MB).
- Licenses: `THIRD-PARTY-LICENSES.txt` (all MIT / ISC / BSD / Apache / OFL-1.1).

Rebuild:

```sh
mkdir board && cd board && npm init -y
npm install --ignore-scripts @excalidraw/excalidraw@0.18.1 react@18.3.1 react-dom@18.3.1 esbuild@0.25.0
npm pkg set overrides.mermaid=11.12.3 && npm install --ignore-scripts
npx esbuild ../source/board.jsx --bundle --minify --format=iife --target=safari16 \
  --define:process.env.NODE_ENV='"production"' --conditions=production \
  --outfile=board.js --legal-comments=external
```

The page API is `window.__feBoard`: `load(json)`, `save()` → JSON, `fromMermaid(source)`,
`svg()`, `png()` → base64, `setTheme(dark)`, `ready()`. It posts `boardChanged(dirty)`.
