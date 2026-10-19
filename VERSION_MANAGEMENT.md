# Управление версиями

Как FocusEdit хранит версию, как её менять и какие файлы держатся в согласии.

Связано: [BUILD.md](BUILD.md) · [CHANGELOG.md](CHANGELOG.md) · [implementation-plan.md](../implementation-plan.md)

## Источник правды

Версия в формате **MAJOR.MINOR.PATCH** ([Semantic Versioning](https://semver.org/)) живёт только в `Info.plist`:

```xml
<key>CFBundleShortVersionString</key>
<string>X.Y.Z</string>
```

- **MAJOR** — несовместимые изменения: другой формат сохранения, другое поведение документов.
- **MINOR** — новая возможность без поломки старого: новый майлстоун из [implementation-plan.md](../implementation-plan.md) (библиотека, превью, CriticMarkup и т.п.).
- **PATCH** — исправления без новых возможностей.

`package.sh` кладёт `Info.plist` в бандл как есть, поэтому `CFBundleShortVersionString` сразу становится версией приложения — её же показывает Finder (Get Info) и окно About.

## Команды

`scripts/update_version.py` использует только стандартную библиотеку Python; виртуальное окружение не нужно.

| Команда | Версия | Дата релиза |
|---|---|---|
| `status` | показывает каждый файл; код выхода 1, если что-то разошлось | — |
| `bump patch\|minor\|major` | следующая по semver | сегодня |
| `sync X.Y.Z` | ставит `X.Y.Z` | сегодня |
| `sync` | заново раскладывает текущую версию источника | сегодня |

Флаги для `bump` и `sync`: `--release-date YYYY-MM-DD`, `--dry-run` (показать, что изменится, ничего не записывая).

```bash
python3 scripts/update_version.py status
python3 scripts/update_version.py bump patch
python3 scripts/update_version.py sync 0.4.0 --dry-run
```

`bump` и `sync` сначала печатают цель, потом каждый изменённый файл:

```text
Target version:      0.3.1
Target release date: 2026-10-19

Updated Info.plist
Updated CHANGELOG.md
Updated README.md
```

## Что синхронизирует скрипт

| Метка в `status` | Файл | Что меняется |
|---|---|---|
| `source` | `Info.plist` | `CFBundleShortVersionString` |
| `changelog` | `CHANGELOG.md` | заголовок `## [X.Y.Z] - YYYY-MM-DD`: новая версия забирает заметки из `## [Unreleased]`, сверху появляется пустой `Unreleased` |
| `readme` | `README.md` | строка ``**Version:** `X.Y.Z`, released DD.MM.YYYY`` под описанием |

Текст заметок в CHANGELOG пишется руками; скрипт трогает только заголовки.

## Номер сборки

`CFBundleVersion` — **не часть semver**. `package.sh` при каждой сборке ставит его по времени UTC, например `20261019.051248`. Так macOS не путает новую сборку той же версии со старой: иначе Dock и Launch Services могут показать старую иконку из кэша. В окне About номер сборки стоит в скобках. Руками этот ключ менять не нужно — его перезаписывает каждая сборка.

## Порядок релиза

1. Поднять версию:
   ```bash
   python3 scripts/update_version.py bump patch
   ```
2. Дописать в `CHANGELOG.md` заметки под новой версией (скрипт уже перенёс туда всё из `Unreleased`).
3. Проверить, что ничего не разошлось:
   ```bash
   python3 scripts/update_version.py status
   ```
4. Собрать: `./package.sh`. Он **откажется собирать**, если `status` не `OK`, а в конце напечатает `Assembled … (version X.Y.Z, build …)`.

## Если что-то не так

**`status` показывает `DIFF`** — версию в `CHANGELOG.md` или `Info.plist` поправили руками. Запустите `sync`: он оставит версию из `Info.plist` и дату «сегодня».

**`status` показывает `MISSING` у `changelog`** — в `CHANGELOG.md` нет заголовка текущей версии (есть только `[Unreleased]`). `sync` создаст его из `## [Unreleased]`.

**`error: Could not update …`** — строку, которую ищет скрипт, переформатировали. Верните вид из таблицы выше и запустите `sync` ещё раз. Скрипт сначала готовит все изменения и только потом пишет файлы.

**В приложении старая версия** — пересоберите `./package.sh` и проверьте `status`. Версия берётся из `Info.plist` в корне проекта, а не из копии внутри `.build/`.

## Правило

Версию меняем только через `scripts/update_version.py` — никогда поиском и заменой по репозиторию. Источник правды — `Info.plist` (`CFBundleShortVersionString`). Номер сборки (`CFBundleVersion`) не трогаем руками — его ставит `package.sh`. Перед сборкой всегда `status`.
