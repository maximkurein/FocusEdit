# FocusEdit для Windows — эксперимент

Экспериментальная Windows-версия в папке `windows/`. Та же идея, что у macOS-версии: строка по центру, всё неактивное приглушено, файл на диске — простой текст. Но интерфейс написан заново: AppKit и TextKit есть только на macOS.

Связано: [../BUILD.md](../BUILD.md) (macOS) · [../START_HERE.md](../START_HERE.md) · [../CHANGELOG.md](../CHANGELOG.md)

## На чём сделано

| Слой | Что | Зачем |
|---|---|---|
| Оболочка | [Tauri 2](https://tauri.app) (Rust) | нативное окно на системном WebView2; установщик ~5–10 МБ |
| Редактор | [CodeMirror 6](https://codemirror.net) (TypeScript) | декорации для фокуса, продолжение списков, автоскобки, поиск — из коробки |
| Rust-часть | `src-tauri/src/lib.rs` | чтение/запись файлов, файл из командной строки («Открыть с помощью») и открытие `http(s)`-ссылки в браузере |

Логика перенесена из macOS-версии:

| macOS (Swift) | Windows (TypeScript) |
|---|---|
| `CompletionEngine.swift` | `src/completion.ts` |
| `FocusTextView` — фокус и печатная машинка | `src/focus.ts` |
| `FocusTextView` — серая подсказка | `src/ghost.ts` |
| `Theme.swift`, `Preferences.swift` | `src/themes.ts`, `src/settings.ts` |
| `HintsViewController.swift` | `src/hints.ts` |
| `FocusDocument` + меню | `src/main.ts`, `src/platform.ts` |
| `VimEngine.swift` | `src/vim.ts` (движок), `src/vim-cm.ts` (клавиши, блочный курсор, учебная панель) |
| `MarkdownToHTML.swift`, панель превью | `src/markdown-html.ts` (на дереве разбора CodeMirror), панель в `src/main.ts` |
| `OutlineViewController.swift` | `src/outline.ts` |
| Open Recent, автосохранение NSDocument | `src/recent.ts`, `src/draft.ts` |
| экспорт HTML, печать | `src/export.ts`, всплывающее меню — `src/menu.ts` |

## Что уже работает (этап 2)

- Фокус-подсветка по предложению или абзацу с плавным угасанием — кнопка-прицел в тулбаре (горячих клавиш нет).
- Печатная машинка: строка держится по центру окна (**Ctrl+T**).
- Подсветка Markdown (GFM: задачи, зачёркивание); метки `#`, `*`, `-` приглушены.
- Серая подсказка слова из документа: **Tab** / **→** — принять, **Esc** — убрать, **Ctrl+Space** — список. В Fountain — `INT.`/`EXT.` и имена персонажей.
- Автоскобки `( [ { " ` «` с оборачиванием выделения; продолжение списков, задач и цитат по Enter.
- **Ctrl+B / I / K** — жирный, курсив, ссылка; **Ctrl+F** — поиск и замена.
- Темы System / Light / Dark / Sepia, ширина колонки, шрифт, размер (**Ctrl+= / Ctrl+−**), полный экран (**F11**), шпаргалка (**F1**).
- Файлы: **Ctrl+N / O / S / Shift+S**; сохраняются BOM и переводы строк (CRLF/LF); «Save As» в `.md` сразу включает Markdown; при закрытии с несохранёнными изменениями — вопрос. Файл можно перетащить на окно.
- **Vim-режим** (кнопка Vim): те же команды и учебная панель, что на Mac; см. [../VIM_GUIDE.md](../VIM_GUIDE.md).
- **Превью Markdown** (кнопка с глазом, **Ctrl+Shift+P**): Edit → Split → Preview; в Split панели прокручиваются вместе, **Esc** выходит из Preview. HTML-вставки показываются как текст, ссылки открываются в браузере только по `http(s)`, картинки заменены подписью.
- **Outline** (**Ctrl+Shift+O**): заголовки Markdown или сцены и секции Fountain, текущий пункт подсвечен.
- **Кнопка ⋯**: недавние файлы (10 штук), Export as HTML, Print or save as PDF (**Ctrl+P**), Copy as HTML. При запуске без файла открывается последний документ.
- **Восстановление после сбоя:** пока есть несохранённые изменения, их копия лежит в localStorage профиля WebView (обновляется через 1,5 с после правки); после аварийного закрытия при запуске предлагается вернуть текст. Нормальное закрытие, сохранение и «Discard» копию удаляют. Тест: набрать текст, завершить процесс в диспетчере задач, запустить снова.
- Тема **System** (по умолчанию) следует настройке Windows и переключается вживую.
- В подсказках (**F1**) внизу: версия, разработчик и ссылка на GitHub.
- Установщик регистрирует `.md`, `.fountain`, `.txt` для «Открыть с помощью».

**Ещё нет (этап 2):** библиотека, outline, превью и экспорт HTML/PDF, подсветка Fountain, CriticMarkup, звуки печатной машинки, словарные подсказки (в WebView нет доступа к системному словарю).

## Сборка

Нужны Node.js 22+ и Rust (stable). На Windows Tauri дополнительно требует Microsoft C++ Build Tools и WebView2 (в Windows 11 уже есть).

```bash
cd windows
npm install                 # зависимости — локально в windows/node_modules
npm test                    # проверки логики без окна (vitest)
npm run build               # проверка типов + сборка интерфейса в dist/
npm run tauri -- dev        # запустить приложение в режиме разработки
npm run tauri -- build      # установщики: src-tauri/target/release/bundle/nsis
```

На macOS `npm run tauri -- build --bundles app` собирает `.app` — так проверяется, что Rust-часть компилируется, и интерфейс можно погонять в настоящем окне.

**Windows-установщики собирает GitHub Actions** (`.github/workflows/windows.yml`) на Windows-машине при каждом пуше в `main`, затрагивающем `windows/`: вкладка **Actions** → последний запуск → артефакт **FocusEdit-windows** (`.exe`). Собрать их на Mac нельзя: нужен Windows-тулчейн.

## Скриншот без Tauri

Интерфейс работает и в обычном браузере (файлы тогда открываются через выбор файла и сохраняются скачиванием). Скриншот в установленном Google Chrome:

```bash
npm run build
npm run snapshot -- ../docs/images/windows-light.png
npm run snapshot -- --theme Dark ../docs/images/windows-dark.png
```

## Правило

Логику держим в паре с macOS-версией: меняя поведение в одной, переносим и в другую. Версия общая с macOS: её меняет только `scripts/update_version.py` из корня репозитория (он правит `package.json`, `package-lock.json`, `tauri.conf.json`, `Cargo.toml`, `Cargo.lock`); в приложении она видна в About внизу подсказок (F1).
