# Changelog

Все заметные изменения FocusEdit. Формат — [Keep a Changelog](https://keepachangelog.com/),
версии — [Semantic Versioning](https://semver.org/). Заголовки правит
`scripts/update_version.py`; текст заметок пишется руками.

## [Unreleased]

## [1.2.0] - 2026-10-20

### Added
- Windows: recovery after a crash. Unsaved text is kept in storage while you write; at the next start FocusEdit offers to restore it
- Windows: the ⋯ button opens a menu with recent files, Export as HTML…, Print or save as PDF… (`Ctrl+P`) and Copy as HTML. The last document reopens at start
- Windows: outline of headings (`Ctrl+Shift+O`, the list button) with the current heading highlighted; Fountain scripts show scenes and sections
- Windows: theme "System" (now the default) follows the Windows light/dark setting and switches live
- Mac: autosave elsewhere every 60 seconds, so unsaved text survives a crash (the system offers it back at the next launch)

## [1.1.8] - 2026-10-20

### Fixed
- Mac: the preview pane scrolls together with the editor, both ways
- Windows: in Split view scrolling the preview now scrolls the editor too (it only worked the other way round); leaving Preview (`Esc`) puts the caret and the editor where you were reading

## [1.1.7] - 2026-10-20

### Changed
- Windows: only the NSIS `.exe` installer is built; the `.msi` is dropped because installing it on Windows 11 showed warning 1946 (the shortcut's AppUserModel.ID could not be set)

### Security
- Mac preview and HTML export: a link or image address could close its attribute and add an event handler. Quotes are now escaped, addresses are limited to web, mail and relative links (images: web, relative and data:), the preview page runs no scripts, and a clicked web link opens in the browser while every other navigation is cancelled

### Changed
- Mac: the Markdown preview (⇧⌘P, the eye button) is now a pane beside the text inside the window instead of a separate window; it updates while you type without jumping to the top, and links open in the browser

## [1.1.6] - 2026-10-20

### Changed
- Windows: the F1 hints panel has its own View section (`Ctrl+Shift+P`: Edit → Split → Preview)

## [1.1.5] - 2026-10-20

### Added
- Windows: Markdown preview. The View button (`Ctrl+Shift+P`) cycles Edit → Split (live preview next to the editor, scrolling together) → Preview (reading view; `Esc` returns to editing). Headings, emphasis, lists, task lists, quotes, code, tables and links; raw HTML is shown as text, links open in the browser (http/https only), images appear as their alt text
- Windows: drag a `.md`, `.markdown`, `.fountain` or `.txt` file onto the window to open it (asks before discarding unsaved changes; other file types are refused with a message)

## [1.1.4] - 2026-10-20

### Changed
- Windows: the app identifier is now `com.kurein.focusedit` instead of the `com.example…` placeholder (aimed at the MSI warning 1946 about the shortcut's AppUserModel.ID). The WebView profile moves with it, so settings (theme, Vim mode) start from defaults once

## [1.1.3] - 2026-10-20

### Added
- About: developer (Kurein M.N.) and a link to the GitHub page — in the Windows hints panel (F1) and in the Mac About panel (credits)

### Changed
- The Windows version now shares the macOS version number; `update_version.py` updates the Windows files too

## [1.1.2] - 2026-10-20

### Fixed
- Vim mode (Mac): `i` and `a` in Normal mode waited for a text object instead of entering Insert mode (the `where` clause of the `case` applied to `a` only); self-test added

### Added
- Windows port: the Vim learning mode (`windows/src/vim.ts`, `vim-cm.ts`) — a TypeScript port of VimEngine with the coach bar, block cursor, Russian-layout keys and tests (`windows/tests/vim.test.ts`)

## [1.1.1] - 2026-10-19

### Added
- Vim coach bar: an always-visible hint of how to reach the other modes, and an Exit Vim button
- `:novim` / `:vimoff` turn Vim mode off from the keyboard

### Changed
- VIM_GUIDE.md, START_HERE.md: how to turn Vim mode on, switch its modes and get back to the normal editor
- Windows port: vitest 5 (npm audit is clean)

## [1.1.0] - 2026-10-19
### Added
- Учебный Vim-режим (Modus ▸ Vim Mode, кнопка в тулбаре): Normal, Insert, Visual, Visual Line и командная строка; грамматика «оператор + движение» со счётчиками (`d c y > <` с `h j k l w b e W B E ge 0 ^ $ gg G { } f F t T ; , n N`), текстовые объекты (`iw aw ip ap i" a" i' a' i( a( i[ a[ i{ a{`), `x X D C Y s S r ~ J p P u Ctrl-r .`, поиск `/ ?` (smartcase), `:w :q :wq :x :q! :help :N`. Блочный курсор в Normal.
- Учебная панель под текстом: режим, набранные клавиши, пояснение каждой команды, подсказки (например, `5l` после пяти `l`); раздел Vim в шпаргалке ⌘?.
- Русская раскладка в Vim-режиме: команды по физической клавише (как `langmap` в NeoVim), аргументы `f`/`t`/`r` и поиск — как набраны.
- VIM_GUIDE.md — курс из семи уроков с упражнениями (`examples/vim-practice.md`) и переходом в NeoVim; 43 проверки Vim-режима в `--selftest`.

## [1.0.0] - 2026-10-19
### Added
- Экспериментальная Windows-версия в `windows/`: Tauri 2 + CodeMirror 6, логика перенесена из Swift — фокус-подсветка, печатная машинка, серая подсказка, автоскобки, продолжение списков, темы, файлы с сохранением кодировки и переводов строк. Установщики `.msi`/`.exe` собирает GitHub Actions. Описано в README, BUILD.md, START_HERE.md и `windows/BUILD.md`.
- RTF: `.rtf` открывается как Markdown и сохраняется обратно в RTF. Переносятся жирный, курсив, зачёркнутый, заголовки (по размеру), маркированные, нумерованные и вложенные списки, ссылки, моноширинный текст и абзацы с отступом; шрифты, цвета, подчёркивание, картинки и таблицы — нет, и при открытии такого файла появляется предупреждение.
- FocusEdit ▸ Make Default Editor for .txt and .rtf, `FocusEdit --make-default` и `./install.sh --make-default` — FocusEdit открывает `.txt` и `.rtf` по двойному щелчку. Назначается только копия из /Applications.
- `.rtf` в библиотеке и при перетаскивании файлов в окно; проверки RTF ↔ Markdown в `--selftest`.

### Fixed
- В «Открыть с помощью» и Spotlight рядом с установленной FocusEdit появлялись рабочие сборки с тем же именем (`.build/`, тестовая сборка Windows-порта): `install.sh` снимает их с регистрации в Launch Services.

## [0.3.3] - 2026-10-19
### Changed
- Убраны клавиши ⌘0 / ⌘1 / ⌘2 у режимов подсветки — они конфликтовали с пользовательскими сочетаниями. Режимы переключает кнопка-прицел в тулбаре и меню Modus ▸ Focus Highlighting; свою клавишу можно назначить в Системных настройках (START_HERE.md).

## [0.3.2] - 2026-10-19
### Added
- `package.sh` собирает универсальный Release (Apple Silicon и Intel) и DMG `.build/dist/FocusEdit-X.Y.Z.dmg` со ссылкой на «Программы», проверяет подпись и DMG; `--no-dmg` — только приложение, `--open` — открыть DMG.
- `install.sh` ставит DMG в `/Applications`: прежняя копия уходит в Корзину, приложение регистрируется в Launch Services, Dock перезапускается.
- START_HERE.md — как работать в приложении: режимы фокуса, подсказки при наборе, Markdown, CriticMarkup, Fountain, навигация, клавиши, частые проблемы.

### Fixed
- После Save As с другим расширением (например, Untitled → `notes.md`) подсветка, продолжение списков, outline и превью переключаются сразу, без переоткрытия файла.
- Документ из шаблона Markdown или Fountain при сохранении предлагает `.md` / `.fountain`, а не `.txt`.

## [0.3.1] - 2026-10-19
### Added
- Современная оболочка окна: unified toolbar с SF Symbols (Liquid Glass на macOS 26) — библиотека, фокус, typewriter, звук, тема, превью, подсказки, outline; включённый режим подсвечивается акцентным цветом; панель настраивается (View ▸ Customize Toolbar…).
- Подсказки: tooltip с горячей клавишей у каждой кнопки, поповер-шпаргалка Help ▸ FocusEdit Hints (⌘?) под тип документа, плейсхолдер в пустом документе.
- Автодополнение: серое продолжение слова из слов документа и системного словаря (русский и английский); Tab или → — принять, Esc — убрать, ⌥Esc — полный список. Для Fountain — `INT./EXT.` и имена персонажей.
- Автозакрытие скобок и кавычек с оборачиванием выделения; продолжение списков, задач `- [ ]` и цитат по Return (Markdown).
- Полноэкранный режим без отвлечений: тулбар и меню прячутся. Меню Window и Help.
- `--selftest` проверяет дополнение и правку текста; `--snapshot out.png` снимает окно без разрешения на запись экрана (окно невидимо и не забирает фокус; `--theme`, `--content`).
- README.md на английском со скриншотами; `update_version.py` синхронизирует и строку версии в README.

### Changed
- Outline — инспектор справа (macOS 14+); счётчик слов перенесён в подзаголовок окна.
- Действия редактора работают и когда фокус в библиотеке или outline.

### Fixed
- Документ, начинающийся с заголовка, целиком становился жирным: базовый шрифт брался из первого символа.
- `package.sh` подписывает весь бандл ad-hoc и проверяет подпись; раньше был подписан только бинарь, без идентификатора и без печати Info.plist.

## [0.3] - 2026-10-19
### Added
- M6: подсветка CriticMarkup и команды Accept/Reject; меню Edit ▸ Format (Markdown) и CriticMarkup.
- Шаблоны документов (File ▸ New From Template: Markdown, Fountain).
- Печать и экспорт в PDF; экспорт и копирование в HTML.
- Редактор пользовательских тем (View ▸ Theme ▸ Edit Themes…), сохранение в UserDefaults.
- Иконка приложения, рисуемая кодом (`IconFactory`, `--makeicon`).

## [0.2] - 2026-10-18
### Added
- M4: сайдбар-библиотека (папка документов), outline по заголовкам, статистика, Find & Replace.
- M5: живое HTML-превью в WKWebView, экспорт в HTML.
- M2/M3: переход на NSDocument (.txt/.md/.fountain), инкрементальная подсветка Markdown и Fountain.

## [0.1] - 2026-10-18
### Added
- M0/M1: каркас редактора на AppKit + TextKit 1, фокус-колонка, typewriter-scrolling,
  focus-highlighting с плавным fade, темы/размеры/шрифты, звуки печатной машинки, персист настроек.
