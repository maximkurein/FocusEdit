# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Two apps, one product

- **macOS app** (`Sources/FocusEdit/`, `Package.swift`): Swift 5 language mode, AppKit + TextKit 1, SwiftPM, no third-party dependencies. macOS 13+. Docs are partly in Russian (`BUILD.md`, `VERSION_MANAGEMENT.md`, `START_HERE.md`); `README.md` is English.
- **Windows app** (`windows/`): separate, experimental port — Tauri 2 (Rust shell in `src-tauri/`) + CodeMirror 6 (TypeScript in `src/`). The writing logic (focus, typewriter, completion, auto-pairing, list continuation, Vim mode) is *re-implemented* in TS, not shared with Swift (`src/vim.ts` is a line-by-line port of `VimEngine.swift`; `src/vim-cm.ts` is the equivalent of `VimController.swift`). When changing behaviour in one, check whether the other needs the same change. Since 1.1 new features land in Windows first; `PROMT_MAC.md` (Russian) is the running task list of Windows features not yet ported to macOS, with `windows/tests/` as the reference behaviour — keep its version table current when adding Windows features. The Windows port shares the version: `update_version.py` also rewrites `windows/package.json`, `package-lock.json`, `src-tauri/tauri.conf.json`, `Cargo.toml` and `Cargo.lock` (the About block in the F1 hints reads it from `package.json` at build time).

## macOS commands

Run from the repo root (relative paths like `./package.sh` fail elsewhere).

```bash
swift build && .build/debug/FocusEdit --selftest   # fast loop: compile + headless tests (no bundle needed)
./package.sh                                  # release universal .app + DMG → .build/FocusEdit.app, .build/dist/
./package.sh --no-dmg                         # only the .app
./install.sh                                  # install the DMG into /Applications
.build/FocusEdit.app/Contents/MacOS/FocusEdit --selftest            # headless tests; exit 1 on failure
.build/FocusEdit.app/Contents/MacOS/FocusEdit examples/welcome.md   # run the bundle directly (not `open`: forbidden in this lab); stop with pkill -f FocusEdit
.build/FocusEdit.app/Contents/MacOS/FocusEdit examples/welcome.md --snapshot out.png [--theme Dark] [--content]
python3 scripts/update_version.py status | bump patch|minor|major | sync X.Y.Z --dry-run
```

- There is no XCTest target. Tests are `SelfTest.swift` (groups: syntax, completion, editing, rtf, markdown, palette, session, link paste, outline, live markup, new file, focus unit, vim) — add new checks there via its `check(name, actual, expected)` helper.
- Always rebuild with `package.sh`; copying a binary into an existing bundle invalidates the ad-hoc signature and macOS kills the app.
- Version lives in `Info.plist` (`CFBundleShortVersionString`) and is changed **only** via `scripts/update_version.py` (it also edits README version line, CHANGELOG headings and the Windows version files). `package.sh` refuses to build if versions disagree; `CFBundleVersion` is stamped by `package.sh`, never by hand.
- `package-lock.json` may be modified locally by `npm`; when committing a version bump, commit only its version lines.
- Pushing only on request. `git push origin main` pushes to both GitHub and Forgejo (`origin` has two push URLs); `forgejo` is a Forgejo-only remote.
- Be careful scripting edits to Swift files via Python/heredocs: a `\n` inside a string literal has turned into a real newline and broken the build more than once. Edit Swift text with backslashes through Edit/Write, not heredocs.
- README screenshots in `docs/images/` are regenerated with `--snapshot` (commands in `BUILD.md`).

## Windows commands

Run from `windows/`:

```bash
npm install
npm run dev                          # vite dev server on :1420 (browser fallback works without Tauri)
npm test                             # vitest run (tests/*.test.ts, node env; pure logic: vim, editing, completion, markdown-html, outline, recent/draft, export, themes, palette/session/links, live)
npx vitest run tests/editing.test.ts # single file; add -t "name" for a single test
npm run build                        # tsc --noEmit && vite build
npm run tauri -- build               # NSIS .exe installer (Windows only; CI does this). MSI is off: its AppUserModel.ID warning 1946
npm run snapshot                     # scripts/snapshot.mjs (playwright-core) → UI screenshots
```

CI (`.github/workflows/windows.yml`) runs `npm ci`, `npm test`, `tauri build` on pushes to `main` touching `windows/**`.

## macOS architecture

- `main.swift` handles CLI flags (`--selftest`, `--snapshot`, `--makeicon`, `--make-default`) before starting `AppDelegate`.
- Document model: `FocusDocument` (NSDocument) with `DocumentKind` (Markdown / Fountain / plain). RTF files are converted to Markdown on open and back on save by `RTFMarkdown` (lossy: fonts, colours, images, tables are dropped).
- Window: `DocumentWindowController` → `MainSplitViewController` hosting `LibraryViewController`, `EditorViewController`, `OutlineViewController`. `EditorViewController` owns theme/size/font/focus-mode state and the writing aids, and forwards edits to outline/preview.
- Editing surface: `FocusTextView` (focus fade, typewriter scrolling) with `EditorCommands` (formatting, CriticMarkup). Highlighting is split in `SyntaxHighlighter` (semantic `SyntaxRole` tokens via `SyntaxEngine`) with `MarkdownHighlighter` / `FountainHighlighter`; roles are resolved to colours/traits at render time from `Theme`, so theme switches do not retokenise.
- `CompletionEngine` (grey inline word suggestion), `VimEngine` (pure operator+motion grammar, teaching mode with explanations) driven by `VimController` in the view; `MarkdownToHTML` + `PreviewViewController` (split pane beside the editor) for preview; `Snapshot` for headless rendering; `IconFactory` draws the app icon in code (no PNG assets).
- `--snapshot` extras for checking UI headlessly: `--view split|preview`, `--palette QUERY`, `--goal N`, `--welcome` and `--start` (both with no file). `--theme`/`--view` values need a file argument, otherwise AppKit takes them for files to open. The glass outline inspector and a dark toolbar don't render off-screen.
- Live Markdown: `LiveMarkdown` finds elements per line; `FocusTextView` draws hidden marks as `.null` glyphs (`NSLayoutManagerDelegate`) and keeps the hidden index set in step with edits (`NSTextStorageDelegate`) so only changed glyphs are regenerated. `ToolbarSymbol` can draw a word instead of a symbol (`text:Vim`).

## Documents: create, open, save, close

Formats on both sides: `.txt` (plain), `.md` / `.markdown` / `.mdown` / `.mkd` / `.mdwn` (Markdown; the Windows Open dialog filters only `.md` / `.markdown`), `.fountain`, and `.rtf`, which is edited as Markdown and converted on read and write (`RTFMarkdown.swift` / `rtf.ts`; bold, italic, strikethrough, headings, lists, quotes, links and code survive, fonts, colours, images and tables don't, and opening such a file warns). The kind comes from the extension (`DocumentKind` / `kindForPath`) and switches on Save As (`FocusDocument.fileURL` didSet → `updateKind`).

| | Mac (`NSDocument`, one window per document) | Windows (one document per window, `main.ts` + `platform.ts`) |
|---|---|---|
| New | ⌘N untitled; File ▸ New From Template; ⇧⌘N New File… (also a toolbar button and the start screen) writes the file first (`NewFile.data`), then opens it | `newDocument()`; `newFile()` → `wizard.ts`, writes via `platform.writeFile`, then `load()` |
| Open | `NSDocumentController` (Open…, Open Recent, Dock / Finder, drop on the window via `enableFileDropOpening`, Library sidebar); types declared in `Info.plist` | `openDocument()` / `openRecent()` / `openDropped()` → `platform.readFile` → `decode()` (RTF → Markdown) → `load()`; recents in `recent.ts` |
| Save | `FocusDocument.data(ofType:)` writes `textView.string` (RTF via `RTFMarkdown.rtf(fromMarkdown:)`); classic Save / Save As / Revert (`autosavesInPlace = false`) | `save()` / `saveAs()` → `platform.writeFile` (RTF via `markdownToRtf`), BOM put back by `contents()` |
| Unsaved changes | the system's Save / Don't Save / Cancel sheet on close and quit | `canDiscard()` → `platform.confirmClose()` before close, new, open, drop |
| Close | ⌘W = File ▸ Close File (`MainSplitViewController.closeFile`): closing the last document leaves an empty untitled window with the start screen; the window's close button closes it all, the app stays (Dock click → new document) | `closeDocument()` → empty "Untitled" + the start screen |
| Start screen | `StartView` over a pristine document (`EditorViewController.isPristine`: untitled, unedited, empty); a file opened then takes its window (`FocusDocument.replacePristineDocuments`) | `updateStart()` in `main.ts` |
| Crash recovery | autosave elsewhere every 60 s (`autosavingDelay`), offered back by the system at the next launch | `draft.ts` in localStorage, `platform.confirmRestore()` at start |

Display attributes (fonts, colours, hidden marks) live only in the text view; both sides save the raw text, never attributes.

## Mac ↔ Windows pairs

The same behaviour is written twice. Pure logic lives in types that can be tested without a window; the Windows test file is the reference, and its cases are copied into the matching `--selftest` group. Change both sides together.

| Swift (`Sources/FocusEdit/`) | TypeScript (`windows/src/`) | Tests |
|---|---|---|
| `VimEngine` / `VimController` | `vim.ts` / `vim-cm.ts` | `vim` |
| `CompletionEngine`; ghost, list continuation and pairing in `FocusTextView` | `completion.ts`, `ghost.ts`; pairing and list continuation are CodeMirror's own (`closeBrackets`, `insertNewlineContinueMarkup`) | `completion`, `editing` |
| `FocusUnit` | `focus.ts` | `focus` / Focus unit |
| `RTFMarkdown` | `rtf.ts` | `rtf` |
| `NewFile` / `NewFileWizard` | `newfile.ts` / `wizard.ts` | `newfile` / New File |
| `MarkdownToHTML` | `markdown-html.ts` | `markdown-html` / Markdown |
| `ViewMode` (in `MainSplitViewController.swift`) | `setView` in `main.ts` | — |
| `CommandPalette.swift` (`PaletteSearch`; commands in a `MainSplitViewController` extension, shortcuts read from the menus) | `palette.ts`, `allCommands()` in `main.ts` | `palette-session-links` / Palette |
| `Session` (+ `GoalBar` in the editor) | `session.ts` | same / Session |
| `LinkPaste` | `links.ts` | same / Link paste |
| `Welcome` (first start via `applicationOpenUntitledFile`) | `welcome.ts` | — |
| `OutlineExtractor` (in `DocumentKind.swift`) | `outline.ts` | `outline` / Outline |
| `LiveMarkdown` | `live.ts` | `live` / Live markup |

Known, deliberate differences: the Mac preview shows images (Windows shows the caption); Fountain forced scenes (`.SCENE`) only on the Mac; no start screen on the Mac (Dock click opens a new document).

## Windows architecture

`src/main.ts` is the app shell (document lifecycle, toolbar, shortcuts, title/word count). `editor.ts` builds the CodeMirror instance; `focus.ts` (focus + typewriter), `ghost.ts` (inline suggestion), `completion.ts` (word engine, doc kinds), `settings.ts`/`themes.ts` (runtime-switched via compartments/CSS), `hints.ts`, `outline.ts` (headings + panel), `recent.ts` and `draft.ts` (recent files, crash recovery; both in localStorage), `export.ts` (HTML page, copy, print), `menu.ts` (pop-up menu), `palette.ts` (command palette, fuzzy match), `session.ts` (word goal, session timer, word counting), `links.ts` (paste URL over selection → Markdown link), `live.ts` (live Markdown: hides formatting marks away from the cursor via decorations), `welcome.ts` (first-run welcome document), `rtf.ts` (RTF ↔ Markdown, the port of `RTFMarkdown.swift`; `.rtf` is converted in `platform.ts` on read/write), `newfile.ts` + `wizard.ts` (New file… dialog: pure rules and the three-step overlay), `markdown-html.ts` (preview renderer), `vim.ts`/`vim-cm.ts`. `platform.ts` bridges to Tauri (real files/dialogs via `lib.rs`) with browser fallbacks, which is what makes browser-based UI testing/screenshots possible. Files are read as UTF-8 (`read_text` in `lib.rs`, lossy) and keep their BOM and line endings.
