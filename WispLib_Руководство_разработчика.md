# WispLib: первый эффект в своём content pack

Это руководство показывает полный путь: подключить WispLib, описать эффект, запустить его в игре и затем изменить. В примере 12 маленьких кубиков вращаются кольцом перед игроком. Все файлы своего эффекта вы создаёте в **своём** pack; исходники WispLib менять не нужно.

Пример рассчитан на VoxelCore 0.32.

## Что нужно знать перед началом

| Слово | Значение в этом руководстве |
|---|---|
| Content pack | Папка с игровыми ресурсами и Lua-кодом. Здесь это `mypack`. |
| Effect definition | JSON-файл с правилами создания эффекта. |
| Emitter | Часть эффекта, которая создаёт частицы. В одном effect может быть несколько emitters. |
| Backend | Способ показать частицы: штатные 2D, общая 3D Entity или отдельные Entity. |
| Handle | Значение, которое возвращает `vfx.spawn`. Через него можно остановить или изменить **этот** экземпляр эффекта. |

`mypack` — пример имени. В своём проекте замените его на ID вашего пака во всех путях и в Lua Content ID.

## 1. Подключите pack

В проекте VoxelCore положите WispLib и ваш pack в каталог `content/`:

```text
project.toml
content/
├── wisplib/
│   └── package.json
└── mypack/
    ├── package.json
    ├── effects/
    │   └── ring.effect.json
    └── scripts/
        └── hud.lua
```

В `project.toml` включите оба пака. Если там уже есть другие `base_packs`, добавьте `mypack` к существующему списку:

```toml
base_packs = ["base", "wisplib", "mypack"]
```

Файл `content/mypack/package.json`:

```json
{
  "id": "mypack",
  "title": "My VFX Pack",
  "version": "0.1.0",
  "creator": "Your Name",
  "description": "My first WispLib effect",
  "dependencies": [
    "!base@>=0.32",
    "!wisplib@>=0.3.3"
  ]
}
```

Зависимость сообщает движку, что `mypack` нужен WispLib. Запись в `base_packs` включает ваш pack при запуске проекта. Одной зависимости недостаточно, если сам `mypack` не выбран проектом.

## 2. Опишите кольцо

Создайте `content/mypack/effects/ring.effect.json`:

```json
{
  "schema": 1,
  "motion": "controlled",
  "emitters": [
    {
      "backend": "entity",
      "particle": "wisplib:controlled_particle",
      "spawn": {"mode": "burst", "count": 12},
      "lifetime": 20,
      "appearance": {
        "scale": 0.07,
        "color": [0.2, 0.8, 1.0, 1.0]
      }
    }
  ]
}
```

Что здесь происходит: один emitter сразу создаёт 12 Entity-частиц. `controlled` означает, что WispLib будет задавать их положение каждый update. Встроенная `wisplib:controlled_particle` — маленькая 3D модель; `scale` задаёт размер, четыре числа `color` — красный, зелёный, синий и alpha от 0 до 1. Каждая частица живёт 20 секунд.

Файл с именем `ring.effect.json` вызывается по Content ID `mypack:ring`. WispLib ищет его по пути `mypack:effects/ring.effect.json`. В `content.json` этот файл вручную добавлять не нужно.

## 3. Запустите эффект

Создайте `content/mypack/scripts/hud.lua`:

```lua
local vfx = require "wisplib:vfx"
local ring

function on_hud_open()
    local player_id = hud.get_player()
    local pos = player.get_pos(player_id)
    local dir = player.get_dir(player_id)

    local center = {
        pos[1] + dir[1] * 3,
        pos[2] + 1.4 + dir[2] * 3,
        pos[3] + dir[3] * 3
    }

    local err
    ring, err = vfx.spawn("mypack:ring", {
        position = center,
        controller = {type = "orbit", radius = 0.6, speed = 1.5}
    })
    if not ring then
        print("WispLib: " .. tostring(err))
    end
end
```

Откройте мир с подключённым `mypack`. При открытии игрового интерфейса скрипт получает позицию и направление взгляда игрока, выбирает точку примерно в трёх единицах перед ним и запускает кольцо. Контроллер `orbit` меняет положение каждой частицы; поле `radius` задаёт радиус, `speed` — скорость вращения. Через 20 секунд частицы исчезнут.

`require "wisplib:vfx"` возвращает Lua-таблицу с функциями библиотеки. Слово `vfx` слева от `=` — обычное имя локальной переменной; можно выбрать другое.

Обновление эффекта уже выполняют скрипты WispLib: на клиенте — `scripts/hud.lua`, в headless режиме — `scripts/world.lua`. Из вашего pack вызывать `vfx.update()` в обычной конфигурации не нужно. Этот пример использует `on_hud_open` и потому предназначен для клиента.

## 4. Измените поведение

### Привяжите кольцо к игроку

В первом примере кольцо остаётся на выбранной точке. Чтобы оно двигалось с игроком, замените таблицу настроек в `vfx.spawn`:

```lua
local entity_uid = player.get_entity(hud.get_player())
ring, err = vfx.spawn("mypack:ring", {
    anchor = {
        type = "entity",
        uid = entity_uid,
        offset = {0, 1.3, 0}
    },
    space = "local",
    controller = {type = "orbit", radius = 0.8, speed = 1.5},
    anchor_policy = "destroy"
})
```

`hud.get_player()` возвращает **ID игрока**. `player.get_entity(...)` возвращает **UID его Entity**. Entity anchor принимает именно UID. `offset` поднимает центр кольца относительно Entity. При каждом update WispLib получает её актуальное положение. `anchor_policy = "destroy"` удалит эффект, если Entity исчезнет. Без этого параметра политика по умолчанию — `freeze`: эффект остаётся у последней известной позиции.

### Управляйте отдельным экземпляром

Переменная `ring` хранит handle, который вернул `vfx.spawn`. Пока он действителен:

```lua
ring:pause()                 -- приостановить
ring:resume()                -- продолжить
ring:move({10, 70, -4})      -- переместить центр
ring:stop()                  -- прекратить эффект
ring:restart()               -- запустить этот экземпляр заново
ring:destroy()               -- удалить его
```

`stop()` и `destroy()` различаются: первый завершает эффект по правилам его backend, второй удаляет runtime instance. После естественного завершения эффект имеет состояние `finished`; его можно `restart()` или `destroy()`. Уточнения по состояниям и возвращаемым значениям — в [справочнике API](WispLib_API_Manual.md).

Чтобы менять число частиц через параметр, его сначала нужно объявить в JSON definition и использовать вместо фиксированного `count`. Пример такого параметра есть в справочнике; `set_parameter("count", ...)` не создаёт параметр автоматически.

## Как выбрать способ показа частиц

| Backend | Для чего подходит | Что важно помнить |
|---|---|---|
| `billboard` | Обычные плоские частицы через встроенный `gfx.particles` VoxelCore. | WispLib не меняет отдельно положение и цвет уже выпущенной частицы. |
| `mesh` | Много управляемых 3D элементов в контейнере Entity. | Элементы являются slots скелета, а не отдельными физическими Entity. |
| `entity` | Отдельные 3D объекты, которым нужны собственные компоненты или контролируемый transform. | Каждая частица создаёт Entity; большое их число требует измерения на вашей сцене. |

Кольцо в примере использует `entity` ради простоты. Для большего количества управляемых 3D элементов смотрите `mesh` в [справочнике API](WispLib_API_Manual.md). Готового числа «безопасных частиц» нет: производительность зависит от модели, компонентов, платформы и числа одновременных эффектов.

## Временный и сохраняемый эффект

`vfx.spawn(...)` создаёт runtime instance. Его частицы и handle не записываются в мир. Для эффекта, который должен появиться снова после загрузки мира, используйте `vfx.world.create(...)`. WorldEffect сохраняет ID definition, положение и сериализуемые настройки в каталоге текущего мира (`world:data/wisplib/world_effects.json`); симуляция частиц при загрузке начинается заново. Дополнительное разрешение `write-to-user` не требуется. Пример и ограничения сериализации приведены в [разделе WorldEffect справочника API](WispLib_API_Manual.md).

## Если эффекта не видно

1. Убедитесь, что `mypack` добавлен в `base_packs`, а зависимость от `wisplib` указана в `package.json`.
2. Сверьте путь `content/mypack/effects/ring.effect.json` и ID `mypack:ring`. Ошибка загрузки или validation будет напечатана скриптом.
3. Проверьте, что мир открыт в клиенте: `on_hud_open` в headless режиме не вызывается.
4. Для Entity anchor проверьте, что передали UID существующей Entity, а не ID игрока.
5. Убедитесь, что эффект ещё жив: у демонстрационных частиц `lifetime = 20` секунд.

Дальше используйте [справочник API](WispLib_API_Manual.md): там описаны параметры, точки и траектории, собственные controllers, события, звук и сохраняемые WorldEffects.
