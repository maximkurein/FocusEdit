# Changelog

Все заметные изменения FocusEdit. Формат — [Keep a Changelog](https://keepachangelog.com/),
версии — [Semantic Versioning](https://semver.org/). Заголовки правит
`scripts/update_version.py`; текст заметок пишется руками.

## [Unreleased]

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
