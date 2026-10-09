-- Client frame timing for a single controlled mesh effect. No images captured.
assert(vc.is_client())
local requested = tonumber(vc.get_project_arg("count") or "512")
assert(requested and requested >= 0 and requested <= 10000)
local count = math.floor(requested)
local backend = vc.get_project_arg("backend") or "mesh"
assert(backend == "mesh" or backend == "billboard")
local update_samples = tonumber(vc.get_project_arg("update_samples") or "40")
assert(update_samples and update_samples >= 1 and update_samples <= 100)
update_samples = math.floor(update_samples)
app.set_setting("chunks.load-distance", 3)
app.new_world("wisplib-client-benchmark", "845071", "core:default")
app.tick()
local vfx = require "wisplib:vfx"
local x, y, z = player.get_pos(0)
local center = {x, y + 35, z}
player.set_suspended(0, true)
local camera = require("core:ai_orbit").new({
    player_id = 0, target_pos = center, radius = 4.5, height = 0,
    speed = 0, smoothing = 0, mouse_controls = false, fov = 58,
})
local function tick()
    assert(camera:step(0))
    app.tick()
end
local effect
if count > 0 then
    local id = "wisplib_bench:" .. backend
    local definition
    if backend == "mesh" then
        definition = {schema = 1, motion = "controlled", emitters = {{
            backend = "mesh", container = "wisplib:mesh_emitter", motion = "controlled",
            settings = {count = count, capacity = 512, size = 0.05, loop = true},
            controller = {type = "orbit", radius = 2, speed = 1.0},
        }}}
    else
        definition = {schema = 1, emitters = {{
            backend = "billboard", preset = {
                texture = "particles:smoke_0", lighting = false,
                collision = false, spawn_interval = 0, lifetime = 10,
                lifetime_spread = 0, max_distance = 100,
                size = {0.05, 0.05, 0.05}, explosion = {0, 0, 0},
                acceleration = {0, 0, 0}, spawn_shape = "sphere",
                spawn_spread = {2, 2, 2},
            }, spawn = {mode = "burst", count = count},
        }}}
    end
    assert(vfx.register(id, definition))
    effect = assert(vfx.spawn(id, {position = center}))
end

for _ = 1, 30 do tick() end
local times = {}
for i = 1, 60 do
    local started = time.precise_time()
    tick()
    times[i] = (time.precise_time() - started) * 1000
end
table.sort(times)
local total = 0
for _, value in ipairs(times) do total = total + value end
local stats = vfx.stats()
if count > 0 and backend == "mesh" then assert(stats.mesh_particles == count) end
local update_times = {}
for i = 1, update_samples do
    local started = time.precise_time()
    vfx.update(1 / 60)
    update_times[i] = (time.precise_time() - started) * 1000
end
table.sort(update_times)
local update_total = 0
for _, value in ipairs(update_times) do update_total = update_total + value end
print(string.format("WISPLIB_BENCH backend=%s count=%d median_ms=%.3f mean_ms=%.3f p95_ms=%.3f max_ms=%.3f mesh_particles=%d",
    backend, count, (times[30] + times[31]) / 2, total / #times, times[57], times[60], stats.mesh_particles))
print(string.format("WISPLIB_UPDATE backend=%s count=%d samples=%d median_ms=%.3f mean_ms=%.3f p95_ms=%.3f",
    backend, count, update_samples, update_times[math.ceil(update_samples / 2)],
    update_total / update_samples, update_times[math.ceil(update_samples * 0.95)]))
if effect then assert(effect:destroy()) end
camera:stop()
app.close_world(true)
