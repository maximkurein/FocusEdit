# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Two apps, one product

- **macOS app** (`Sources/FocusEdit/`, `Package.swift`): Swift 5 language mode, AppKit + TextKit 1, SwiftPM, no third-party dependencies. macOS 13+. Docs are partly in Russian (`BUILD.md`, `VERSION_MANAGEMENT.md`, `START_HERE.md`); `README.md` is English.
- **Windows app** (`windows/`): separate, experimental port — Tauri 2 (Rust shell in `src-tauri/`) + CodeMirror 6 (TypeScript in `src/`). The writing logic (focus, typewriter, completion, auto-pairing, list continuation, Vim mode) is *re-implemented* in TS, not shared with Swift (`src/vim.ts` is a line-by-line port of `VimEngine.swift`; `src/vim-cm.ts` is the equivalent of `VimController.swift`). When changing behaviour in one, check whether the other needs the same change. The Windows port shares the version: `update_version.py` also rewrites `windows/package.json`, `package-lock.json`, `src-tauri/tauri.conf.json`, `Cargo.toml` and `Cargo.lock` (the About block in the F1 hints reads it from `package.json` at build time).

## macOS commands

Run from the repo root (relative paths like `./package.sh` fail elsewhere).

```bash
swift build                                   # debug build → .build/debug/FocusEdit (compile check)
./package.sh                                  # release universal .app + DMG → .build/FocusEdit.app, .build/dist/
./package.sh --no-dmg                         # only the .app
./install.sh                                  # install the DMG into /Applications
.build/FocusEdit.app/Contents/MacOS/FocusEdit --selftest            # headless tests; exit 1 on failure
.build/FocusEdit.app/Contents/MacOS/FocusEdit examples/welcome.md --snapshot out.png [--theme Dark] [--content]
python3 scripts/update_version.py status | bump patch|minor|major | sync X.Y.Z --dry-run
```

- There is no XCTest target. Tests are `SelfTest.swift` (`--selftest`: syntax, completion, editing, rtf, vim groups) — add new checks there via its `check(name, actual, expected)` helper.
- Always rebuild with `package.sh`; copying a binary into an existing bundle invalidates the ad-hoc signature and macOS kills the app.
- Version lives in `Info.plist` (`CFBundleShortVersionString`) and is changed **only** via `scripts/update_version.py` (it also edits README version line, CHANGELOG headings and the Windows version files). `package.sh` refuses to build if versions disagree; `CFBundleVersion` is stamped by `package.sh`, never by hand.
- README screenshots in `docs/images/` are regenerated with `--snapshot` (commands in `BUILD.md`).

## Windows commands

Run from `windows/`:

```bash
npm install
npm run dev                          # vite dev server on :1420 (browser fallback works without Tauri)
npm test                             # vitest run (tests/*.test.ts, node environment)
npx vitest run tests/editing.test.ts # single file; add -t "name" for a single test
npm run build                        # tsc --noEmit && vite build
npm run tauri -- build               # .msi/.exe installers (Windows only; CI does this)
npm run snapshot                     # scripts/snapshot.mjs (playwright-core) → UI screenshots
```

CI (`.github/workflows/windows.yml`) runs `npm ci`, `npm test`, `tauri build` on pushes to `main` touching `windows/**`.

## macOS architecture

- `main.swift` handles CLI flags (`--selftest`, `--snapshot`, `--makeicon`, `--make-default`) before starting `AppDelegate`.
- Document model: `FocusDocument` (NSDocument) with `DocumentKind` (Markdown / Fountain / plain). RTF files are converted to Markdown on open and back on save by `RTFMarkdown` (lossy: fonts, colours, images, tables are dropped).
- Window: `DocumentWindowController` → `MainSplitViewController` hosting `LibraryViewController`, `EditorViewController`, `OutlineViewController`. `EditorViewController` owns theme/size/font/focus-mode state and the writing aids, and forwards edits to outline/preview.
- Editing surface: `FocusTextView` (focus fade, typewriter scrolling) with `EditorCommands` (formatting, CriticMarkup). Highlighting is split in `SyntaxHighlighter` (semantic `SyntaxRole` tokens via `SyntaxEngine`) with `MarkdownHighlighter` / `FountainHighlighter`; roles are resolved to colours/traits at render time from `Theme`, so theme switches do not retokenise.
- `CompletionEngine` (grey inline word suggestion), `VimEngine` (pure operator+motion grammar, teaching mode with explanations) driven by `VimController` in the view; `MarkdownToHTML` + `PreviewWindowController` for preview; `Snapshot` for headless rendering; `IconFactory` draws the app icon in code (no PNG assets).

## Windows architecture

`src/main.ts` is the app shell (document lifecycle, toolbar, shortcuts, title/word count). `editor.ts` builds the CodeMirror instance; `focus.ts` (focus + typewriter), `ghost.ts` (inline suggestion), `completion.ts` (word engine, doc kinds), `settings.ts`/`themes.ts` (runtime-switched via compartments/CSS), `hints.ts`. `platform.ts` bridges to Tauri (real files/dialogs via `lib.rs`) with browser fallbacks, which is what makes browser-based UI testing/screenshots possible. Files keep their encoding, BOM and line endings.
