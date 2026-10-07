# WispLib: API для другого content pack

WispLib читает описание эффекта из JSON и возвращает Lua handle для управления его экземпляром. Один эффект может состоять из нескольких emitters и звуков. Публичная точка входа — `require "wisplib:vfx"`.

## Минимальный пример API

Пошаговый запуск в клиенте с готовым обработчиком `on_hud_open` показан в [руководстве для разработчика](WispLib_Руководство_разработчика.md). Здесь — короткий пример формата и вызовов API.

Добавьте зависимость в `content/mygame/package.json`:

```json
{
  "id": "mygame",
  "title": "My Game",
  "version": "0.1.0",
  "creator": "Your Name",
  "description": "My WispLib effects",
  "dependencies": ["!base@>=0.32", "!wisplib@>=0.3.3"]
}
```

В `project.toml` игры включите `base`, `wisplib` и свой pack в `base_packs`. Пример: `base_packs = ["base", "wisplib", "mygame"]`.

Создайте `content/mygame/effects/orbit.effect.json`. Его effect ID будет `mygame:orbit`:

```json
{
  "schema": 1,
  "motion": "controlled",
  "controller": {"type": "orbit", "radius": 0.8, "speed": 1.4},
  "parameters": {
    "count": {"type": "number", "default": 16, "min": 1, "max": 64},
    "size": {"type": "number", "default": 0.08, "min": 0.02, "max": 0.5}
  },
  "emitters": [
    {
      "backend": "entity",
      "particle": "wisplib:controlled_particle",
      "spawn": {"mode": "burst", "count": {"parameter": "count"}},
      "lifetime": 3600,
      "appearance": {
        "scale": {"parameter": "size"},
        "color": [0.25, 0.8, 1.0, 1.0]
      }
    }
  ]
}
```

`wisplib:controlled_particle` — техническая Entity из библиотеки. Для своего вида укажите Content ID собственной Entity с нужной моделью и компонентами. `lifetime` здесь задаёт срок жизни каждой частицы в секундах; `3600` держит кольцо видимым долго.

Когда мир уже открыт, вызовите из игрового обработчика Lua:

```lua
local vfx = require "wisplib:vfx"

local fx, err = vfx.spawn("mygame:orbit", {
    position = {12, 70, -4},
    parameters = {count = 24, size = 0.06},
})
if fx then
    local ok, change_error = fx:set_parameter("count", 32)
    if not ok then print(change_error) end
    fx:move({14, 70, -4})
else
    print("Cannot start orbit: " .. tostring(err))
end
```

Сохраните `fx` в переменной, доступной вашему игровому коду, если позже потребуется `fx:destroy()`. `spawn()` возвращает `handle` либо `nil, error`. Методы изменения обычно возвращают `true` либо `false, error`; некоторые простые методы при неуспехе возвращают только `false`.

### Кто вызывает `update()`

При обычном подключении WispLib его `scripts/hud.lua` вызывает `vfx.update()` каждый клиентский render frame, а `scripts/world.lua` делает это на headless/server world tick. Не вызывайте `update()` второй раз из игрового pack: эффект продвинется повторно. Если lifecycle-скрипты библиотеки отключены, обеспечьте один регулярный вызов сами. `vfx.update(dt)` принимает необязательный интервал в секундах и ограничивает его максимумом `0.1`.

## Выбрать backend и описать emitter

Корень definition содержит `schema: 1` и массив `emitters`. Пустой массив допустим для эффекта только со звуком. Необязательные поля корня: `motion`, `controller`, `parameters`, `events`, `audio`, `duration`, `world.placeable`.

| Backend | Обязательное поле emitter | Что создаётся | Для чего подходит |
| --- | --- | --- | --- |
| `billboard` | `preset` | Нативный `gfx.particles` emitter | Текстурированные частицы, которые затем симулирует движок |
| `mesh` | — | Entity-контейнер со слотами skeleton | Много 3D фигур с индивидуальными position, rotation, scale, color |
| `entity` | `particle` или `entity` | Отдельная Entity на каждую частицу | Rigidbody, Lua-компоненты, raycast и события отдельных частиц |

`preset` у billboard — объект native particle settings либо путь/Content ID JSON preset; строке без `.json` расширение добавляется автоматически. Mesh backend по умолчанию создаёт `wisplib:mesh_emitter`. Один контейнер вмещает не более 512 slots; при большем количестве создаются дополнительные контейнеры. Это вместимость, а не гарантированный предел производительности.

Для Entity `spawn.mode` по умолчанию `burst`: `spawn.count` задаёт число частиц (по умолчанию 1). Режим `rate` использует `spawn.rate` в частицах за секунду и необязательный общий `spawn.limit`. У billboard режим по умолчанию `rate`; `burst` выпускает `spawn.count`. Для mesh количество задаёт `settings.count` (по умолчанию 128); `settings.loop: false` делает его конечным.

Пример отдельного mesh effect:

```json
{
  "schema": 1,
  "emitters": [
    {
      "backend": "mesh",
      "motion": "simulated",
      "shape": {"type": "sphere", "radius": 0.6},
      "settings": {"count": 40, "loop": false},
      "appearance": {"size": 0.05, "color": [1.0, 0.7, 0.2, 1.0]}
    }
  ]
}
```

`appearance.scale`/`size` принимает неотрицательное число, `vec3` либо диапазон `{"min": ..., "max": ...}`. `appearance.color` принимает RGB/RGBA или диапазон цветов. Mesh `appearance.models` — массив ID моделей или объектов `{"model": "mygame:star", "weight": 3}`; модель выбирается при рождении slot. `scale_over_life`, `color_over_life`, `alpha_over_life` — массивы точек `[доля_жизни, значение]` с долей от 0 до 1. Alpha записывается в skeleton tint; прозрачность на экране зависит также от материала модели.

### Передать параметры

Типы параметров: `number`, `boolean`, `enum`, `vec3`, `color`. Для `enum` требуется непустой `values`; для `number` можно задать `min`/`max`. Ссылка из emitter на объявленный параметр: `{"parameter": "size"}`. Если `spawn.count` или `spawn.limit` берётся из параметра, у числового параметра должны быть конечные неотрицательные целые `min` и `max`. Для `spawn.rate` границы должны быть конечными неотрицательными числами.

`spawn()` ищет значение в `options.parameters`, затем в одноимённом поле `options`, затем берёт `default`. Числа приводятся к `min`/`max`; некорректный ввод при обычном transient `spawn()` может превратиться в default. `handle:set_parameter()` и `vfx.world.create()` проверяют переданные значения строже и сообщают об неизвестном имени или неверном типе. Для явности передавайте значения через `options.parameters`.

## Управлять запущенным эффектом

| Метод handle | Действие |
| --- | --- |
| `state()` / `exists()` | Состояние `running`, `paused`, `stopping`, `finished`, `destroyed` / доступность handle |
| `get(name)` / `get_parameter(name)` | Читает общие поля или объявленный параметр / только параметр |
| `set(name, value)` / `set_parameter(name, value)` | Меняет `scale`, `rotation` (mat4) или параметр / только параметр |
| `move(position)` | Задаёт мировую точку и снимает привязку к anchor |
| `set_anchor(anchor, space)` / `attach(uid, offset)` | Привязывает к world/Entity anchor / использует старую привязку по UID |
| `set_source_target(source, target)` / `set_points(points)` | Обновляет данные controllers `source_target` и `points` |
| `set_count(count, emitter_index?)` | Меняет число mesh или burst Entity; индекс emitter начинается с 1 |
| `pause()` / `resume()` | Ставит runtime на паузу / возобновляет |
| `stop()` / `destroy()` / `restart()` | Прекращает выпуск и ждёт живые частицы / удаляет экземпляр и принадлежащие объекты / запускает заново |
| `release_particles(options)` | Передаёт controlled/hybrid Entity частицы симуляции; возвращает `true, count` |
| `on(event, callback)` / `emit(event, details)` | Подписывает Lua callback / вручную посылает particle event |
| `set_audio(sources)` | Заменяет звуковые cues |

`get("position")`, `get("state")`, `get("scale")`, `get("audio")` читают текущее значение. `get("audio_error")`, `get("callback_error")`, `get("action_error")`, `get("controller_error")`, `get("collision_error")`, `get("spawn_error")` помогают найти ошибку во время работы.

Для billboard `set_parameter()` может вернуть третий результат `status`:

```lua
local ok, err, status = fx:set_parameter("size", 0.1)
if not ok then print(err) end
```

`billboard_rate_recreated` означает пересоздание rate emitter; `billboard_burst_deferred` — уже выпущенный burst не изменился, новые настройки применятся после `restart()`; для смешанного эффекта возвращается `billboard_rate_recreated_burst_deferred`. При успехе `err == nil`.

`pause()` останавливает выпуск billboard particles, но уже выпущенные частицы продолжают двигаться в движке. `resume()` вновь создаёт rate emitter; для повторного burst вызовите `restart()`. `stop()` даёт живым частицам завершиться. `destroy()` удаляет экземпляр и его Entity/mesh-контейнеры. Поштучного удаления native billboard particles этот API не даёт.

## Привязать эффект и задать движение

Anchor может быть статическим `{type = "world", position = {x, y, z}}` или `{type = "entity", uid = some_uid}`. Entity UID должен существовать при `spawn()` и `set_anchor()`. Пространства `world`, `local`, `parent`; для `local`/`parent` нужен anchor. Если `anchor` передан без `space`, используется `local`. `position` в локальном пространстве — смещение от anchor. Для нового кода используйте `anchor`; `parent = uid` и `attach()` сохранены для старого способа привязки.

```lua
local fx, err = vfx.spawn("mygame:orbit", {
    anchor = {type = "entity", uid = entity_uid, offset = {0, 1, 0}},
    position = {0, 0, 0},
    space = "local",
    anchor_policy = "destroy",
})
```

Для игрока получите `entity_uid` через `player.get_entity(hud.get_player())`: ID игрока и UID Entity различаются. При исчезновении Entity anchor `anchor_policy` задаёт действие: `freeze` (по умолчанию) удерживает последний transform, `stop` прекращает выпуск, `destroy` удаляет эффект, `detach` снимает привязку. Bone/socket anchors отсутствуют. Для billboard привязка обновляет origin нативного emitter; WispLib не задаёт transform уже выпущенных billboard particles.

`controlled` назначает transform каждого Entity/mesh particle на каждом update. `simulated` использует симуляцию backend. `hybrid` начинает с controller и позволяет затем вызвать `release_particles()` для Entity. Например, `fx:release_particles({velocity = "radial", speed = 3})` рассчитывает скорость от центра эффекта; фиксированный вектор передаётся как `{velocity = {0, 4, 0}}`. Mesh slots нельзя превратить в отдельные Rigidbody.

Встроенные controllers: `follow`, `orbit`, `points`, `path`, `source_target`. Их можно указать на уровне effect или emitter; emitter-настройка имеет приоритет. Для `points` передайте массив vec3 при spawn или обновите через `set_points()`. Controller `path` распределяет частицы вдоль пути по индексу. Для линии между двумя Entity используйте controlled Entity или mesh definition, например `mygame:orbit` выше, и переопределите controller:

```lua
local beam, err = vfx.spawn("mygame:orbit", {
    source = {type = "entity", uid = caster_uid},
    target = {type = "entity", uid = target_uid},
    controller = {type = "source_target", wave = 0.1, frequency = 2},
})
```

`source_target` читает текущие transforms `source` и `target`; без них позиции для линии не появятся. `vfx.path()` создаёт путь типов `line`, `circle`, `polyline`, `bezier` или заранее зарегистрированного типа. Результат имеет `:evaluate(t)` для `t` от 0 до 1. Bezier требует четыре точки:

```lua
local curve = assert(vfx.path({
    type = "bezier",
    points = {{0, 0, 0}, {1, 2, 0}, {2, 2, 0}, {3, 0, 0}},
}))
local midpoint = curve:evaluate(0.5)
```

Стартовые shapes: `point`, `sphere`, `box`, `ring`, `disk`, `cone`; `line` и зарегистрированные Lua shapes работают только с Entity backend. Shape задаёт начальную позицию, controller — дальнейшее движение. Built-in modifiers по backend: mesh — `gravity`, `drag`, `wind`, `turbulence`, `vortex`; Entity — `gravity`, `drag`, `rotation`, `wind`, `turbulence`; billboard не принимает эти modifiers.

## Реагировать на события

События: `on_start`, `on_spawn`, `on_collision`, `on_particle_death`, `on_stop`, `on_finished`. Lua callback задаётся в `options.events` при `spawn()` или через `fx:on(event, callback)`; получает `(handle, details)`. `fx:emit()` принимает только `on_spawn`, `on_collision`, `on_particle_death` для внешних расширений.

```lua
local fx = assert(vfx.spawn("mygame:orbit", {
    events = {
        on_start = function(handle, details)
            print("Started: " .. details.effect)
        end,
        on_particle_death = function(handle, details)
            print("Entity ended: " .. details.reason)
        end,
    },
}))
```

Поштучные `on_spawn` и `on_particle_death` создаются для Entity backend. `on_collision` приходит от встроенного `raycast` либо custom collision resolver, если тот вернул `hit`. Native Rigidbody collision сам по себе этого события не создаёт. В JSON `events` можно связать событие с действиями `spawn_effect`, `change_parameter`, `release_particles`, `callback`, `destroy_particle`. Для `callback` заранее зарегистрируйте функцию через `vfx.register_callback("mygame:impact", fn)`.

```json
{
  "schema": 1,
  "emitters": [{
    "backend": "entity",
    "particle": "wisplib:controlled_particle",
    "spawn": {"mode": "burst", "count": 1},
    "velocity": [0, -5, 0],
    "collision": {"type": "raycast", "response": "destroy", "gravity": [0, 0, 0]}
  }],
  "events": {
    "on_collision": [{"type": "callback", "id": "mygame:impact"}]
  }
}
```

Для этого definition вызовите `vfx.register_callback("mygame:impact", fn)` до первого `spawn()` и запускайте частицу над твёрдой поверхностью. Lua callback получает `(handle, details, arguments)`.

## Добавить звук

`audio` — массив cues в definition или опция `audio` при spawn. `type: "sound"` использует уже загруженный asset ID; `type: "stream"` — путь к локальному `.ogg`/`.wav` ресурсу, доступному VoxelCore. Прямой URL-поток не поддерживается. Пример effect только со звуком; указанный файл должен существовать в игровом pack:

```json
{
  "schema": 1,
  "emitters": [],
  "audio": [
    {
      "event": "on_start",
      "type": "stream",
      "resource": "mygame:sounds/ambience/hum.ogg",
      "channel": "ambient",
      "volume": 0.4,
      "loop": true,
      "follow": true
    }
  ]
}
```

`spatial` по умолчанию `true`; `false` выбирает 2D звук и несовместимо с `follow` и ненулевым `offset`. `follow` по умолчанию включён для зацикленного пространственного звука. `loop` допустим только с `on_start`. Каналы: `regular`, `music`, `ambient`, `ui`; `volume` от 0 до 1, `pitch` — положительное число. `stop_on_stop` и `stop_on_finish` по умолчанию равны `loop`; `stop_on_destroy` по умолчанию включён для `loop` или `follow`. `set_audio()` останавливает прежние speakers, но новый `on_start` требует `restart()`. Эффект только с зацикленным звуком активен до `stop()`/`destroy()` либо истечения `duration`.

## Расширить библиотеку Lua-кодом

Регистрируйте расширения с namespaced ID до загрузки definitions, которые на них ссылаются. Все функции регистрации возвращают `true` либо `false, error`:

| Вызов | Интерфейс | Применение |
| --- | --- | --- |
| `vfx.register_shape(id, fn)` | `fn(context, random) -> vec3` | Стартовая позиция Entity |
| `vfx.register_controller(id, factory)` | `factory(config, effect) -> controller table` либо готовая controller table | Controlled Entity/mesh |
| `vfx.register_path(id, provider)` | `provider.evaluate(config, t, context) -> vec3` | Controller `path` |
| `vfx.register_modifier(id, fn)` | `fn(particle, context, config) -> fields` | Entity |
| `vfx.register_collision(id, fn)` | `fn(particle, context, config) -> fields` | Entity с `collision.type = "custom"` |
| `vfx.register_callback(id, fn)` | `fn(handle, details, arguments)` | JSON action `callback` |

Пример своего controller:

```lua
assert(vfx.register_controller("mygame:helix", function(config)
    return {
        update_particle = function(self, particle, dt, context)
            local angle = context.effect_time * (config.speed or 1)
                + context.normalized_index * math.pi * 2
            local radius = config.radius or 0.8
            return {
                position = {math.cos(angle) * radius, context.normalized_index * 2,
                    math.sin(angle) * radius},
                space = "local",
                scale = 0.06,
            }
        end,
    }
end))
```

В JSON: `{"type": "mygame:helix", "speed": 1.5}`. Controller table может также реализовать `init(self, config, context)`, `update(self, dt, context)`, `destroy(self, context)`. Контекст содержит время эффекта, индекс и возраст частицы, параметры, anchors, seed и RNG. Вариант `{"type": "script", "module": "mygame:controller_module"}` загружает Lua-модуль с controller table/factory.

Modifier для Entity может вернуть `acceleration` или `velocity`, а также `position`, `rotation`, `scale`, `color`. Custom collision resolver может вернуть `position`, `velocity`, `rotation`, `scale`, `color`, `hit` для события `on_collision` или `destroy = true` для удаления частицы.

Для встроенного raycast у Entity emitter задайте `collision: {"type": "raycast", "response": "bounce"}`. Возможные `response`: `bounce`, `stop`, `destroy`; настройки включают `gravity`, `restitution`, `radius`, `skin`, `damping`, `entities`. Raycast/custom collision требуют `simulated` или `hybrid` motion. `native_rigidbody` тоже требует `simulated` или `hybrid` и не вызывает `on_collision` автоматически.

## Сохранить эффект в мире

`vfx.world` хранит описание эффекта, а не живые Entity, возраст или скорость частиц. Для `create()` нужен открытый мир. Путь создаётся штатной функцией `pack.data_file("wisplib", "world_effects.json")`; разрешение `write-to-user` не требуется. При обычном подключении `scripts/world.lua` загружает записи при открытии мира, сохраняет их при сохранении и выходе, затем очищает runtime состояние. После изменения записи можно вызвать `save()` сразу.

```lua
local saved, err = vfx.world.create("mygame:orbit", {
    name = "town_orbit",
    position = {24, 68, -10},
    parameters = {count = 20, size = 0.07},
    tags = {"town", "ambient"},
    enabled = true,
    autostart = true,
})
if not saved then print(err); return end

saved:set_parameter("count", 28)
local ok, save_error = saved:save()
if not ok then print(save_error) end
```

`create()` возвращает WorldHandle либо `nil, error`. При `enabled = true` и `autostart = true` runtime запускается сразу, если нужный backend готов. Сохранённый `billboard` на клиенте стартует после открытия HUD, когда доступен `gfx.particles`; в headless режиме ему нужен клиент, поэтому запуск пропускается с диагностикой. `saved:stop()` останавливает текущий runtime, но оставляет запись; `saved:disable()` выключает запись и удаляет runtime; `saved:delete()` удаляет запись из памяти. После удаления вызовите `vfx.world.save()`, чтобы записать изменение сразу.

`vfx.world` предоставляет `create`, `get`, `get_by_name`, `list`, `find_by_tag`, `duplicate`, `delete`, `save`, `load`, `clear`, `stop_runtime`. WorldHandle предоставляет `get`, `get_parameter`, `start`, `stop`, `restart`, `move`, `set_rotation`, `set_scale`, `set`/`set_parameter`, `set_name`, `set_autostart`, `set_tags`, `set_audio`, `set_anchor`, `set_controller`, `enable`, `disable`, `save`, `delete`, `exists`. `set_controller()` перезапускает активный runtime. Методы `world.close()` и `world.start_pending_client()` обслуживают жизненный цикл WispLib и обычно не нужны игровому коду.

В запись входят ID, имя, effect ID, transform, параметры, controller, points, motion, audio, tags и flags. Lua closures и Entity UID не сериализуются. Для `anchor`, `source`, `target` допустимы только статические world anchors. Пользовательские Lua extensions должны быть вновь зарегистрированы до восстановления effects. Файл хранится в `world:data/wisplib/world_effects.json`, отдельно в каталоге каждого мира. Старые файлы `user:wisplib/world_effects_<seed>_<generator>.json` не импортируются автоматически: такой путь мог принадлежать нескольким мирам с одинаковыми seed и generator. Для переноса скопируйте нужный файл в `data/wisplib/world_effects.json` конкретного мира до его открытия. Запись файла выполняется напрямую; атомарная замена через временный файл API VoxelCore здесь не используется. Если файл повреждён, `load()` сообщит об ошибке и `save()` не станет его перезаписывать; проверяйте ошибку перед ручным `clear()`.

## Справка по функциям модуля

| Вызов | Результат |
| --- | --- |
| `vfx.validate(id, definition)` | `true` либо `false, error` для schema и сочетания возможностей |
| `vfx.register(id, definition)` | Регистрирует Lua table в памяти; `true` либо `nil, error` |
| `vfx.get_definition(id)` | Копия definition либо `nil, error` |
| `vfx.list_definitions({search = ..., placeable_only = ...})` | Список установленных definitions и отдельный список ошибок чтения |
| `vfx.clear_definition_cache(id?)` | Сбрасывает одну или все загруженные definitions |
| `vfx.capabilities()` | Таблица возможностей backend |
| `vfx.stats()` / `vfx.handles()` | Счётчики runtime / handles в памяти |
| `vfx.stop_all()` / `vfx.stop_transient_all()` | Уничтожает все instances / только instances вне WorldEffects |

`vfx.stats()` считает объекты и raycasts текущего update; это не профилировщик CPU/GPU. Billboard не даёт WispLib точного числа ещё видимых частиц: после остановки библиотека ждёт максимальный `lifetime` preset. Mesh slots обновляются через Lua и skeleton API без GPU simulation. Стоимость Entity backend растёт с числом отдельных Entity. Библиотека не задаёт универсальный безопасный бюджет частиц.

Исходный публичный модуль: `content/wisplib/modules/vfx.lua`. Компонент mesh backend: `content/wisplib/scripts/components/mesh_emitter.lua`.
