# BUILD — сборка FocusEdit

Как собрать FocusEdit из исходников: приложение, DMG для установки и установка в «Программы».

Связано: [START_HERE.md](START_HERE.md) · [VERSION_MANAGEMENT.md](VERSION_MANAGEMENT.md) · [implementation-plan.md](../implementation-plan.md) · [00-recon.md](../00-recon.md)

FocusEdit — минималистичный macOS-редактор (Swift + AppKit + TextKit 1), прототип; вдохновлён редакторами без отвлечений вроде uFocus, написан с нуля. Собирается через SwiftPM; `.app`-бандл собирается скриптом поверх `swift build`.

## Что получается

| Что | Чем собирается | Где лежит |
|---|---|---|
| Исполняемый файл Debug (быстрая проверка компиляции) | `swift build` | `.build/debug/FocusEdit` |
| Приложение Release (универсальное: Apple Silicon и Intel) | `./package.sh` | `build/FocusEdit.app` |
| DMG для установки | `./package.sh` | `build/FocusEdit-X.Y.Z.dmg` |
| Установленное приложение | `./install.sh` | `/Applications/FocusEdit.app` |

Компилятор Swift кладёт служебные файлы в скрытую `.build/` (так устроен SwiftPM, Finder её не показывает). Готовое приложение и DMG скрипт складывает в обычную `build/` — её видно в Finder, приложение открывается двойным щелчком. В git не попадает ни то, ни другое.

## Требования

- **macOS 13** или новее — минимальная цель приложения (`LSMinimumSystemVersion`).
- **Xcode / Swift toolchain**. Проверено на **Xcode 26.5, Swift 6.3, macOS 26**. Пакет собирается в режиме языка Swift 5 (`swiftLanguageModes: [.v5]` в `Package.swift`), чтобы код на главном потоке AppKit не требовал строгой проверки конкуренции Swift 6.
- Сторонних зависимостей нет — только системные фреймворки (AppKit, WebKit, AVFoundation). Сеть для сборки не нужна.

## Структура

```
FocusEdit/
├── Package.swift            # SwiftPM: executable-таргет FocusEdit, язык Swift 5, macOS 13+
├── Info.plist               # версия, типы документов (.txt/.md/.fountain), иконка
├── package.sh               # status → Release arm64+x86_64 → .app → номер сборки → иконка → подпись → DMG
├── install.sh               # DMG → /Applications, регистрация в Launch Services, перезапуск Dock
├── README.md                # описание на английском; строку версии правит update_version.py
├── START_HERE.md            # как работать в приложении: режимы, подсказки, приёмы, клавиши
├── VIM_GUIDE.md             # учебный курс по Vim-режиму: уроки, упражнения, переход в NeoVim
├── CHANGELOG.md             # заметки по версиям (заголовки правит update_version.py)
├── docs/images/             # скриншоты для README (--snapshot)
├── scripts/update_version.py # bump / status / sync — единственный способ менять версию
├── Sources/FocusEdit/*.swift
├── examples/                # welcome.md, vim-practice.md (упражнения к VIM_GUIDE) и превью иконки
├── windows/                 # Windows-версия (эксперимент): Tauri 2 + CodeMirror 6
└── .github/workflows/windows.yml  # сборка Windows-установщиков в GitHub Actions
```

## Шаг 1. Собрать

```bash
cd FocusEdit            # каталог, куда вы клонировали репозиторий
./package.sh            # → build/FocusEdit.app и build/FocusEdit-X.Y.Z.dmg
./package.sh --no-dmg   # только приложение — быстрее, пока идёт разработка
./package.sh --open     # ещё и открыть DMG в Finder
```

Что делает `package.sh`:

1. Отказывается собирать, если версии разошлись (`update_version.py status`).
2. Собирает Release для arm64 и x86_64 (`swift build -c release --arch arm64 --arch x86_64`) — журнал в `.build/release-build.log`.
3. Собирает бандл `build/FocusEdit.app` заново: бинарь, `Info.plist`, `PkgInfo`.
4. Ставит номер сборки `CFBundleVersion` по времени UTC (см. [VERSION_MANAGEMENT.md](VERSION_MANAGEMENT.md)).
5. Рендерит иконку: `FocusEdit --makeicon` рисует PNG кодом из `IconFactory.swift`, `iconutil` собирает `AppIcon.icns`.
6. Подписывает бандл ad-hoc (`codesign --sign -`) и проверяет подпись (`codesign --verify --deep --strict`) и номер сборки — так `Info.plist` и иконка запечатаны, а повреждённый бандл ломается на сборке, а не при запуске.
7. Собирает DMG со ссылкой на «Программы» и проверяет его (`hdiutil verify`).

В конце печатает строку вида `Created build/FocusEdit-0.3.1.dmg (928K, version 0.3.1, build 20261019.175426, x86_64 arm64)`.

Только проверить, что код компилируется, — без бандла, иконки и типов документов:

```bash
swift build                 # → .build/debug/FocusEdit
```

## Шаг 2. Установка в «Программы»

```bash
./install.sh            # поставить build/FocusEdit-X.Y.Z.dmg
./install.sh <dmg>      # поставить другой DMG
./install.sh --make-default   # и сделать FocusEdit программой по умолчанию для .txt и .rtf
```

Программу по умолчанию можно назначить и позже: в приложении **FocusEdit ▸ Make Default Editor for .txt and .rtf** или `/Applications/FocusEdit.app/Contents/MacOS/FocusEdit --make-default`. Назначается только копия из `/Applications` — иначе `.txt` привязался бы к сборке в `.build/`, которая пропадает при пересборке.

`install.sh` закрывает запущенный FocusEdit (если есть несохранённые изменения, приложение спросит, сохранить ли, — ответьте и запустите `install.sh` ещё раз), перекладывает прежнюю копию в Корзину (ничего не удаляет), копирует новую из DMG и проверяет её подпись, заново регистрирует в Launch Services, «забывает» копии в Корзине, перезапускает Dock и открывает приложение. Без этого Dock может показывать старую или пустую иконку из кэша.

Вручную: откройте DMG (`./package.sh --open`) и перетащите **FocusEdit** в **Applications**. Dock при этом не обновится.

После установки FocusEdit запускается как обычное приложение: Launchpad, Spotlight, Dock, «Открыть с помощью» для `.md`, `.fountain` и `.txt`.

## Запуск без установки

Пока идёт разработка, собранный бандл можно запускать прямо из `build/` — вызовом внутреннего бинаря. `Bundle.main` всё равно указывает на `.app`, поэтому `Info.plist`, типы документов и иконка подхватываются.

```bash
# пустой документ
build/FocusEdit.app/Contents/MacOS/FocusEdit

# открыть файл сразу
build/FocusEdit.app/Contents/MacOS/FocusEdit "$PWD/examples/welcome.md"

# остановить
pkill -f FocusEdit
```

> Обычный способ — `open build/FocusEdit.app` или двойной щелчок в Finder; вызов внутреннего бинаря удобен, когда нужно видеть вывод в терминале.

Команды проекта с относительными путями (`./package.sh`, `build/...`) работают только из каталога проекта — сначала `cd` в него либо используйте абсолютные пути.

## Шаг 3. Проверки

Логика проверяется без GUI — встроенный self-test токенизирует образцы Markdown и Fountain, проверяет автодополнение и правку текста (продолжение списков, автоскобки, принятие подсказки) и выходит с кодом 1 при любой ошибке:

```bash
build/FocusEdit.app/Contents/MacOS/FocusEdit --selftest
```

Снимок окна без разрешения на запись экрана: открывает документ, печатает демо-строку (список + серая подсказка), сохраняет PNG и закрывается, демо-ввод не сохраняется:

```bash
build/FocusEdit.app/Contents/MacOS/FocusEdit "$PWD/examples/welcome.md" --snapshot "$TMPDIR/ui.png"
```

Окно снимка невидимо и не забирает фокус клавиатуры. `--theme Dark` задаёт тему только для снимка, `--content` оставляет область под тулбаром — стеклянный тулбар в тёмной теме вне экрана не рендерится. Скриншоты README обновляются так:

```bash
APP=build/FocusEdit.app/Contents/MacOS/FocusEdit
$APP "$PWD/examples/welcome.md" --snapshot "$PWD/docs/images/window-light.png" --theme Light
$APP "$PWD/examples/welcome.md" --snapshot "$PWD/docs/images/editor-dark.png" --theme Dark --content
```

Ручная проверка GUI: открыть `examples/welcome.md`, подвигать каретку (фокус-подсветка и typewriter-scrolling), ⌘S сохранить, ⌘F поиск, View ▸ Theme, ⌥⌘P превью (Edit → Split → Preview), Edit ▸ Format/CriticMarkup.

## Шаг 4. Версия — перед релизом

Версия MAJOR.MINOR.PATCH живёт в `Info.plist` и меняется только скриптом `scripts/update_version.py` — подробно в [VERSION_MANAGEMENT.md](VERSION_MANAGEMENT.md):

```bash
python3 scripts/update_version.py bump patch
python3 scripts/update_version.py status
```

`package.sh` сам вызывает `status` в начале и **откажется собирать**, если версии в `Info.plist` и `CHANGELOG.md` разошлись.

## Иконка

Иконка нарисована кодом в `Sources/FocusEdit/IconFactory.swift` (приглушённые строки текста, одна яркая «сфокусированная» строка и янтарная каретка). PNG-ассеты в репозитории не хранятся — их рендерит сам бинарь во время `package.sh`. Посмотреть результат без сборки бандла:

```bash
TMP="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$TMP"
.build/debug/FocusEdit --makeicon "$TMP"
open "$TMP/icon_256x256.png"
```

После правки рисунка просто пересоберите `./package.sh`.

## Windows (эксперимент)

В папке `windows/` есть экспериментальная Windows-версия. Это отдельное приложение на Tauri 2 (Rust) и CodeMirror 6 (TypeScript): AppKit под Windows нет, поэтому интерфейс написан заново, а логика (фокус, печатная машинка, подсказки, автоскобки, списки, Vim-режим) перенесена из Swift; превью, outline, недавние файлы, экспорт и восстановление после сбоя написаны заново. Подробно — [windows/BUILD.md](windows/BUILD.md).

```bash
cd windows
npm install                 # один раз
npm test                    # проверки логики
npm run build               # типы + сборка интерфейса
npm run tauri -- build --bundles app   # на macOS: проверить, что Rust-часть собирается
```

Установщик `.exe` (NSIS) собирает GitHub Actions на Windows при пуше в `main`, затрагивающем `windows/` (`.github/workflows/windows.yml`): **Actions** → последний запуск → артефакт **FocusEdit-windows**. На Mac их не собрать.

Версия у Windows-порта общая с macOS: `update_version.py` меняет и `windows/package.json`, `package-lock.json`, `tauri.conf.json`, `Cargo.toml`, `Cargo.lock`.

## Частые проблемы

**`no such file or directory: ./package.sh`** — вы не в каталоге проекта. Сделайте `cd` в каталог репозитория или запускайте по абсолютному пути.

**`sandbox-exec: sandbox_apply: Operation not permitted` / недоступен кэш SwiftPM** — песочница мешает `swift build`. В Claude Code это снимается разрешением на команду; вне — запускайте сборку в обычной оболочке. Управление песочницей — `/sandbox`.

**Окно не появляется, только иконка в Dock** — исправлено: после назначения `contentViewController` окну явно задаётся размер и центрирование (иначе оно схлопывалось до полоски заголовка, и это запоминалось в настройках). Если всплывёт старый кривой frame: `defaults delete com.kurein.focusedit`.

**Приложение сразу падает: `SIGKILL (Code Signature Invalid)`, `Taskgated Invalid Signature`** — исполняемый файл внутри бандла перезаписали на месте (например, `cp .build/debug/FocusEdit build/FocusEdit.app/Contents/MacOS/`). macOS кэширует проверку подписи файла, и подменённый Mach-O ядро убивает при запуске. Не копируйте бинарь в бандл руками — пересоберите `./package.sh`: он удаляет бандл целиком, собирает и подписывает заново.

**`package failed: iconutil could not build AppIcon.icns`** — проверьте, что `FocusEdit --makeicon` создаёт все 10 PNG в iconset.

**`package failed: swift build failed`** — первая строка с `error:` уже напечатана; полный журнал — `.build/release-build.log`.

**`install failed: FocusEdit is still running`** — в открытом документе есть несохранённые изменения, и приложение ждёт ответа. Сохраните или закройте документы и запустите `./install.sh` снова.

**В «Открыть с помощью» или Spotlight несколько FocusEdit** — система регистрирует каждую найденную копию: `build/FocusEdit.app`, тестовую сборку Windows-порта, копии в Корзине. `./install.sh` снимает их с регистрации, оставляя `/Applications/FocusEdit.app`. Вручную:

```bash
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSR -dump | grep -E '^path:.*FocusEdit'      # какие копии знает система
$LSR -u "$PWD/build/FocusEdit.app"            # забыть одну
```

**В Dock старая или пустая иконка** — ставьте через `./install.sh`: он перезапускает Dock. Если иконка всё равно старая:

```bash
touch /Applications/FocusEdit.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/FocusEdit.app
killall Dock
```

**Ошибки сборки после правки структуры** — убедитесь, что новые файлы лежат в `Sources/FocusEdit/`; SwiftPM забирает всю папку таргета автоматически (перегенерация проекта не нужна — Xcode-проекта тут нет).

## Управление сессией, моделями и сборкой (Cheat Sheet)

### 1. Команды внутри чата Claude Code

* `/model` — переключение модели на лету (например, `claude-sonnet-5-5` для повседневной разработки, `claude-opus-5-5` для сложного реверс-инжиниринга).
* `/cost` — статистика по потраченным токенам сессии и Prompt Caching.
* `/config` — настройки сессии (режим мышления, автоподтверждения, режимы по умолчанию).
* `/sandbox` — просмотр и переключение прав песочницы (выход за пределы рабочей директории).

### 2. Запуск и восстановление сессий из терминала macOS

```bash
# Запуск сессии в папке проекта
cd FocusEdit && claude

# Продолжить последнюю сессию с полным контекстом
claude --continue

# Выбрать одну из прошлых сессий для восстановления
claude --resume

# Запуск с явным указанием модели
claude --model claude-opus-5-5
```

### 3. Контроль сборки и процессов

```bash
# Полная сборка: проверка версии, Release, UTC-номер сборки, иконка, подпись, DMG
# (./install.sh — поставить DMG в «Программы»)
./package.sh

# Быстрая компиляция отладочной версии через SwiftPM
swift build

# Остановка запущенного FocusEdit перед пересборкой
# (совпадает и с бандлом .app, и с .build/debug/FocusEdit)
pkill -f FocusEdit
```

## Правило

Приложение и DMG собираем только `./package.sh`, ставим в «Программы» только `./install.sh`; версию меняем только `scripts/update_version.py` (см. [VERSION_MANAGEMENT.md](VERSION_MANAGEMENT.md)). Бинарь в бандл руками не копируем.
