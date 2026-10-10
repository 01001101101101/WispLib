# Пример: помехи сигнала

Небольшой пример экранного эффекта для WispLib 0.4.0 и VoxelCore 0.32. Помехи немного искажают изображение, добавляют зерно и короткие сбои. При ходьбе они становятся заметнее, при прыжке дают короткий импульс.

Это обычный content pack: движок выполняет GLSL-постобработку, а Lua передаёт ей параметры игрока через `vfx.screen`. Частицы и Entity не создаются.

## Установка

Скопируйте папку `wisplib_signal_demo` в `content/` проекта VoxelCore. В `project.toml` включите паки:

```toml
base_packs = ["base", "wisplib", "wisplib_signal_demo"]
```

Если `base_packs` уже содержит другие паки, добавьте `wisplib_signal_demo` к существующему списку. Запустите клиентский мир и походите или попрыгайте. При закрытии HUD эффект удаляется.

## Настройка

- В `scripts/hud.lua` найдите таблицу профиля в `vfx.screen.register`: `noise`, `tearing` и `vignette` задают вид эффекта, `motion` и `jump` управляются скриптом.
- В `shaders/effects/radio_interference.glsl` можно изменить форму и движение помех.
- Не переименовывайте alias `wisplib_signal_demo_radio`, пока не обновите его одновременно в `preload.json` и профиле.

Профиль зарегистрирован из Lua через `vfx.screen.register`, поэтому отдельный JSON-файл для него не нужен. Слот и GLSL asset всё равно объявлены ресурсами content pack.

## Состав

```text
wisplib_signal_demo/
├── package.json
├── content.json
├── resources.json
├── preload.json
├── scripts/hud.lua
└── shaders/effects/radio_interference.glsl
```
