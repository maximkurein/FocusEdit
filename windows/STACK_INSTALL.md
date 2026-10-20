# STACK_INSTALL — что стоит под сборкой Windows-версии

Пояснение к [BUILD.md](BUILD.md): из каких слоёв состоит стек и что происходит при каждой команде. Версия FocusEdit для Windows — это Tauri 2 (Rust) + CodeMirror 6 (TypeScript).

## 1. Стек: что нужно поставить и зачем

| Слой | Что это | Зачем |
|---|---|---|
| **Node.js + npm** | Среда выполнения JavaScript и менеджер пакетов | Ставит зависимости интерфейса (`node_modules`), запускает Vite, vitest и CLI `tauri` |
| **Rust toolchain** (`rustup`, `cargo`) | Компилятор и сборщик Rust | Собирает нативную оболочку приложения (`src-tauri/`): окно, файлы, диалоги |
| **MSVC (Visual Studio C++ Build Tools)** | Компилятор и компоновщик Microsoft | Rust на Windows (`x86_64-pc-windows-msvc`) использует его для линковки `.exe`. Нужен компонент «Разработка классических приложений на C++» |
| **Microsoft WebView2** | Системный движок на базе Chromium | Рисует интерфейс (HTML/CSS/JS) внутри окна |

Как они связаны:

- **Интерфейс** (`src/`) — TypeScript + CodeMirror 6, собирается Vite в статику `dist/`.
- **Rust-ядро** (`src-tauri/src/lib.rs`) — доступ к файловой системе, диалогам и окну Windows.
- **WebView2** показывает интерфейс. В отличие от Electron, Tauri не вшивает Chromium в каждое приложение, а использует WebView2, который уже есть в Windows 10/11. Поэтому установщик получается в разы меньше (порядка единиц–десятков МБ, а не 150 МБ+) и приложение скромнее по памяти.
- Если WebView2 на машине нет, установщик скачает его сам: в `tauri.conf.json` задано `webviewInstallMode: downloadBootstrapper` (при установке нужен интернет).

Установка зависимостей один раз: Node.js LTS, `rustup` (профиль MSVC), Visual Studio Build Tools с C++.

## 2. Команды по шагам

Все команды — из папки `windows/`.

```powershell
cd C:\Project\FocusEdit\windows
npm install
npm test
npm run tauri -- dev
npm run tauri -- build
```

### `npm install`

Читает `package.json` / `package-lock.json` и скачивает библиотеки в `node_modules/`: CodeMirror, Vite, TypeScript, vitest, playwright-core и `@tauri-apps/cli` (даёт команду `tauri`). Rust-зависимости здесь не ставятся: их `cargo` скачает при первой сборке (по `src-tauri/Cargo.lock`). Выполняется один раз и повторно — после изменения зависимостей.

### `npm test`

Запускает `vitest run`: тесты чистой логики из `tests/` (`completion.test.ts`, `editing.test.ts`) в окружении Node, без окна и без Rust. Это быстрая проверка того, что логика подсказок, автоскобок и списков не сломана. Один файл: `npx vitest run tests/editing.test.ts`.

### `npm run tauri -- dev` — режим разработки

Двойное `--` нужно, чтобы флаги ушли в `tauri`, а не в npm. Что происходит:

1. По `beforeDevCommand` запускается `npm run dev` — dev-сервер Vite на `http://localhost:1420`.
2. `cargo` собирает Rust-часть в отладочном режиме (первый раз долго — скачиваются и компилируются все crate'ы, потом быстро, с кэшем в `src-tauri/target/`).
3. Открывается окно с WebView2, которое загружает страницу с dev-сервера. Интерфейс и Rust общаются через IPC Tauri (вызовы команд из JS в Rust, сообщения сериализуются в JSON).
4. Правки в `src/*.ts` и `src/styles.css` подхватывает Vite (hot reload). Правки в `src-tauri/*.rs` приводят к перекомпиляции Rust и перезапуску окна — мгновенного обновления тут нет.

Файлы Swift (`Sources/`) к Windows-версии не относятся и на неё не влияют.

Интерфейс можно разрабатывать и без Rust: `npm run dev` открывает его в обычном браузере, а `src/platform.ts` подставляет браузерные замены файлам и диалогам.

### `npm run tauri -- build` — релизная сборка

1. По `beforeBuildCommand` выполняется `npm run build`: проверка типов (`tsc --noEmit`) и `vite build` → минифицированная статика в `dist/`.
2. `cargo build --release` с настройками из `Cargo.toml`: `lto = true`, `codegen-units = 1`, `opt-level = "s"` (компактный размер), `strip = true` (без отладочных символов). Статика `dist/` встраивается в `.exe`.
3. Упаковка в установщик (`"targets": ["nsis"]`): **NSIS** (`.exe`, мастер «Далее → Далее → Готово»). MSI (WiX) отключён: при его установке Windows 11 показывала предупреждение 1946 про `AppUserModel.ID` ярлыка. Если нужен MSI для корпоративного развёртывания, верните `"targets": "all"`. Инструмент NSIS Tauri скачивает сам при первой сборке.

Результат:

```
src-tauri\target\release\FocusEdit.exe                 # сам исполняемый файл (без установщика)
src-tauri\target\release\bundle\nsis\*.exe             # установщик NSIS
```

Установщики на Windows также собирает GitHub Actions (`.github/workflows/windows.yml`): `npm ci` → `npm test` → `tauri build` → артефакт **FocusEdit-windows**.

## 3. Типичные проблемы

- **`link.exe not found` / `linker 'link.exe' not found`** — не установлены Build Tools с компонентом C++.
- **`cargo` / `rustc` не найден** — установите Rust через `rustup` и откройте новый терминал, чтобы обновился `PATH`.
- **Пустое окно или «localhost refused»** в `dev` — порт 1420 занят (в `vite.config.ts` стоит `strictPort`); освободите порт.
- **Первая сборка Rust очень долгая** — это нормально, дальше используется кэш.
