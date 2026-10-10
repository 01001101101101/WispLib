# WispLib: первый эффект в своём content pack

Это руководство показывает полный путь: подключить WispLib, описать эффект, запустить его в игре и затем изменить. В примере 12 маленьких кубиков вращаются кольцом перед игроком. Все файлы своего эффекта вы создаёте в **своём** pack; исходники WispLib менять не нужно.

Руководство относится к WispLib 0.4.0 и рассчитано на VoxelCore 0.32.

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
    "!wisplib@>=0.4.0"
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

## Экранный эффект: радиопомехи, реагирующие на движение

`vfx.screen` управляет GLSL-постобработкой: шейдер получает готовое изображение сцены и возвращает изменённый кадр. Ниже — пример помех с лёгкой кривизной «экрана», зерном, цветовым сдвигом и короткими случайными сбоями. Lua усиливает их при движении и прыжке и приглушает, когда игрок смотрит почти вплотную в стену.

Это не частицы и не геометрия в мире. Шейдер не создаёт Entity, коллизии или тени. В VoxelCore постобработка проходит после мира, но до first-person рук и HUD: интерфейс и оружие остаются чистыми.

### Файлы эффекта

Добавьте в `content/mypack/` следующие файлы. Имя GLSL alias должно быть уникальным среди подключённых паков:

```text
resources.json
preload.json
screen-effects/radio_noise.screenfx.json
shaders/effects/radio_noise.glsl
scripts/hud.lua
```

Если в pack уже есть `resources.json` или `preload.json`, добавьте эти записи к существующим данным, сохранив другие слоты и asset aliases.

`resources.json` резервирует слот движка, а `preload.json` сообщает движку, какой GLSL asset загрузить:

```json
{"post-effect-slot": ["radio_noise"]}
```

```json
{
  "post-effects": [
    {"name": "mypack_radio_noise", "path": "shaders/effects/radio_noise"}
  ]
}
```

`name` — runtime alias без `mypack:`; он должен быть уникальным. `path` указывает на `shaders/effects/radio_noise.glsl` внутри пака. Профиль WispLib свяжет этот alias со слотом:

```json
{
  "schema": 1,
  "slot": "mypack:radio_noise",
  "effect": "mypack_radio_noise",
  "intensity": 0.95,
  "parameters": {
    "noise": {"uniform": "p_noise", "type": "float", "default": 0.035, "min": 0, "max": 0.12},
    "tearing": {"uniform": "p_tear", "type": "float", "default": 0.04, "min": 0, "max": 0.08},
    "vignette": {"uniform": "p_vignette", "type": "float", "default": 0.5, "min": 0, "max": 0.9},
    "motion": {"uniform": "p_motion", "type": "float", "default": 0, "min": 0, "max": 1},
    "airborne": {"uniform": "p_airborne", "type": "float", "default": 0, "min": 0, "max": 1},
    "impact": {"uniform": "p_impact", "type": "float", "default": 0, "min": 0, "max": 1},
    "wall_calm": {"uniform": "p_wallCalm", "type": "float", "default": 0, "min": 0, "max": 1}
  }
}
```

Сохраните его как `screen-effects/radio_noise.screenfx.json`; ID профиля будет `mypack:radio_noise`. Имена слева (`motion`, `wall_calm`) — ключи Lua API, а `uniform` — соответствующие параметры в GLSL. Числа `min` и `max` ограничивают значения, которые WispLib передаст шейдеру.

### GLSL

Создайте `shaders/effects/radio_noise.glsl`:

```glsl
#param float p_noise = 0.035
#param float p_tear = 0.04
#param float p_vignette = 0.5
#param float p_motion = 0.0
#param float p_airborne = 0.0
#param float p_impact = 0.0
#param float p_wallCalm = 0.0

float hashNoise(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec4 effect() {
    float activity = clamp(p_motion * 0.58 + p_airborne * 0.46 + p_impact * 1.3, 0.0, 1.0);
    float calm = clamp(p_wallCalm, 0.0, 1.0);
    float dynamic = activity * (1.0 - calm * 0.88);
    vec2 screenSize = vec2(u_screenSize);
    vec2 texel = 1.0 / max(screenSize, vec2(1.0));
    vec2 uv = (v_uv - 0.5) * 2.0;
    uv *= 1.0 + 0.018 * dot(uv, uv);
    uv = uv * 0.5 + 0.5;

    vec2 wave = vec2(sin(uv.y * 18.0 + u_timer * 5.7),
                     cos(uv.x * 13.0 - u_timer * 4.2));
    uv += wave * (0.0004 + dynamic * 0.003);
    float frame = floor(u_timer * 20.0);
    vec2 blockId = floor(v_uv * screenSize / 14.0);
    float flicker = step(0.96 - dynamic * 0.08,
                         hashNoise(blockId + vec2(frame, floor(u_timer * 7.0)))) * dynamic;
    uv.x += (hashNoise(blockId + vec2(41.0, frame)) - 0.5) * flicker * 0.025;

    for (int i = 0; i < 3; i++) {
        float seed = floor(u_timer * 16.0) + float(i) * 31.7;
        vec2 center = vec2(hashNoise(vec2(seed, 1.7)), hashNoise(vec2(seed, 8.3)));
        vec2 size = vec2(0.04 + hashNoise(vec2(seed, 4.1)) * 0.12,
                         0.012 + hashNoise(vec2(seed, 6.9)) * 0.035);
        vec2 q = abs(v_uv - center) / size;
        float patch = 1.0 - smoothstep(0.78, 1.15, max(q.x, q.y));
        float gate = step(0.55, hashNoise(vec2(seed, 12.1)));
        uv.x += (hashNoise(vec2(seed, 25.0)) - 0.5) * p_tear
              * (0.2 + dynamic * 2.0) * patch * gate * (1.0 - calm);
    }

    uv = clamp(uv, texel * 0.5, vec2(1.0) - texel * 0.5);
    vec2 sampleUV = (floor(uv * screenSize) + 0.5) / screenSize;
    float chroma = 0.002 * (1.0 + dynamic * 2.0);
    vec3 color = vec3(texture(u_screen, sampleUV + vec2(chroma, 0.0)).r,
                      texture(u_screen, sampleUV).g,
                      texture(u_screen, sampleUV - vec2(chroma, 0.0)).b);
    float grain = hashNoise(floor(sampleUV * screenSize) + vec2(17.0, frame * 71.0));
    color += (grain - 0.5) * p_noise * (0.4 + dynamic * 1.5) * (1.0 - calm * 0.8);
    float edge = length((v_uv - 0.5) * vec2(0.78, 1.0));
    color *= 1.0 - p_vignette * smoothstep(0.38, 1.25, edge);
    vec3 original = texture(u_screen, v_uv).rgb;
    return vec4(mix(original, clamp(color, 0.0, 1.0), u_intensity), 1.0);
}
```

`u_screen` — исходный кадр, `v_uv` — координата текущего пикселя, `u_timer` — время шейдера, `u_intensity` — интенсивность, которую WispLib меняет при fade/stop. Остальные `p_*` значения задаются через профиль и Lua. Шейдер собирает несколько небольших операций: искривляет координату выборки, иногда сдвигает отдельные участки, разносит цветовые каналы, добавляет шум и затемняет края. Это один полноэкранный проход, а не множество игровых объектов.

### Свяжите параметры с игроком

В `scripts/hud.lua` запустите профиль и обновляйте только его динамические параметры. Здесь состояние пересылается не чаще 30 раз в секунду; сам GLSL проход движок выполняет при рендере кадра.

```lua
local vfx = require "wisplib:vfx"
local handle, player_id
local state = {motion = 0, airborne = 0, impact = 0, wall_calm = 0}
local previous_y, pulse, wall_timer, send_timer = 0, 0, 0, 0

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local function smooth(a, b, rate, dt)
    return a + (b - a) * (1 - math.exp(-rate * dt))
end

function on_hud_open()
    player_id = hud.get_player()
    local _, vy = player.get_vel(player_id)
    previous_y = vy or 0
    local err
    handle, err = vfx.screen.play("mypack:radio_noise", {intensity = 0.95})
    if not handle then print("Radio noise: " .. tostring(err)) end
end

function on_hud_render()
    if not handle or not handle:exists() or not player_id then return end
    local dt = clamp(time.delta() or 0, 0, 0.1)
    local x, y, z = player.get_pos(player_id)
    local vx, vy, vz = player.get_vel(player_id)
    if not x or not y or not z or not vx or not vy or not vz then return end

    local speed = math.sqrt(vx * vx + vz * vz)
    state.motion = smooth(state.motion, clamp((speed - 0.1) / 2.8, 0, 1), 7, dt)
    state.airborne = smooth(state.airborne, clamp(math.abs(vy) / 5, 0, 1), 5.5, dt)
    if previous_y <= 0.35 and vy > 1 then pulse = 0.88 end
    if previous_y < -1.1 and vy > -0.15 then pulse = 1 end
    previous_y = vy
    pulse = math.max(0, pulse * math.exp(-dt * 3.6))
    state.impact = pulse

    wall_timer = wall_timer + dt
    if wall_timer >= 0.08 then
        wall_timer = 0
        local dir = player.get_dir(player_id)
        local calm = 0
        if dir then
            local ok, hit = pcall(block.raycast, {x, y + 1.3, z}, dir, 3.2)
            if ok and hit and hit.length then calm = clamp((2.6 - hit.length) / 1.9, 0, 1) end
        end
        state.wall_calm = smooth(state.wall_calm, calm, 6.5, 0.08)
    end

    send_timer = send_timer + dt
    if send_timer >= 1 / 30 then
        send_timer = 0
        local ok, err = handle:set_params(state)
        if not ok then print("Radio noise update: " .. tostring(err)) end
    end
end

function on_hud_close()
    if handle then handle:destroy(); handle = nil end
    player_id = nil
end
```

При открытии HUD скрипт создаёт handle. Скорость и вертикальное движение игрока плавно меняют `motion` и `airborne`; начало прыжка или приземление дают короткий импульс `impact`. Раз в 0,08 секунды raycast проверяет, близка ли стена по направлению взгляда. Результат смягчает помехи через `wall_calm`. При закрытии HUD handle уничтожается, поэтому эффект не остаётся активным.

Код, который хранит handle, может менять и остальные параметры. Например, при входе в опасную зону усилить зерно и затемнить края:

```lua
handle:set("noise", 0.08)
handle:tween("vignette", 0.72, 0.6, "smooth")
handle:fade_to(0.75, 0.3)
```

`set` меняет параметр сразу, `tween` плавно меняет его, а `fade_to` регулирует вклад всего постэффекта. Динамические `motion`, `airborne`, `impact` и `wall_calm` в этом примере обновляет HUD-скрипт.

Это пример клиентского HUD-скрипта: `vfx.screen` требует renderer и не работает в headless режиме. Сам GLSL и слот остаются ресурсами `mypack`; WispLib только предоставляет Lua управление. Для второго параллельного постэффекта объявите ещё один слот и отдельный GLSL alias. Более компактные thermal-пример, типы uniform, массивы и ограничения движка описаны в [справочнике API](WispLib_API_Manual.md#экранные-glsl-post-effects).

## Временный и сохраняемый эффект

`vfx.spawn(...)` создаёт runtime instance. Его частицы и handle не записываются в мир. Для эффекта, который должен появиться снова после загрузки мира, используйте `vfx.world.create(...)`. WorldEffect сохраняет ID definition, положение и сериализуемые настройки в двух чередующихся файлах каталога текущего мира (`world:data/wisplib/world_effects.a.json` и `world_effects.b.json`); симуляция частиц при загрузке начинается заново. Дополнительное разрешение `write-to-user` не требуется. Пример и ограничения сериализации приведены в [разделе WorldEffect справочника API](WispLib_API_Manual.md).

## Если эффекта не видно

1. Убедитесь, что `mypack` добавлен в `base_packs`, а зависимость от `wisplib` указана в `package.json`.
2. Сверьте путь `content/mypack/effects/ring.effect.json` и ID `mypack:ring`. Ошибка загрузки или validation будет напечатана скриптом.
3. Проверьте, что мир открыт в клиенте: `on_hud_open` в headless режиме не вызывается.
4. Для Entity anchor проверьте, что передали UID существующей Entity, а не ID игрока.
5. Убедитесь, что эффект ещё жив: у демонстрационных частиц `lifetime = 20` секунд.

Дальше используйте [справочник API](WispLib_API_Manual.md): там описаны параметры, точки и траектории, собственные controllers, события, звук и сохраняемые WorldEffects.
