-- Finite graphical smoke test. Run with VoxelCore_AI ai_runner check --client.
assert(vc.is_client(), "graphical client required")
app.set_setting("chunks.load-distance", 3)
app.new_world("wisplib-client-runtime", "534762", "core:default")
assert(world.is_open())
app.tick()

local vfx = require "wisplib:vfx"
assert(assets.to_canvas("particles:smoke_0"), "billboard atlas region is missing")
local x, y, z = player.get_pos(0)
assert(x and y and z)
local center = {x, y + 35, z}
player.set_suspended(0, true)
local camera = require("core:ai_orbit").new({
    player_id = 0, target_pos = center, radius = 5, height = 0,
    speed = 0, smoothing = 0, mouse_controls = false, fov = 58,
})
local function tick()
    assert(camera:step(0))
    app.tick()
end
local anchor = entities.spawn("wisplib:controlled_particle", center)
local uid = anchor:get_uid()

local defs = {
    entity = {schema = 1, motion = "controlled", emitters = {{
        backend = "entity", particle = "wisplib:controlled_particle",
        motion = "controlled", spawn = {mode = "burst", count = 3},
        lifetime = 30, appearance = {scale = 0.1},
        controller = {type = "points", space = "local", points = {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}},
    }}},
    mesh = {schema = 1, motion = "controlled", emitters = {{
        backend = "mesh", container = "wisplib:mesh_emitter",
        motion = "controlled", settings = {count = 513, capacity = 512, size = 0.07, loop = true},
        controller = {type = "orbit", radius = 1.5, speed = 0.5},
    }}},
    billboard = {schema = 1, emitters = {{
        backend = "billboard", preset = {
            texture = "particles:smoke_0", lighting = false,
            collision = false, lifetime = 2, lifetime_spread = 0,
            size = {0.1, 0.1, 0.1}, max_distance = 100,
        }, spawn = {mode = "rate", rate = 10},
    }}},
    audio = {schema = 1, emitters = {}, audio = {{
        event = "on_start", type = "stream", resource = "base:sounds/ambient/rain_0.ogg",
        channel = "ambient", spatial = false, volume = 0, loop = true,
    }}},
}
for name, def in pairs(defs) do
    local ok, err = vfx.register("wisplib_client:" .. name, def)
    assert(ok, err)
end

local missing_texture = {schema = 1, emitters = {{
    backend = "billboard", preset = {texture = "particles:missing_wisplib_test", lifetime = 1},
    spawn = {mode = "burst", count = 1},
}}}
assert(vfx.register("wisplib_client:missing_texture", missing_texture))
local bad_effect, bad_error = vfx.spawn("wisplib_client:missing_texture", {position = center})
assert(bad_effect == nil and type(bad_error) == "string"
    and bad_error:find("particles:missing_wisplib_test", 1, true),
    "a billboard with an unavailable texture must fail with its alias")

local entity = assert(vfx.spawn("wisplib_client:entity", {
    anchor = {type = "entity", uid = uid}, space = "local",
}))
local mesh = assert(vfx.spawn("wisplib_client:mesh", {position = center}))
local billboard = assert(vfx.spawn("wisplib_client:billboard", {position = center}))
local sound = assert(vfx.spawn("wisplib_client:audio", {position = center}))
for _ = 1, 30 do tick() end
local stats = vfx.stats()
assert(stats.entities == 3, "Entity particles were not created")
assert(stats.mesh_particles == 513, "mesh must span two containers")
assert(stats.billboards == 1, "native billboard emitter was not created")
assert(stats.audio_speakers == 1, "audio cue did not start its stream")
assert(entity:state() == "running" and mesh:state() == "running")

anchor.transform:set_pos({center[1] + 3, center[2], center[3]})
for _ = 1, 4 do tick() end
local moved = 0
for _, candidate in ipairs(entities.get_all_in_radius({center[1] + 3, center[2], center[3]}, 2)) do
    if candidate ~= uid and entities.get_def(candidate) == entities.def_index("wisplib:controlled_particle") then
        moved = moved + 1
    end
end
assert(moved >= 3, "Entity particles failed to follow moving anchor")

assert(entity:pause())
assert(entity:resume())
assert(mesh:set_count(700))
for _ = 1, 4 do tick() end
assert(vfx.stats().mesh_particles == 700, "mesh count update failed")
assert(mesh:set_count(450))
for _ = 1, 2 do tick() end
assert(vfx.stats().mesh_particles == 450, "mesh count shrink failed")
assert(mesh:set_count(700))
for _ = 1, 2 do tick() end
assert(vfx.stats().mesh_particles == 700, "mesh count regrowth failed")

assert(entity:destroy())
assert(mesh:destroy())
assert(billboard:destroy())
assert(sound:destroy())
entities.despawn(uid)
for _ = 1, 3 do tick() end
stats = vfx.stats()
assert(stats.entities == 0 and stats.mesh_particles == 0 and stats.billboards == 0
    and stats.audio_speakers == 0,
    "client effect resources remained after destroy")

local bounds_second_x = 4
local bounds_skip_first = false
assert(vfx.register_controller("wisplib_client:bounds_controller", function()
    return {update_particle = function(_, _, _, context)
        if context.particle_index == 1 and bounds_skip_first then return nil end
        local offset = context.particle_index == 1 and 0 or bounds_second_x
        return {position = {center[1] + offset, center[2], center[3]},
            space = "world", scale = 1}
    end}
end))
assert(vfx.register("wisplib_client:bounds_mesh", {schema = 1, motion = "controlled", emitters = {{
    backend = "mesh", motion = "controlled", container = "wisplib:mesh_emitter",
    settings = {count = 2, size = 0.1, loop = true, bounds_model_radius = 1},
    controller = {type = "wisplib_client:bounds_controller"},
}}}))
local bounds_effect = assert(vfx.spawn("wisplib_client:bounds_mesh", {position = center}))
tick()
local bounds_host
for _, candidate in ipairs(entities.get_all_in_radius(center, 2)) do
    if entities.get_def(candidate) == entities.def_index("wisplib:mesh_emitter") then
        bounds_host = entities.get(candidate)
    end
end
assert(bounds_host, "controlled mesh host must exist")
local first_bound = bounds_host.transform:get_size()[1]
assert(first_bound > 4, "host culling box must include the far slot")
local far_matrix = bounds_host.skeleton:get_matrix(2)
local particle_scale = bounds_host:get_component("wisplib:mesh_emitter").get_particle_scale(2)
assert(math.abs(first_bound * far_matrix[13] - 4) < 0.01,
    "world position changed when culling bounds grew")
assert(math.abs(first_bound * far_matrix[1] - particle_scale[1]) < 0.01,
    "model scale changed when culling bounds grew")
bounds_skip_first, bounds_second_x = true, 8
tick()
local second_bound = bounds_host.transform:get_size()[1]
assert(second_bound > 8)
local old_matrix = bounds_host.skeleton:get_matrix(1)
far_matrix = bounds_host.skeleton:get_matrix(2)
assert(math.abs(second_bound * old_matrix[13]) < 0.01
    and math.abs(second_bound * far_matrix[13] - 8) < 0.01,
    "old and updated slots must retain positions when bounds grow")
assert(bounds_effect:destroy())
print("WISPLIB_CLIENT_RUNTIME_OK")
camera:stop()
app.close_world(true)
