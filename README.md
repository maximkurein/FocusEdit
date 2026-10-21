# FocusEdit

FocusEdit is a minimalist macOS text editor for distraction-free writing. It keeps your line in the middle of the screen, fades everything you are not working on, and saves plain text files: Markdown, Fountain screenplays or ordinary text. An experimental Windows version lives in [`windows/`](windows/) — see [Windows (experimental)](#windows-experimental).

**Version:** `1.5.2`, released 21.10.2026 · [changelog](CHANGELOG.md) · [how versions are managed](VERSION_MANAGEMENT.md)

<p align="center">
  <img src="docs/images/window-light.png" width="760" alt="FocusEdit editing a Markdown document: a toolbar with focus, typewriter, sound, theme, preview, hints and outline buttons, the word count under the title, faded paragraphs around the active list item, and a grey suggestion completing the word Markdown">
</p>

<table>
  <tr>
    <td width="50%"><img src="docs/images/editor-dark.png" alt="The same document in the dark theme"></td>
    <td width="50%">
      <b>Dark, Light and Sepia themes</b>, or your own.<br><br>
      Formatting stays visible in faded paragraphs: bold, italic and code keep their style while the color steps back.
    </td>
  </tr>
</table>

<sub>Screenshots come from <code>FocusEdit examples/welcome.md --snapshot</code>; see <a href="#command-line">Command line</a>.</sub>

> **Status: prototype.** Everything listed below works. Not yet done: iCloud sync and version conflicts, a Quick Look extension, screenplay page layout for Fountain PDF export, and a signed, notarized build.

## What it does

- **Focus** — highlight only the current sentence or paragraph (the text up to the blank lines; a heading or a list item counts as its own block), with a short fade as you move; keep the active line fixed at the centre of the window (typewriter scrolling); optional typewriter sounds; full screen hides the toolbar and the menu bar.
- **Writing aids** — a grey suggestion completes the word you are typing from words already in the document, then from the system dictionary (English and Russian); brackets and quotes close themselves and wrap a selection; pasting a web address over selected text makes a Markdown link `[text](address)`; Return continues Markdown lists, task lists and quotes. In Fountain, scene headings and character names you have used are suggested.
- **Plain text, styled on screen** — Markdown headings, emphasis, code, quotes, lists, links and CriticMarkup; Fountain scene headings, characters, parentheticals and transitions. Styling is display-only: the file on disk stays clean plain text.
- **Vim mode for learning** — Modus ▸ Vim Mode: Normal, Insert and Visual modes with the operator + motion grammar (`dw`, `ciw`, `3j`, `.`), and a coach bar under the text that explains every command and suggests faster ways. Leave it with the Exit Vim button on the coach bar or `:novim`. Works in the Russian keyboard layout too. A lesson-by-lesson course is in [VIM_GUIDE.md](VIM_GUIDE.md).
- **New File…** — `⇧⌘N` opens a three-step dialog: pick the format (`.txt`, `.md` or `.rtf`), what to start from (blank, note, to-do list, meeting notes), then the name and the folder; the file is created and opened. The same dialog is in the Windows version (`Ctrl+Shift+N`).
- **RTF** — `.rtf` files (TextEdit's default format) open as Markdown and save back as RTF: bold, italic, strikethrough, headings, lists, links and code survive the round trip; fonts, colours, images and tables do not, and FocusEdit warns when a file has them. **FocusEdit ▸ Make Default Editor for .txt and .rtf** makes double-clicked text and RTF files open in FocusEdit.
- **Documents** — standard macOS documents: open, save, revert, recent files, drag and drop, and autosave elsewhere every minute so unsaved text survives a crash. A library sidebar browses a linked folder; the outline jumps between headings and keeps the one you are in selected; the window subtitle shows the word count and reading time, the words in the selection, or — with a word goal set from the palette — the words written this session, the time spent writing and a thin progress bar under the toolbar; find and replace.
- **Preview and export** — live HTML preview for Markdown in a pane beside the text (tables, task lists, strikethrough, nested lists, reference links), scrolling together with it, export as HTML or PDF, copy as HTML, print.
- **Themes and type** — Light, Dark, Sepia and custom themes; system, monospaced or serif font; three column widths.
- **Command palette** — `⇧⌘P`: type a few letters of what you want to do (a theme, a view, export, a recent file…) and press Return; a number sets a word goal or jumps to that line.
- **Help where you are** — every toolbar button has a tooltip with its shortcut, ⌘? opens a cheat sheet for the current document type, and the first start opens a welcome tour that teaches by being edited (Help ▸ Welcome Tour shows it again).

## Shortcuts

| Keys | Action |
|---|---|
| Tab or → | Accept the grey suggestion |
| Esc · ⌥Esc | Dismiss the suggestion · list all completions |
| ⇧⌘P | Command palette: every action by typing a few letters; a number sets a word goal or goes to that line |
| ⇧⌘N | New File…: format, template, name |
| ⌘T | Keep the active line centred |
| ⌘U | Typewriter sounds |
| ⌥⌘P | View: Edit → Split (live preview) → Preview only; Esc leaves Preview (Markdown) |
| ⌥⌘L · ⌥⌘O | Library · outline |
| ⌘B · ⌘I · ⌘K | Bold · italic · link |
| ⌃⌘F | Full screen |
| ⌘? | Hints and shortcuts |

## Requirements

- macOS 13 or later to run; Xcode 26 to build (tested with Xcode 26.5, Swift 6.3)
- No third-party dependencies: AppKit, WebKit and AVFoundation only
- Python 3 for `scripts/update_version.py` (standard library only)

## Build and run

```bash
./package.sh   # build Release and pack .build/dist/FocusEdit-<version>.dmg
./install.sh   # install that DMG into Applications and refresh the Dock icon
```

`package.sh` checks that the version files agree, builds a universal Release (Apple Silicon and Intel), assembles the app bundle, stamps a UTC build number, renders the app icon (it is drawn in code), ad-hoc signs and verifies the bundle, then packs and verifies the DMG. `./package.sh --no-dmg` builds only `.build/FocusEdit.app`, which runs in place: `.build/FocusEdit.app/Contents/MacOS/FocusEdit examples/welcome.md`. Always rebuild with `package.sh`: copying a new binary into an existing bundle invalidates its signature and macOS kills the app at launch.

`install.sh` quits a running FocusEdit, moves the installed copy to the Trash (nothing is deleted), copies the new one, re-registers it with Launch Services and restarts the Dock, which otherwise can keep a blank cached icon. To install by hand instead, `./package.sh --open` opens the DMG in Finder; drag **FocusEdit** into **Applications**.

The build is ad-hoc signed, not notarized: it opens without warnings on the Mac that built it, while on other Macs macOS blocks it until you choose **System Settings → Privacy & Security → Open Anyway**.

The step-by-step build guide with common problems: [BUILD.md](BUILD.md) (in Russian).

## Command line

```bash
FocusEdit [file]                          # open a document
FocusEdit --selftest                      # headless checks: highlighting, completion, editing; exit 1 on failure
FocusEdit file --snapshot out.png         # render the window to PNG without screen-recording permission, then quit
          [--theme Dark] [--content]      #   pick a theme for the shot; keep only the area below the toolbar
FocusEdit --makeicon AppIcon.iconset      # render every icon size
```

The snapshot window stays invisible and never takes keyboard focus, and its demo typing is never saved.

## Windows (experimental)

[`windows/`](windows/) holds an experimental Windows version: a separate app built with [Tauri 2](https://tauri.app) and [CodeMirror 6](https://codemirror.net), since AppKit exists only on macOS. The writing logic is ported from the Swift code: focus highlighting by sentence or paragraph, typewriter scrolling, the grey word suggestion, automatic pairing, Markdown list continuation, the Vim learning mode (the Vim button in the toolbar; same commands and coach bar as on the Mac, `Ctrl+R` redoes), an outline of headings (`Ctrl+Shift+O`), recent files and export to HTML, print or PDF, copy as HTML (the ⋯ button), recovery of unsaved text after a crash, a theme that follows the Windows light/dark setting, a Markdown preview (the View button: edit, split with a live preview, or preview only; `Ctrl+Shift+P`), files dropped on the window to open them, themes, and plain-text files that keep their encoding and line endings.

<table>
  <tr>
    <td width="50%"><img src="docs/images/windows-light.png" alt="The Windows version: a light toolbar with open, save, recent files and export, view mode, outline, focus (Paragraph), typewriter, theme, column width, font, full screen, Vim and hints buttons; the document in a centred column with faded paragraphs and a grey suggestion completing Markdown"></td>
    <td width="50%"><img src="docs/images/windows-dark.png" alt="The Windows version in the dark theme"></td>
  </tr>
</table>

<sub>Rendered from the same web UI in Chrome by <code>npm run snapshot</code> in <code>windows/</code>.</sub>

- **Status:** stage 2. Ported: focus and typewriter, writing aids, Vim mode, Markdown preview (edit, split, preview), outline, recent files, export (HTML, print or PDF, copy as HTML), crash recovery, themes including System, drag-and-drop open. `.rtf` open and save (as Markdown), New File… (three steps). Not yet ported: the library, Fountain highlighting, CriticMarkup and typewriter sounds.
- **Installers:** GitHub Actions builds the `.exe` installer on Windows for every push to `main` that changes `windows/` (**Actions** → latest run → artifact **FocusEdit-windows**). They cannot be built on a Mac.
- **Keys:** Ctrl replaces ⌘; F1 opens the hints (with the version and the developer), F11 toggles full screen. Focus modes have no shortcuts: use the focus button in the toolbar.

  | Keys | Action |
  |---|---|
  | Ctrl+Shift+P | Command palette: type what you want to do (themes, view, export, word goal, recent files…) |
  | Ctrl+Shift+N | New file…: pick txt, md or rtf, a template, a name and a folder |
  | Ctrl+W | Close the file, keep the app: a start screen offers New file… and Open… |
  | Ctrl+Shift+V | View: Edit → Split → Preview (Esc leaves the preview) |
  | Ctrl+Shift+O | Outline of headings |
  | Ctrl+P | Print, or save as PDF from the print dialog |
  | ⋯ button | Recent files · Export as HTML · Copy as HTML |
  | Ctrl+R | Redo in Vim mode (it no longer reloads the window) |
  | select text, paste a web address | Makes a Markdown link `[text](address)` |

  Also: live Markdown (the marks `#`, `**`, `*`, `` ` ``, `[ ](…)` are hidden away from the cursor and appear as it comes close; palette: *Markup*), a word goal with a thin progress bar and a timer that counts only the time you write (palette: *Word goal*), a word count of the selection under the title, and a welcome document on the first start (palette: *Open the welcome tour*).
- **Build from source:** Node.js 22+ and Rust; see [windows/BUILD.md](windows/BUILD.md) (in Russian).

## Project documents

- [VIM_GUIDE.md](VIM_GUIDE.md) — learning Vim with FocusEdit's Vim mode: lessons, exercises, moving on to NeoVim (in Russian)
- [START_HERE.md](START_HERE.md) — how to work in the app: focus modes, writing aids, Markdown and Fountain, shortcuts (in Russian)
- [windows/BUILD.md](windows/BUILD.md) — the experimental Windows version: what is ported and how to build it (in Russian)
- [PROMT_MAC.md](PROMT_MAC.md) — a task for Claude Code on a Mac: what to check and what to port from the Windows version (in Russian)
- [BUILD.md](BUILD.md) — how to build, run and check (in Russian)
- [VERSION_MANAGEMENT.md](VERSION_MANAGEMENT.md) — how versions are changed and kept in sync (in Russian)
- [CHANGELOG.md](CHANGELOG.md) — what changed in each version
- [implementation-plan.md](../implementation-plan.md) — milestones M0–M6 (in Russian)

FocusEdit is an independent implementation written from scratch. Its feature set was modelled on uFocus, studied through static analysis of the shipped app bundle; no code, icons, sounds or other assets were copied, and the project is not affiliated with its authors.

## License

No license has been chosen yet.
