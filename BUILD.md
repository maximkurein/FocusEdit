# BUILD — сборка FocusEdit

Как собрать FocusEdit из исходников: приложение, иконку и бандл `.app` для запуска.

Связано: [VERSION_MANAGEMENT.md](VERSION_MANAGEMENT.md) · [implementation-plan.md](../implementation-plan.md) · [00-recon.md](../00-recon.md)

FocusEdit — минималистичный macOS-редактор (Swift + AppKit + TextKit 1), прототип, воссозданный по статической разведке uFocus. Собирается через SwiftPM; `.app`-бандл собирается скриптом поверх `swift build`.

## Что получается

| Что | Чем собирается | Где лежит |
|---|---|---|
| Исполняемый файл (Debug) | `swift build` | `.build/debug/FocusEdit` |
| Бандл `FocusEdit.app` (бинарь + Info.plist + иконка) | `./package.sh` | `.build/FocusEdit.app` |
| Иконка `AppIcon.icns` | `./package.sh` (рендерит сам бинарь) | `.build/FocusEdit.app/Contents/Resources/AppIcon.icns` |

Всё собранное лежит в `.build/` и в git не попадает.

## Требования

- **macOS 13** или новее — минимальная цель приложения (`LSMinimumSystemVersion`).
- **Xcode / Swift toolchain**. Проверено на **Xcode 26.5, Swift 6.3, macOS 26**. Пакет собирается в режиме языка Swift 5 (`swiftLanguageModes: [.v5]` в `Package.swift`), чтобы код на главном потоке AppKit не требовал строгой проверки конкуренции Swift 6.
- Сторонних зависимостей нет — только системные фреймворки (AppKit, WebKit, AVFoundation). Сеть для сборки не нужна.

## Структура

```
FocusEdit/
├── Package.swift            # SwiftPM: executable-таргет FocusEdit, язык Swift 5, macOS 13+
├── Info.plist               # версия, типы документов (.txt/.md/.fountain), иконка
├── package.sh               # status → swift build → собрать .app → номер сборки → иконка
├── CHANGELOG.md             # заметки по версиям (заголовки правит update_version.py)
├── scripts/update_version.py # bump / status / sync — единственный способ менять версию
├── Sources/FocusEdit/*.swift
└── examples/                # welcome.md и превью иконки (для ручного теста)
```

## Шаг 1. Собрать

```bash
cd /Users/olgazaharova/Project/rea-lab/work/uFocus/FocusEdit
./package.sh
```

Что делает `package.sh`:

1. `swift build` — компилирует исполняемый файл в `.build/debug/FocusEdit`.
2. Собирает бандл `.build/FocusEdit.app`: копирует бинарь, кладёт `Info.plist` и `PkgInfo`.
3. Ставит номер сборки `CFBundleVersion` по времени UTC (см. [VERSION_MANAGEMENT.md](VERSION_MANAGEMENT.md)).
4. Рендерит иконку: запускает `FocusEdit --makeicon` (рисует набор PNG кодом из `IconFactory.swift`) и собирает `AppIcon.icns` через `iconutil`.
5. Печатает итог: `Assembled .build/FocusEdit.app (version X.Y, build …)`.

Можно собирать и без скрипта — тогда будет только бинарь, без бандла, иконки и типов документов:

```bash
swift build                 # → .build/debug/FocusEdit
swift build -c release      # релизная сборка
```

## Шаг 2. Запуск

Бандл запускается прямым вызовом внутреннего бинаря. При прямом запуске `Bundle.main` всё равно указывает на `.app`, поэтому `Info.plist`, типы документов и иконка подхватываются.

```bash
# пустой документ
.build/FocusEdit.app/Contents/MacOS/FocusEdit

# открыть файл сразу
.build/FocusEdit.app/Contents/MacOS/FocusEdit "$PWD/examples/welcome.md"

# остановить
pkill -f FocusEdit
```

> **Почему не `open`.** В этой лаборатории `open` и запись в глобальные конфиги запрещены правилами проекта (`.claude/settings.json`, `CLAUDE.md`), поэтому бандл запускается напрямую. Вне лаборатории `open .build/FocusEdit.app` тоже работает.

Команды проекта с относительными путями (`./package.sh`, `.build/...`) работают только из каталога проекта — сначала `cd` в него либо используйте абсолютные пути.

## Шаг 3. Проверки

Движок подсветки проверяется без GUI — встроенный self-test токенизирует образцы Markdown и Fountain и печатает роли:

```bash
.build/FocusEdit.app/Contents/MacOS/FocusEdit --selftest
```

Ручная проверка GUI: открыть `examples/welcome.md`, подвигать каретку (фокус-подсветка и typewriter-scrolling), ⌘S сохранить, ⌘F поиск, View ▸ Theme/Editor Size, ⇧⌘P превью, Edit ▸ Format/CriticMarkup.

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
open "$TMP/icon_256x256.png"   # вне лаборатории
```

После правки рисунка просто пересоберите `./package.sh`.

## Частые проблемы

**`no such file or directory: ./package.sh`** — вы не в каталоге проекта. Сделайте `cd` в `…/work/uFocus/FocusEdit` или запускайте по абсолютному пути.

**`sandbox-exec: sandbox_apply: Operation not permitted` / недоступен кэш SwiftPM** — песочница мешает `swift build`. В Claude Code это снимается разрешением на команду; вне — запускайте сборку в обычной оболочке. Управление песочницей — `/sandbox`.

**Окно не появляется, только иконка в Dock** — исправлено: после назначения `contentViewController` окну явно задаётся размер и центрирование (иначе оно схлопывалось до полоски заголовка, и это запоминалось в настройках). Если всплывёт старый кривой frame: `defaults delete com.example.focusedit`.

**`iconutil failed`** — `package.sh` продолжит сборку, приложение получит системную иконку по умолчанию. Проверьте, что `FocusEdit --makeicon` создал все 10 PNG в iconset.

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
cd /Users/olgazaharova/Project/rea-lab/work/uFocus/FocusEdit && claude

# Продолжить последнюю сессию с полным контекстом
claude --continue

# Выбрать одну из прошлых сессий для восстановления
claude --resume

# Запуск с явным указанием модели
claude --model claude-opus-5-5
```

> Сессия, запущенная в `work/uFocus/FocusEdit`, не подхватит `.mcp.json` лаборатории — инструменты REA будут недоступны. Для реверса запускайте `claude` из корня `rea-lab`.

### 3. Контроль сборки и процессов

```bash
# Полная сборка бандла: проверка версии, UTC-номер сборки, иконка
./package.sh

# Быстрая компиляция отладочной версии через SwiftPM
swift build

# Остановка запущенного FocusEdit перед пересборкой
# (совпадает и с бандлом .app, и с .build/debug/FocusEdit)
pkill -f FocusEdit
```

## Правило

Бандл для запуска собираем только `./package.sh`; версию меняем только в `Info.plist` (см. [VERSION_MANAGEMENT.md](VERSION_MANAGEMENT.md)). Перед запуском GUI — пересборка, затем прямой вызов бинаря бандла.
