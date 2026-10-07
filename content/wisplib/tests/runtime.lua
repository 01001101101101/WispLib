-- Run with VoxelCore --headless --test <this file> --project <project folder>.
local vfx

local function tick(count)
    for _ = 1, count do
        app.tick()
        vfx.update()
    end
end

app.reconfig_packs({"base", "wisplib"}, {})
app.new_world("wisplib-runtime-test-12", "8675320", "core:default")
vfx = require "wisplib:vfx"
assert(world.is_open())
assert(app.is_content_loaded())
assert(vfx.world.clear())

local definitions, definition_errors = vfx.list_definitions({placeable_only = true})
for _, definition_error in ipairs(definition_errors) do print("definition scan: " .. definition_error) end
assert(#definition_errors == 0, "installed library definitions should scan without errors")
assert(type(definitions) == "table", "definition listing should return a table")

local valid_parameter_refs, parameter_ref_error = vfx.validate("wisplib_tests:invalid_parameter_ref", {
    schema = 1,
    parameters = {count = {type = "number", default = 1}},
    emitters = {{
        backend = "entity", particle = "wisplib:controlled_particle",
        spawn = {mode = "burst", count = {parameter = "missing_count"}},
    }},
})
assert(not valid_parameter_refs and parameter_ref_error:find("unknown parameter missing_count", 1, true),
    "validator should identify references to undeclared effect parameters")

local custom_collision_hits = 0
assert(vfx.register_collision("wisplib_tests:test_collision", function(particle, context)
    return {
        position = {context.position[1] + context.dt, context.position[2], context.position[3]},
        velocity = context.velocity,
        hit = {position = context.position, normal = {0, 1, 0}},
    }
end))

local particle_def = entities.def_index("wisplib:controlled_particle")
local ignored_entities = {}
local function particles_near(position, radius)
    local result = {}
    for _, uid in ipairs(entities.get_all_in_radius(position, radius)) do
        if entities.get_def(uid) == particle_def and not ignored_entities[uid] then
            result[#result + 1] = entities.get(uid)
        end
    end
    return result
end

local anchor_entity = entities.spawn("wisplib:controlled_particle", {0, 40, 0})
local player_uid = anchor_entity:get_uid()
ignored_entities[player_uid] = true
tick(3)

local starts, spawns, collisions = 0, 0, 0
assert(vfx.register("wisplib_tests:vfx_runtime_points", {
    schema = 1,
    motion = "controlled",
    controller = {type = "points", space = "local", points = {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}},
    emitters = {{
        backend = "entity",
        particle = "wisplib:controlled_particle",
        motion = "controlled",
        spawn = {mode = "burst", count = 3},
        lifetime = 60,
        appearance = {scale = 0.08},
    }},
}))

assert(vfx.register("wisplib_tests:vfx_reference", {
    schema = 1,
    world = {placeable = true},
    motion = "controlled",
    parameters = {
        count = {type = "number", default = 24, min = 1, max = 128},
        size = {type = "number", default = 0.12, min = 0.03, max = 0.5},
        color = {type = "color", default = {0.2, 0.75, 1.0}},
    },
    emitters = {{
        backend = "entity", particle = "wisplib:controlled_particle", motion = "controlled",
        spawn = {mode = "burst", count = {parameter = "count"}}, lifetime = 60,
        appearance = {scale = {parameter = "size"}, color = {parameter = "color"}},
    }},
}))
assert(vfx.register("wisplib_tests:vfx_mesh_controlled", {
    schema = 1,
    world = {placeable = true},
    motion = "controlled",
    parameters = {count = {type = "number", default = 24, min = 1, max = 128}},
    emitters = {{
        backend = "mesh", container = "wisplib:mesh_emitter", motion = "controlled",
        settings = {count = {parameter = "count"}, capacity = 512, size = 0.055, loop = true},
        controller = {type = "points", space = "local", points = {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}},
    }},
}))

local fx = assert(vfx.spawn("wisplib_tests:vfx_runtime_points", {
    anchor = {type = "entity", uid = player_uid},
    space = "local",
    motion = "controlled",
    events = {
        on_start = function() starts = starts + 1 end,
        on_spawn = function() spawns = spawns + 1 end,
    },
}))
assert(starts == 1 and spawns == 3)
fx:on("on_collision", function() collisions = collisions + 1 end)
assert(fx:emit("on_collision", {test = true}))
assert(collisions == 1)
tick(2)

assert(vfx.register("wisplib_tests:vfx_runtime_custom_collision", {
    schema = 1,
    emitters = {{
        backend = "entity", particle = "wisplib:controlled_particle",
        spawn = {mode = "burst", count = 1}, lifetime = 5,
        collision = {type = "custom", id = "wisplib_tests:test_collision"},
    }},
}))
local custom_collision = assert(vfx.spawn("wisplib_tests:vfx_runtime_custom_collision", {position = {80, 60, 0}}))
custom_collision:on("on_collision", function() custom_collision_hits = custom_collision_hits + 1 end)
vfx.update(0.05)
assert(custom_collision_hits == 1, "custom collision extensions should emit collision events")
assert(custom_collision:destroy())

local raycast_target = entities.spawn("wisplib:controlled_particle", {80.5, 60, 0})
local raycast_target_uid = raycast_target:get_uid()
ignored_entities[raycast_target_uid] = true
local raycast_hits = 0
assert(vfx.register("wisplib_tests:vfx_runtime_raycast", {
    schema = 1,
    emitters = {{
        backend = "entity", particle = "wisplib:controlled_particle",
        spawn = {mode = "burst", count = 1}, lifetime = 5, velocity = {10, 0, 0},
        collision = {type = "raycast", gravity = {0, 0, 0}, radius = 0.04,
            response = "stop", entities = true, nonselect_entities = true},
    }},
}))
local raycast_effect = assert(vfx.spawn("wisplib_tests:vfx_runtime_raycast", {position = {80, 60, 0}}))
raycast_effect:on("on_collision", function(_, details)
    if details.entity == raycast_target_uid then raycast_hits = raycast_hits + 1 end
end)
vfx.update(0.1)
assert(raycast_hits == 1, "raycast mode should sweep particle movement against VoxelCore Entity raycasts")
assert(vfx.stats().raycasts > 0, "runtime stats should count VFX raycasts")
assert(raycast_effect:destroy())
entities.despawn(raycast_target_uid)

local particles = particles_near({0, 40, 0}, 5)
assert(#particles == 3, "controlled Entity backend should spawn three particles")
local positions = {}
for _, entity in ipairs(particles) do
    local p = entity.transform:get_pos()
    positions[string.format("%.0f,%.0f,%.0f", p[1], p[2], p[3])] = true
end
assert(positions["0,40,0"] and positions["1,40,0"] and positions["0,41,0"],
    "points controller must keep stable local coordinates around its Entity anchor")

anchor_entity.transform:set_pos({10, 40, 0})
tick(2)
particles = particles_near({10, 40, 0}, 5)
assert(#particles == 3, "controlled particles should follow the moved Entity anchor")
positions = {}
for _, entity in ipairs(particles) do
    local p = entity.transform:get_pos()
    positions[string.format("%.0f,%.0f,%.0f", p[1], p[2], p[3])] = true
end
assert(positions["10,40,0"] and positions["11,40,0"] and positions["10,41,0"])

assert(fx:set_points({{0, 0, 0}, {2, 0, 0}, {0, 2, 0}}))
tick(2)
particles = particles_near({10, 40, 0}, 5)
positions = {}
for _, entity in ipairs(particles) do
    local p = entity.transform:get_pos()
    positions[string.format("%.0f,%.0f,%.0f", p[1], p[2], p[3])] = true
end
assert(positions["10,40,0"] and positions["12,40,0"] and positions["10,42,0"],
    "set_points should update stable controlled slots at runtime")
assert(fx:set_count(5))
tick(2)
assert(#particles_near({10, 40, 0}, 5) == 5, "burst Entity count should be adjustable at runtime")
assert(fx:pause())
anchor_entity.transform:set_pos({14, 40, 0})
tick(2)
assert(#particles_near({10, 40, 0}, 5) == 5,
    "paused controlled particles should retain their previous transforms")
assert(fx:resume())
tick(2)
assert(#particles_near({14, 40, 0}, 5) == 5,
    "resumed controlled particles should follow the current anchor transform")

assert(vfx.register_controller("wisplib_tests:helix", function(config)
    return {
        update_particle = function(_, particle, dt, context)
            local t = context.effect_time * (config.speed or 1.2)
                + context.normalized_index * (config.turns or 2) * math.pi * 2
            local radius = config.radius or 1
            local height = (context.normalized_index - 0.5) * (config.height or 2)
            return {
                position = {math.cos(t) * radius, height, math.sin(t) * radius},
                rotation = mat4.idt(), scale = config.scale or 1,
                color = {0.2, 0.75, 1.0, 1.0}, space = config.space or "local",
            }
        end,
    }
end))
assert(vfx.register_path("wisplib_tests:helix_path", {
    evaluate = function(config, t)
        local angle = t * (config.turns or 2) * math.pi * 2
        local radius = config.radius or 1
        return {math.cos(angle) * radius, t * (config.height or 2), math.sin(angle) * radius}
    end,
}))
local helix = assert(vfx.spawn("wisplib_tests:vfx_reference", {
    anchor = {type = "entity", uid = player_uid}, space = "local", motion = "controlled",
    parameters = {count = 6}, controller = {type = "wisplib_tests:helix", radius = 0.8, height = 2},
}))
local path_stream = assert(vfx.spawn("wisplib_tests:vfx_reference", {
    anchor = {type = "entity", uid = player_uid}, space = "local", motion = "controlled",
    parameters = {count = 6}, controller = {
        type = "path", space = "local",
        path = {type = "wisplib_tests:helix_path", radius = 0.9, height = 2.4, turns = 2.5},
    },
}))
tick(2)
assert(#particles_near({10, 40, 0}, 5) >= 12,
    "registered controller and custom path should drive additional Entity transforms")
assert(helix:destroy() and path_stream:destroy())

assert(vfx.register_shape("wisplib_tests:star_shell", function(context, random)
    local index = context.particle_index or 1
    local count = math.max(1, context.particle_count or 1)
    local angle = (index - 1) / count * math.pi * 2 * 5
    local y = 1 - 2 * ((index - 0.5) / count)
    local radius = math.sqrt(math.max(0, 1 - y * y)) * (context.radius or 1)
    return {math.cos(angle) * radius, y * radius, math.sin(angle) * radius}
end))
assert(vfx.register("wisplib_tests:vfx_custom_star", {
    schema = 1,
    parameters = {count = {type = "number", default = 8, min = 1, max = 96}},
    emitters = {{
        backend = "entity", particle = "wisplib:controlled_particle",
        spawn = {mode = "burst", count = {parameter = "count"}},
        shape = {type = "wisplib_tests:star_shell", radius = 1.5},
        physics = {gravity = 0, linear_damping = 0.1}, lifetime = 12,
        appearance = {scale = 0.08, color = {0.2, 0.75, 1.0, 1.0}},
    }},
}))
local custom_shape = assert(vfx.spawn("wisplib_tests:vfx_custom_star", {
    position = {100, 60, 0}, parameters = {count = 8},
}))
tick(2)
assert(#particles_near({100, 60, 0}, 4) == 8,
    "registered custom shape should spawn one Entity at each deterministic index")
assert(custom_shape:destroy())

local mesh_controlled = assert(vfx.spawn("wisplib_tests:vfx_mesh_controlled", {
    position = {30, 60, 0}, motion = "controlled", parameters = {count = 6},
    points = {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {-1, 0, 0}, {0, -1, 0}, {0, 0, 1}},
}))
tick(2)
assert(vfx.stats().mesh_particles >= 6, "controlled mesh backend should create and update mesh slots")
local mesh_emitter_def = entities.def_index("wisplib:mesh_emitter")
local mesh_hosts = {}
for _, uid in ipairs(entities.get_all_in_radius({30, 60, 0}, 3)) do
    if entities.get_def(uid) == mesh_emitter_def then
        local host = entities.get(uid)
        if host then mesh_hosts[#mesh_hosts + 1] = host end
    end
end
assert(#mesh_hosts > 0, "mesh backend should create a host Entity")
for _, host in ipairs(mesh_hosts) do
    assert(not host.rigidbody:is_enabled(), "mesh host Entity must not run native physics")
    assert(math.abs(host.transform:get_pos()[2] - 60) < 0.01,
        "mesh host Entity should stay at its VFX transform instead of falling")
end
assert(mesh_controlled:destroy())

local parameter_effect = assert(vfx.spawn("wisplib_tests:vfx_reference", {
    position = {26, 55, 0}, parameters = {count = 3, size = 0.2, color = {0.8, 0.3, 0.1}},
}))
assert(parameter_effect:get_parameter("count") == 3)
assert(parameter_effect:set_parameter("count", 4))
assert(parameter_effect:get_parameter("count") == 4)
assert(parameter_effect:set_parameter("size", 0.3))
assert(math.abs(parameter_effect:get_parameter("size") - 0.3) < 0.001)
local invalid_parameter_ok = parameter_effect:set_parameter("size", "large")
assert(not invalid_parameter_ok, "typed parameter validation should reject a string for a number")
assert(#particles_near({26, 55, 0}, 4) == 4,
    "changing a count parameter should refresh the active burst emitter")
assert(parameter_effect:destroy())

anchor_entity.transform:set_pos({10, 40, 0})
tick(2)

local released, released_count = fx:release_particles({velocity = {0, 4, 0}})
assert(released and released_count == 5, "controlled Entity particles should release into rigidbody simulation")
for _, entity in ipairs(particles_near({10, 40, 0}, 5)) do
    assert(entity.rigidbody:is_enabled())
    assert(math.abs(entity.rigidbody:get_vel()[2] - 4) < 0.01)
end
assert(fx:destroy())

local deaths = 0
assert(vfx.register("wisplib_tests:vfx_runtime_short_lived", {
    schema = 1,
    motion = "controlled",
    controller = {type = "points", space = "world", points = {{100, 40, 0}}},
    emitters = {{
        backend = "entity",
        particle = "wisplib:controlled_particle",
        motion = "controlled",
        spawn = {mode = "burst", count = 1},
        lifetime = 0.05,
        appearance = {scale = 0.08},
    }},
}))
local short_lived = assert(vfx.spawn("wisplib_tests:vfx_runtime_short_lived", {
    motion = "controlled",
    events = {on_particle_death = function() deaths = deaths + 1 end},
}))
vfx.update(0.06)
app.tick()
vfx.update(0.02)
assert(deaths == 1, "controlled Entity particle should emit its lifetime death event once")
assert(short_lived:state() == "finished", "finite controlled Entity effect should finish after particle death")
assert(#particles_near({100, 40, 0}, 5) == 0, "expired controlled Entity particle should be despawned")

local source_entity = entities.spawn("wisplib:controlled_particle", {0, 50, 0})
local target_entity = entities.spawn("wisplib:controlled_particle", {8, 50, 0})
local source_uid, target_uid = source_entity:get_uid(), target_entity:get_uid()
ignored_entities[source_uid], ignored_entities[target_uid] = true, true
local link = assert(vfx.spawn("wisplib_tests:vfx_runtime_points", {
    source = {type = "entity", uid = source_uid},
    target = {type = "entity", uid = target_uid},
    controller = {type = "source_target"},
    motion = "controlled",
}))
tick(2)
local line_particles = particles_near({4, 50, 0}, 6)
assert(#line_particles == 3, "source_target should create controlled particles along two Entity anchors")
target_entity.transform:set_pos({14, 50, 0})
tick(2)
local moved_line_particles = particles_near({7, 50, 0}, 8)
assert(#moved_line_particles == 3, "source_target path should follow a moved target Entity")
assert(link:destroy())

local action_calls = 0
assert(vfx.register_callback("wisplib_tests:runtime_event", function(handle, details, args)
    action_calls = action_calls + (args.increment or 1)
end))
assert(vfx.register("wisplib_tests:vfx_runtime_event_action", {
    schema = 1,
    motion = "controlled",
    controller = {type = "points", points = {{0, 0, 0}}},
    events = {on_collision = {{type = "callback", id = "wisplib_tests:runtime_event", arguments = {increment = 3}}}},
    emitters = {{
        backend = "entity", particle = "wisplib:controlled_particle", motion = "controlled",
        spawn = {mode = "burst", count = 1}, lifetime = 20,
    }},
}))
local action_effect = assert(vfx.spawn("wisplib_tests:vfx_runtime_event_action", {position = {45, 50, 0}}))
assert(action_effect:emit("on_collision", {test = true}))
assert(action_calls == 3, "definition actions should invoke registered pack callbacks")
assert(action_effect:destroy())

local persistent = assert(vfx.world.create("wisplib_tests:vfx_runtime_points", {
    name = "headless_round_trip",
    position = {20, 50, 0},
    anchor = {type = "world", position = {20, 50, 0}, rotation = mat4.idt(),
        scale = {2, 2, 2}, inherit_scale = true},
    controller = {type = "points", space = "local", points = {{0, 0, 0}, {0, 1, 0}}},
    motion = "controlled",
    tags = {"runtime-test", "controlled"},
}))
assert(persistent.id == "world_fx_1")
assert(vfx.world.save())
local world_effect_path = pack.data_file("wisplib", "world_effects.json")
local good_world_effects = file.read(world_effect_path)
assert(type(good_world_effects) == "string" and #good_world_effects > 0)
file.write(world_effect_path, '{"schema":99,"effects":[]}')
local malformed_ok = vfx.world.load()
assert(malformed_ok == false and persistent:exists(),
    "invalid saved schema must leave active WorldEffect records intact")
file.write(world_effect_path, good_world_effects)
vfx.world.stop_runtime()
local loaded, load_errors = vfx.world.load()
assert(loaded and #load_errors == 0)
local restored = assert(vfx.world.get_by_name("headless_round_trip"))
assert(restored:exists() and restored:get("position")[1] == 20)
assert(restored:get("anchor").inherit_scale == true
    and restored:get("anchor").position[1] == 20,
    "WorldEffect must restore a serializable static anchor configuration")
tick(2)
local anchored_particles = particles_near({20, 50, 0}, 5)
local has_scaled_anchor_point = false
for _, entity in ipairs(anchored_particles) do
    local p = entity.transform:get_pos()
    if math.abs(p[2] - 52) < 0.01 then has_scaled_anchor_point = true end
end
assert(has_scaled_anchor_point,
    "restored WorldEffect anchor scale should affect local controlled point placement")
assert(#vfx.world.find_by_tag("runtime-test") == 1)
local dormant = assert(vfx.world.create("wisplib_tests:vfx_reference", {
    name = "dormant_record", position = {24, 50, 0}, enabled = true, autostart = false,
    motion = "controlled", controller = {type = "orbit", radius = 0.5},
}))
assert(dormant:get("runtime_state") == "stopped")
local duplicate = assert(vfx.world.duplicate(dormant.id, {name = "dormant_copy"}))
assert(duplicate.id ~= dormant.id and duplicate:get("name") == "dormant_copy")
assert(duplicate:delete())
assert(vfx.world.save())
vfx.world.stop_runtime()
loaded, load_errors = vfx.world.load()
assert(loaded and #load_errors == 0)
assert(vfx.world.get_by_name("dormant_record"):get("runtime_state") == "stopped",
    "autostart=false WorldEffect must restore its record without starting particles")
assert(vfx.world.get_by_name("dormant_record"):start())
assert(vfx.world.get_by_name("dormant_record"):get("runtime_state") == "running")
local entity_anchor, entity_error = vfx.world.create("wisplib_tests:vfx_runtime_points", {
    anchor = {type = "entity", uid = player_uid},
})
assert(entity_anchor == nil and entity_error:find("cannot be persisted"))
assert(vfx.world.clear())

app.close_world(true)
app.delete_world("wisplib-runtime-test-12")
print("WispLib headless runtime tests passed")
