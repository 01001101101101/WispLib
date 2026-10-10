-- Public VFX API. Definitions are loaded from <pack>:effects/<name>.effect.json.
-- Backends intentionally stay inside this module so consumers only own handles.
local API = {API_VERSION = "0.3.0", SCHEMA_VERSION = 1}
local screenfx = require "wisplib:screenfx"

local definitions = {}
local instances = {}
local world_effects = {}
local event_handlers = {}
local shape_extensions = {}
local controller_extensions = {}
local path_extensions = {}
local modifier_extensions = {}
local collision_extensions = {}
local action_callbacks = {}
local raycasts_this_update = 0
local action_spawn_depth = 0
local MAX_ACTION_SPAWN_DEPTH = 32
local next_id = 1
local generation = 1
local last_update = time.precise_time()
local fire_event
local play_effect_audio_event
local current_position

local Handle = {}
Handle.__index = Handle

local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = clone(item) end
    return result
end

local function merge(base, extra)
    local result = clone(base or {})
    for key, value in pairs(extra or {}) do
        if type(value) == "table" and type(result[key]) == "table" then
            result[key] = merge(result[key], value)
        else
            result[key] = clone(value)
        end
    end
    return result
end

local function split_id(id)
    if type(id) ~= "string" then return nil, nil end
    local pack, name = id:match("^([^:]+):(.+)$")
    return pack, name
end

local function read_json(uri)
    local ok, result = pcall(function()
        return json.parse(file.read(uri))
    end)
    if not ok then return nil, tostring(result) end
    if type(result) ~= "table" then return nil, "JSON root must be an object" end
    return result
end

local function load_definition(id)
    if definitions[id] then return definitions[id] end
    local pack, name = split_id(id)
    if not pack then return nil, "effect id must use a namespace, for example mypack:my_effect" end
    local path = pack .. ":effects/" .. name .. ".effect.json"
    local def, err = read_json(path)
    if not def then return nil, "cannot load " .. path .. ": " .. err end
    local ok, validation = API.validate(id, def)
    if not ok then return nil, validation end
    definitions[id] = def
    return def
end

local function is_vec3(value)
    return type(value) == "table" and type(value[1]) == "number"
        and type(value[2]) == "number" and type(value[3]) == "number"
end

local function finite_number(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function finite_vec3(value)
    return is_vec3(value) and finite_number(value[1])
        and finite_number(value[2]) and finite_number(value[3])
end

local function finite_mat4(value)
    if type(value) ~= "table" or #value ~= 16 then return false end
    for index = 1, 16 do if not finite_number(value[index]) then return false end end
    return true
end

local EFFECT_AUDIO_EVENTS = {
    on_start = true, on_spawn = true, on_collision = true,
    on_particle_death = true, on_stop = true, on_finished = true,
}
local EFFECT_AUDIO_CHANNELS = {
    regular = true, music = true, ambient = true, ui = true,
}

local function normalize_audio_sources(id, value, label)
    label = label or (tostring(id) .. ": audio")
    if value == nil then return {} end
    if type(value) ~= "table" then return nil, label .. " must be an audio source or an array of sources" end
    local sources = value
    if value.type ~= nil or value.event ~= nil or value.resource ~= nil then
        sources = {value}
    end
    local result = {}
    for index, source in ipairs(sources) do
        local source_label = label .. " source " .. index
        if type(source) ~= "table" then return nil, source_label .. " must be an object" end
        if source.type ~= "sound" and source.type ~= "stream" then
            return nil, source_label .. ".type must be sound or stream"
        end
        if type(source.resource) ~= "string" or source.resource == "" then
            return nil, source_label .. ".resource must be a non-empty asset ID or resource path"
        end
        if not EFFECT_AUDIO_EVENTS[source.event] then
            return nil, source_label .. ".event must be a supported VFX event"
        end
        if source.type == "stream" then
            local extension = source.resource:match("(%.[^./:]+)$")
            if extension ~= ".ogg" and extension ~= ".OGG"
                and extension ~= ".wav" and extension ~= ".WAV" then
                return nil, source_label .. ".resource must point to a .ogg or .wav stream"
            end
        end
        if source.volume ~= nil and (not finite_number(source.volume) or source.volume < 0 or source.volume > 1) then
            return nil, source_label .. ".volume must be in [0, 1]"
        end
        if source.pitch ~= nil and (not finite_number(source.pitch) or source.pitch <= 0) then
            return nil, source_label .. ".pitch must be a positive finite number"
        end
        if source.channel ~= nil and (type(source.channel) ~= "string" or not EFFECT_AUDIO_CHANNELS[source.channel]) then
            return nil, source_label .. ".channel must be regular, music, ambient, or ui"
        end
        for _, key in ipairs({"loop", "spatial", "follow", "stop_on_stop", "stop_on_finish", "stop_on_destroy"}) do
            if source[key] ~= nil and type(source[key]) ~= "boolean" then
                return nil, source_label .. "." .. key .. " must be boolean"
            end
        end
        if source.loop == true and source.event ~= "on_start" then
            return nil, source_label .. " looping audio must use event on_start"
        end
        if source.offset ~= nil and not finite_vec3(source.offset) then
            return nil, source_label .. ".offset must be a finite vec3"
        end
        local normalized = clone(source)
        normalized.volume = source.volume == nil and 1 or source.volume
        normalized.pitch = source.pitch == nil and 1 or source.pitch
        normalized.channel = source.channel or "regular"
        normalized.loop = source.loop == true
        normalized.spatial = source.spatial ~= false
        if source.follow == nil then normalized.follow = normalized.spatial and normalized.loop
        else normalized.follow = source.follow end
        normalized.offset = clone(source.offset or {0, 0, 0})
        if source.stop_on_stop == nil then normalized.stop_on_stop = normalized.loop
        else normalized.stop_on_stop = source.stop_on_stop end
        if source.stop_on_finish == nil then normalized.stop_on_finish = normalized.loop
        else normalized.stop_on_finish = source.stop_on_finish end
        if source.stop_on_destroy == nil then normalized.stop_on_destroy = normalized.loop or normalized.follow
        else normalized.stop_on_destroy = source.stop_on_destroy end
        if not normalized.spatial and normalized.follow then
            return nil, source_label .. " cannot follow an effect when spatial is false"
        end
        if not normalized.spatial and (normalized.offset[1] ~= 0
            or normalized.offset[2] ~= 0 or normalized.offset[3] ~= 0) then
            return nil, source_label .. " cannot use a positional offset when spatial is false"
        end
        result[#result + 1] = normalized
    end
    if #result == 0 and next(sources) ~= nil then
        return nil, label .. " must be an array of audio sources"
    end
    return result
end

local function valid_anchor(anchor)
    if type(anchor) ~= "table" then return false end
    if anchor.type == "world" then
        if anchor.position ~= nil and not finite_vec3(anchor.position) then return false end
        if anchor.scale ~= nil and not finite_vec3(anchor.scale) then return false end
        if anchor.rotation ~= nil and not finite_mat4(anchor.rotation) then return false end
        if anchor.inherit_scale ~= nil and type(anchor.inherit_scale) ~= "boolean" then return false end
        return true
    elseif anchor.type == "entity" then
        local uid = tonumber(anchor.uid)
        return finite_number(uid) and uid >= 0 and uid % 1 == 0
            and (anchor.offset == nil or finite_vec3(anchor.offset))
    end
    return false
end

local function vadd(a, b)
    return {a[1] + b[1], a[2] + b[2], a[3] + b[3]}
end

local function vsub(a, b)
    return {a[1] - b[1], a[2] - b[2], a[3] - b[3]}
end

local function vmul(a, scalar)
    return {a[1] * scalar, a[2] * scalar, a[3] * scalar}
end

local function vlen(a)
    return math.sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3])
end

local function vnorm(a)
    local length = vlen(a)
    if length < 0.000001 then return {0, 1, 0} end
    return vmul(a, 1.0 / length)
end

local function vhadamard(a, b)
    return {a[1] * b[1], a[2] * b[2], a[3] * b[3]}
end

local function matrix_or_identity(value)
    if type(value) == "table" and #value == 16 then return clone(value) end
    return mat4.idt()
end

local function rotate_vector(rotation, vector)
    local ok, result = pcall(mat4.mul, rotation, vector)
    if ok and finite_vec3(result) then return result end
    return clone(vector)
end

local function point_in_transform(transform, point, inherit_scale)
    local local_point = clone(point)
    if inherit_scale then local_point = vhadamard(local_point, transform.scale) end
    return vadd(transform.position, rotate_vector(transform.rotation, local_point))
end

local function resolve_anchor(anchor, fallback)
    if type(anchor) ~= "table" then return clone(fallback), false end
    if anchor.type == "world" then
        local position = anchor.position or {0, 0, 0}
        if not finite_vec3(position) then return clone(fallback), false end
        return {
            position = clone(position),
            rotation = matrix_or_identity(anchor.rotation),
            scale = finite_vec3(anchor.scale) and clone(anchor.scale) or {1, 1, 1},
        }, true
    elseif anchor.type == "entity" then
        local uid = tonumber(anchor.uid)
        if not finite_number(uid) or uid < 0 or uid % 1 ~= 0 or not entities.exists(uid) then
            return clone(fallback), false
        end
        local ok, target = pcall(entities.get, uid)
        if not ok or not target then return clone(fallback), false end
        local success, result = pcall(function()
            return {
                position = target.transform:get_pos(),
                rotation = target.transform:get_rot(),
                scale = target.transform:get_size(),
            }
        end)
        if not success or not finite_vec3(result.position) then return clone(fallback), false end
        local offset = anchor.offset or {0, 0, 0}
        if finite_vec3(offset) then
            result.position = point_in_transform(result, offset, anchor.inherit_scale == true)
        end
        return result, true
    end
    return clone(fallback), false
end

local function effect_transform(effect)
    local anchor, valid = resolve_anchor(effect.anchor, effect.last_transform)
    if not anchor then
        anchor = {position = clone(effect.position), rotation = mat4.idt(), scale = {1, 1, 1}}
    end
    effect.anchor_valid = valid
    if valid then effect.last_transform = clone(anchor) end

    local explicit_anchor = effect.anchor ~= nil
    local space = effect.space or "world"
    local position
    if space == "world" or (not explicit_anchor and effect.legacy_parent) then
        position = clone(effect.position)
        if effect.legacy_parent and entities.exists(effect.parent_uid) then
            local ok, parent = pcall(entities.get, effect.parent_uid)
            if ok and parent then
                position = vadd(parent.transform:get_pos(), effect.parent_offset)
                effect.last_parent_position = clone(position)
            end
        elseif effect.legacy_parent and effect.last_parent_position then
            position = clone(effect.last_parent_position)
        end
    else
        position = point_in_transform(anchor, effect.position, effect.inherit_scale)
    end
    local rotation = effect.local_rotation or mat4.idt()
    if effect.inherit_rotation then
        local ok, combined = pcall(mat4.mul, anchor.rotation, rotation)
        if ok then rotation = combined end
    end
    return {
        position = position,
        rotation = rotation,
        scale = effect.inherit_scale and clone(anchor.scale) or {1, 1, 1},
        anchor = anchor,
        anchor_valid = valid,
    }
end

local function rng_for(seed)
    local state = math.floor(math.abs(tonumber(seed) or 1)) % 2147483647
    if state == 0 then state = 1 end
    return function()
        state = (state * 48271) % 2147483647
        return (state - 1) / 2147483646
    end
end

local function random_range(value, random)
    if type(value) == "number" then return value end
    if type(value) == "table" and type(value[1]) == "number"
        and type(value[2]) == "number" then
        return value[1] + (value[2] - value[1]) * random()
    end
    return tonumber(value) or 0
end

local function sample_scale(value, random, fallback)
    fallback = fallback or {1, 1, 1}
    if type(value) == "number" then return {value, value, value} end
    if finite_vec3(value) then return clone(value) end
    if type(value) == "table" and value.min ~= nil and value.max ~= nil then
        local minimum = type(value.min) == "number" and {value.min, value.min, value.min} or value.min
        local maximum = type(value.max) == "number" and {value.max, value.max, value.max} or value.max
        if finite_vec3(minimum) and finite_vec3(maximum) then
            return {
                random_range({minimum[1], maximum[1]}, random),
                random_range({minimum[2], maximum[2]}, random),
                random_range({minimum[3], maximum[3]}, random),
            }
        end
    end
    return clone(fallback)
end

local function sample_color(value, random)
    if type(value) == "table" and type(value.min) == "table" and type(value.max) == "table" then
        local color = {}
        for channel = 1, 4 do
            local low = tonumber(value.min[channel]) or (channel == 4 and 1 or 1)
            local high = tonumber(value.max[channel]) or low
            color[channel] = math.max(0, math.min(1, random_range({low, high}, random)))
        end
        return color
    end
    if type(value) ~= "table" then return nil end
    local color = clone(value)
    if #color == 3 then color[4] = 1 end
    for channel = 1, 4 do color[channel] = math.max(0, math.min(1, tonumber(color[channel]) or 1)) end
    return color
end


local function curve_sample(curve, t, fallback)
    if type(curve) ~= "table" or #curve == 0 then return fallback end
    local left = curve[1]
    if t <= left[1] then return left[2] end
    for index = 2, #curve do
        local right = curve[index]
        if t <= right[1] then
            local span = math.max(0.000001, right[1] - left[1])
            local factor = math.max(0, math.min(1, (t - left[1]) / span))
            if type(left[2]) == "number" then
                return left[2] + (right[2] - left[2]) * factor
            end
            local value = {}
            for channel = 1, #left[2] do
                value[channel] = left[2][channel] + (right[2][channel] - left[2][channel]) * factor
            end
            return value
        end
        left = right
    end
    return left[2]
end

local function apply_alpha(color, curve, t, opacity)
    if type(color) ~= "table" then return color end
    local result = clone(color)
    if #result == 3 then result[4] = 1 end
    local alpha = curve_sample(curve, t, opacity or 1)
    for channel = 1, 3 do result[channel] = math.max(0, math.min(1, tonumber(result[channel]) or 1)) end
    result[4] = math.max(0, math.min(1, (tonumber(result[4]) or 1) * (tonumber(alpha) or 1)))
    return result
end

local function resolve(value, effect, random)
    if type(value) ~= "table" then return value end
    if value.parameter then
        local result = effect.parameters[value.parameter]
        if result == nil and value.parameter == "scale" then result = effect.scale end
        if result == nil then result = value.default end
        if type(result) == "number" then
            result = result * (value.multiply or 1) + (value.add or 0)
        elseif type(result) == "table" and type(value.multiply) == "number" then
            result = clone(result)
            for index = 1, #result do result[index] = result[index] * value.multiply end
        end
        return result
    end
    if type(value.range) == "table" then
        return random_range(value.range, random)
    end
    local result = {}
    for key, item in pairs(value) do result[key] = resolve(item, effect, random) end
    return result
end

local function uniform_direction(random)
    local y = random() * 2 - 1
    local angle = random() * math.pi * 2
    local radial = math.sqrt(math.max(0, 1 - y * y))
    return {math.cos(angle) * radial, y, math.sin(angle) * radial}
end

local function sample_shape(shape, random, context)
    shape = shape or {type = "point"}
    local kind = shape.type or "point"
    if kind == "sphere" then
        return vmul(uniform_direction(random), random_range(shape.radius or 1, random)
            * math.pow(random(), 1 / 3))
    elseif kind == "box" then
        local size = shape.size or {1, 1, 1}
        return {
            (random() - 0.5) * size[1],
            (random() - 0.5) * size[2],
            (random() - 0.5) * size[3],
        }
    elseif kind == "ring" or kind == "disk" then
        local inner = shape.inner_radius or 0
        local outer = shape.radius or 1
        local radius = math.sqrt(inner * inner + random() * (outer * outer - inner * inner))
        local angle = random() * math.pi * 2
        return {math.cos(angle) * radius, 0, math.sin(angle) * radius}
    elseif kind == "line" then
        local from = shape.from or {0, 0, 0}
        local to = shape.to or {0, 1, 0}
        return vadd(from, vmul(vsub(to, from), random()))
    elseif kind == "cone" then
        local height = shape.height or 1
        local t = random()
        local radius = (shape.radius or 1) * (1 - t)
        local angle = random() * math.pi * 2
        local radial = radius * math.sqrt(random())
        return {math.cos(angle) * radial, height * t, math.sin(angle) * radial}
    end
    local extension = shape_extensions[kind]
    if extension then
        local ok, point = pcall(extension, context or {}, random)
        if ok and finite_vec3(point) then return clone(point) end
        error("custom shape " .. tostring(kind) .. " failed: " .. tostring(point))
    end
    return {0, 0, 0}
end

local function valid_extension_id(id)
    local pack, name = split_id(id)
    return pack ~= nil and name ~= nil
end

function API.register_shape(id, provider)
    if not valid_extension_id(id) then return false, "shape id must be namespaced" end
    if type(provider) ~= "function" then return false, "shape provider must be a function" end
    shape_extensions[id] = provider
    return true
end

function API.register_controller(id, factory)
    if not valid_extension_id(id) then return false, "controller id must be namespaced" end
    if type(factory) ~= "function" and type(factory) ~= "table" then
        return false, "controller must be a factory function or controller table"
    end
    controller_extensions[id] = factory
    return true
end

function API.register_path(id, provider)
    if not valid_extension_id(id) then return false, "path id must be namespaced" end
    if type(provider) ~= "table" or type(provider.evaluate) ~= "function" then
        return false, "path provider must be a table with evaluate(config, t, context)"
    end
    path_extensions[id] = provider
    return true
end

function API.register_modifier(id, updater)
    if not valid_extension_id(id) then return false, "modifier id must be namespaced" end
    if type(updater) ~= "function" then return false, "modifier must be a function" end
    modifier_extensions[id] = updater
    return true
end

function API.register_collision(id, resolver)
    if not valid_extension_id(id) then return false, "collision id must be namespaced" end
    if type(resolver) ~= "function" then return false, "collision resolver must be a function" end
    collision_extensions[id] = resolver
    return true
end

function API.register_callback(id, callback)
    if not valid_extension_id(id) then return false, "callback id must be namespaced" end
    if type(callback) ~= "function" then return false, "callback must be a function" end
    action_callbacks[id] = callback
    return true
end

local function cubic_bezier(points, t)
    local u = 1 - t
    local a, b, c, d = points[1], points[2], points[3], points[4]
    return {
        u*u*u*a[1] + 3*u*u*t*b[1] + 3*u*t*t*c[1] + t*t*t*d[1],
        u*u*u*a[2] + 3*u*u*t*b[2] + 3*u*t*t*c[2] + t*t*t*d[2],
        u*u*u*a[3] + 3*u*u*t*b[3] + 3*u*t*t*c[3] + t*t*t*d[3],
    }
end

local function path_evaluate(config, t, context)
    t = tonumber(t)
    if not finite_number(t) then t = 0 end
    t = math.max(0, math.min(1, t))
    local kind = config.type or "line"
    if kind == "line" then
        local from, to = config.from or {0, 0, 0}, config.to or {0, 1, 0}
        return vadd(from, vmul(vsub(to, from), t))
    elseif kind == "circle" then
        local angle = (config.start_angle or 0) + t * math.pi * 2 * (config.turns or 1)
        local axis = vnorm(config.axis or {0, 1, 0})
        local guide = math.abs(axis[2]) < 0.9 and {0, 1, 0} or {1, 0, 0}
        local right = vnorm({axis[2] * guide[3] - axis[3] * guide[2], axis[3] * guide[1] - axis[1] * guide[3], axis[1] * guide[2] - axis[2] * guide[1]})
        local forward = {axis[2] * right[3] - axis[3] * right[2], axis[3] * right[1] - axis[1] * right[3], axis[1] * right[2] - axis[2] * right[1]}
        return vadd(config.center or {0, 0, 0}, vadd(vmul(right, math.cos(angle) * (config.radius or 1)), vmul(forward, math.sin(angle) * (config.radius or 1))))
    elseif kind == "polyline" then
        local points = config.points or {}
        if #points == 0 then return {0, 0, 0} end
        if #points == 1 then return clone(points[1]) end
        local scaled = t * (#points - 1)
        local segment = math.min(#points - 1, math.floor(scaled) + 1)
        local local_t = segment == #points and 1 or scaled - (segment - 1)
        return vadd(points[segment], vmul(vsub(points[segment + 1], points[segment]), local_t))
    elseif kind == "bezier" then
        if type(config.points) ~= "table" or #config.points ~= 4 then
            error("bezier path requires exactly four control points")
        end
        return cubic_bezier(config.points, t)
    end
    local extension = path_extensions[kind]
    if extension then
        local ok, point = pcall(extension.evaluate, config, t, context)
        if ok and finite_vec3(point) then return clone(point) end
        if not ok then error("custom path " .. tostring(kind) .. " failed: " .. tostring(point)) end
    end
    error("unknown path type " .. tostring(kind))
end

local Path = {}
Path.__index = Path
function Path:evaluate(t) return path_evaluate(self.definition, t) end
function API.path(definition)
    if type(definition) ~= "table" then return nil, "path definition must be a table" end
    local kind = definition.type or "line"
    if kind == "line" then
        if definition.from ~= nil and not finite_vec3(definition.from) then
            return nil, "line path from must be a finite vec3"
        end
        if definition.to ~= nil and not finite_vec3(definition.to) then
            return nil, "line path to must be a finite vec3"
        end
    elseif kind == "circle" then
        if definition.center ~= nil and not finite_vec3(definition.center) then
            return nil, "circle path center must be a finite vec3"
        end
        if definition.axis ~= nil and not finite_vec3(definition.axis) then
            return nil, "circle path axis must be a finite vec3"
        end
        if definition.radius ~= nil and (not finite_number(definition.radius) or definition.radius < 0) then
            return nil, "circle path radius must be non-negative and finite"
        end
        if definition.turns ~= nil and not finite_number(definition.turns) then
            return nil, "circle path turns must be finite"
        end
        if definition.start_angle ~= nil and not finite_number(definition.start_angle) then
            return nil, "circle path start_angle must be finite"
        end
    end
    if kind == "bezier" and (type(definition.points) ~= "table" or #definition.points ~= 4) then
        return nil, "bezier path requires exactly four control points"
    end
    if kind == "polyline" and type(definition.points) ~= "table" then
        return nil, "polyline path points must be an array"
    end
    if kind == "polyline" or kind == "bezier" then
        for index, point in ipairs(definition.points or {}) do
            if not finite_vec3(point) then return nil, "path point " .. index .. " must be a finite vec3" end
        end
    end
    if kind ~= "line" and kind ~= "circle" and kind ~= "polyline" and kind ~= "bezier" and not path_extensions[kind] then
        return nil, "unknown path type " .. tostring(kind)
    end
    return setmetatable({definition = clone(definition)}, Path)
end

local function initial_velocity(def, random, position)
    local velocity = def.velocity or {0, 0, 0}
    if type(velocity) == "table" and velocity.type == "radial" then
        local direction = vnorm(position or uniform_direction(random))
        local speed = random_range(velocity.speed or {0, 1}, random)
        direction[2] = direction[2] + (velocity.vertical_bias or 0)
        return vmul(vnorm(direction), speed)
    end
    if is_vec3(velocity) then return clone(velocity) end
    return {0, 0, 0}
end

local function safe_call(object, method, ...)
    if not object then return false end
    local ok, fn = pcall(function() return object[method] end)
    if not ok or type(fn) ~= "function" then return false end
    return pcall(fn, object, ...)
end

local function get_instance(handle)
    if type(handle) ~= "table" then return nil end
    local instance = instances[handle.id]
    if not instance or instance.generation ~= handle.generation then return nil end
    return instance
end

fire_event = function(effect, event, details)
    local handle = setmetatable({id = effect.id, generation = effect.generation}, Handle)
    local called = 0
    play_effect_audio_event(effect, event, details)
    local handlers = event_handlers[effect.id]
    local callbacks = {}
    for _, callback in ipairs(handlers and handlers[event] or {}) do callbacks[#callbacks + 1] = callback end
    for _, callback in ipairs(callbacks) do
        local ok, err = pcall(callback, handle, clone(details or {}))
        if ok then called = called + 1 else effect.callback_error = tostring(err) end
    end
    local actions = effect.definition.events and effect.definition.events[event]
    if actions then
        if type(actions) == "table" and actions.type then actions = {actions} end
        for _, action in ipairs(type(actions) == "table" and actions or {}) do
            if type(action) == "table" then
                local ok, err = pcall(function()
                    if action.type == "spawn_effect" then
                        if action_spawn_depth >= MAX_ACTION_SPAWN_DEPTH then
                            error("spawn_effect recursion exceeded " .. MAX_ACTION_SPAWN_DEPTH .. " levels")
                        end
                        local position = action.position or (details and details.position) or current_position(effect)
                        action_spawn_depth = action_spawn_depth + 1
                        local spawned, child, child_error = pcall(API.spawn, action.effect, {
                            position = clone(position), parameters = clone(action.parameters or {}),
                            scale = action.scale, seed = action.seed,
                        })
                        action_spawn_depth = action_spawn_depth - 1
                        if not spawned then error(child) end
                        if not child then error(child_error) end
                    elseif action.type == "change_parameter" then
                        local value = action.value
                        if type(value) == "table" and value.parameter then value = effect.parameters[value.parameter] end
                        local changed, change_error = API.set(handle, action.name, value)
                        if not changed then error(change_error) end
                    elseif action.type == "release_particles" then
                        local released, release_error = API.release_particles(handle, action.options or {})
                        if not released then error(release_error) end
                    elseif action.type == "callback" then
                        local callback = action_callbacks[action.id]
                        if not callback then error("unregistered event callback " .. tostring(action.id)) end
                        callback(handle, clone(details or {}), clone(action.arguments or {}))
                    elseif action.type == "destroy_particle" then
                        local uid = details and details.uid
                        if uid and entities.exists(uid) then entities.despawn(uid) end
                    else
                        error("unknown event action " .. tostring(action.type))
                    end
                end)
                if ok then called = called + 1 else effect.action_error = tostring(err) end
            end
        end
    end
    return called
end

function API.on(handle, event, callback)
    local effect = get_instance(handle)
    local supported = {on_start = true, on_spawn = true, on_collision = true,
        on_particle_death = true, on_stop = true, on_finished = true}
    if not effect then return false, "effect handle is no longer valid" end
    if not supported[event] then return false, "unsupported event " .. tostring(event) end
    if type(callback) ~= "function" then return false, "event callback must be a function" end
    event_handlers[effect.id] = event_handlers[effect.id] or {}
    event_handlers[effect.id][event] = event_handlers[effect.id][event] or {}
    table.insert(event_handlers[effect.id][event], callback)
    return true
end

function API.emit(handle, event, details)
    local effect = get_instance(handle)
    if not effect then return false, "effect handle is no longer valid" end
    local supported = {on_collision = true, on_particle_death = true, on_spawn = true}
    if not supported[event] then return false, "only particle events may be emitted by extensions" end
    fire_event(effect, event, details)
    return true
end

local function validate_controller_config(id, label, config)
    if config == nil then return true end
    if type(config) ~= "table" or type(config.type) ~= "string" then
        return false, id .. ": " .. label .. " needs a string type"
    end
    local kind = config.type
    local built_in = {follow = true, orbit = true, points = true, path = true, source_target = true}
    if kind == "script" then
        if not valid_extension_id(config.module) then
            return false, id .. ": " .. label .. " script controller needs a namespaced module"
        end
    elseif not built_in[kind] and not controller_extensions[kind] then
        if not valid_extension_id(kind) then
            return false, id .. ": " .. label .. " has unknown controller " .. tostring(kind)
        end
        return false, id .. ": " .. label .. " controller " .. kind .. " is not registered"
    end
    if config.space ~= nil and config.space ~= "world" and config.space ~= "local" and config.space ~= "parent" then
        return false, id .. ": " .. label .. " space must be world, local, or parent"
    end
    if kind == "points" then
        if config.points ~= nil then
            if type(config.points) ~= "table" then return false, id .. ": " .. label .. " points must be an array" end
            for index, point in ipairs(config.points) do
                if not finite_vec3(point) then return false, id .. ": " .. label .. " point " .. index .. " is not a finite vec3" end
            end
        end
    elseif kind == "path" then
        local path, err = API.path(config.path or config)
        if not path then return false, id .. ": " .. label .. " path: " .. tostring(err) end
    end
    return true
end

local function valid_parameter_reference(value, parameters, allowed_types)
    if type(value) ~= "table" or type(value.parameter) ~= "string" then return false end
    local name = value.parameter
    local spec = name == "scale" and {type = "number"} or (parameters or {})[name]
    if not spec or not allowed_types[spec.type] then return false end
    if value.multiply ~= nil and not finite_number(value.multiply) then return false end
    if value.add ~= nil and (spec.type ~= "number" or not finite_number(value.add)) then return false end
    return true
end

local function valid_scale_parameter_reference(value, parameters)
    if type(value) ~= "table" or type(value.parameter) ~= "string" then return false end
    local multiplier = value.multiply == nil and 1 or value.multiply
    local addition = value.add == nil and 0 or value.add
    if not finite_number(multiplier) or not finite_number(addition) or multiplier < 0 then return false end
    if value.parameter == "scale" then return addition >= 0 end
    local spec = (parameters or {})[value.parameter]
    if spec == nil or spec.type ~= "number" or not finite_number(spec.min)
        or not finite_number(spec.max) or spec.min < 0 then return false end
    local minimum = spec.min * multiplier + addition
    local maximum = spec.max * multiplier + addition
    return finite_number(minimum) and minimum >= 0 and finite_number(maximum) and maximum >= 0
end

local function validate_shape_config(id, label, shape, parameters)
    if shape == nil then return true end
    if type(shape) ~= "table" then return false, id .. ": " .. label .. " shape must be an object" end
    local kind = shape.type or "point"
    local builtin = {point = true, sphere = true, box = true, ring = true, disk = true, line = true, cone = true}
    if not builtin[kind] and not shape_extensions[kind] then
        if not valid_extension_id(kind) then return false, id .. ": " .. label .. " has unknown shape " .. tostring(kind) end
        return false, id .. ": " .. label .. " shape " .. kind .. " is not registered"
    end
    local size_is_parameter = valid_parameter_reference(shape.size, parameters, {vec3 = true})
    local radius_is_parameter = valid_parameter_reference(shape.radius, parameters, {number = true})
    if shape.size ~= nil and not size_is_parameter and not finite_vec3(shape.size) then
        return false, id .. ": " .. label .. " shape size must be a finite vec3 or parameter reference"
    end
    if shape.radius ~= nil and not radius_is_parameter
        and (not finite_number(shape.radius) or shape.radius < 0) then
        return false, id .. ": " .. label .. " shape radius must be a non-negative finite number"
    end
    for _, key in ipairs({"inner_radius", "height"}) do
        local value = shape[key]
        if value ~= nil and not finite_number(value)
            and not valid_parameter_reference(value, parameters, {number = true}) then
            return false, id .. ": " .. label .. " shape " .. key .. " must be a finite number or number parameter"
        end
        if type(value) == "number" and value < 0 then
            return false, id .. ": " .. label .. " shape " .. key .. " must be non-negative"
        end
    end
    if shape.inner_radius and type(shape.inner_radius) == "number"
        and type(shape.radius or 1) == "number" and shape.inner_radius > (shape.radius or 1) then
        return false, id .. ": " .. label .. " shape inner_radius must not exceed radius"
    end
    if kind == "line" then
        if shape.from ~= nil and not finite_vec3(shape.from) then
            return false, id .. ": " .. label .. " line shape from must be a finite vec3"
        end
        if shape.to ~= nil and not finite_vec3(shape.to) then
            return false, id .. ": " .. label .. " line shape to must be a finite vec3"
        end
    end
    return true
end

local function validate_collision_config(id, label, backend, motion, collision)
    if collision == nil then return true end
    if type(collision) ~= "table" or type(collision.type) ~= "string" then
        return false, id .. ": " .. label .. " collision needs a type"
    end
    local kind = collision.type
    if kind == "none" then return true end
    if backend ~= "entity" then
        return false, id .. ": " .. label .. " collision modes require the entity backend"
    end
    if kind == "native_rigidbody" then
        if motion == "controlled" then
            return false, id .. ": " .. label .. " native_rigidbody collision requires simulated or hybrid motion"
        end
        return true
    end
    if kind == "raycast" then
        if motion == "controlled" then
            return false, id .. ": " .. label .. " raycast collision requires simulated or hybrid motion"
        end
        if collision.gravity ~= nil and not finite_vec3(collision.gravity) then
            return false, id .. ": " .. label .. " raycast gravity must be a finite vec3"
        end
        if collision.restitution ~= nil and (not finite_number(collision.restitution) or collision.restitution < 0) then
            return false, id .. ": " .. label .. " raycast restitution must be non-negative"
        end
        if collision.radius ~= nil and (not finite_number(collision.radius) or collision.radius < 0) then
            return false, id .. ": " .. label .. " raycast radius must be non-negative"
        end
        if collision.skin ~= nil and (not finite_number(collision.skin) or collision.skin < 0) then
            return false, id .. ": " .. label .. " raycast skin must be non-negative"
        end
        if collision.damping ~= nil and (not finite_number(collision.damping)
            or collision.damping < 0 or collision.damping > 1) then
            return false, id .. ": " .. label .. " raycast damping must be in [0, 1]"
        end
        if collision.entities ~= nil and type(collision.entities) ~= "boolean" then
            return false, id .. ": " .. label .. " raycast entities must be a boolean"
        end
        if collision.nonselect_entities ~= nil and type(collision.nonselect_entities) ~= "boolean" then
            return false, id .. ": " .. label .. " nonselect_entities must be a boolean"
        end
        local response = collision.response or "bounce"
        if response ~= "bounce" and response ~= "stop" and response ~= "destroy" then
            return false, id .. ": " .. label .. " raycast response must be bounce, stop, or destroy"
        end
        return true
    end
    if kind == "custom" then
        if motion == "controlled" then
            return false, id .. ": " .. label .. " custom collision requires simulated or hybrid motion"
        end
        if not valid_extension_id(collision.id) or not collision_extensions[collision.id] then
            return false, id .. ": " .. label .. " custom collision id must reference a registered namespaced resolver"
        end
        return true
    end
    return false, id .. ": " .. label .. " has unknown collision mode " .. tostring(kind)
end

local function validate_parameter_references(id, def)
    local declared = def.parameters or {}
    local visited = {}
    local function walk(value, path)
        if type(value) == "string" then
            local parameter = value:match("^parameter:(.+)$")
            if parameter and parameter ~= "scale" and declared[parameter] == nil then
                return false, id .. ": " .. path .. " references unknown parameter " .. parameter
            end
            return true
        end
        if type(value) ~= "table" or visited[value] then return true end
        visited[value] = true
        local parameter = rawget(value, "parameter")
        if parameter ~= nil then
            if type(parameter) ~= "string" then
                return false, id .. ": " .. path .. ".parameter must be a string"
            end
            if parameter ~= "scale" and declared[parameter] == nil then
                return false, id .. ": " .. path .. " references unknown parameter " .. parameter
            end
        end
        for key, child in pairs(value) do
            if key ~= "parameter" then
                local child_path = type(key) == "number"
                    and (path .. "[" .. tostring(key) .. "]")
                    or (path .. "." .. tostring(key))
                local ok, err = walk(child, child_path)
                if not ok then return false, err end
            end
        end
        return true
    end

    local ok, err = walk(def.controller, "controller")
    if not ok then return false, err end
    ok, err = walk(def.emitters, "emitters")
    if not ok then return false, err end
    ok, err = walk(def.events, "events")
    if not ok then return false, err end
    return true
end

local function valid_color_value(value)
    if type(value) ~= "table" or (#value ~= 3 and #value ~= 4) then return false end
    for index = 1, #value do if not finite_number(value[index]) then return false end end
    return true
end

local function valid_scale_value(value)
    if finite_number(value) then return value >= 0 end
    if finite_vec3(value) then return value[1] >= 0 and value[2] >= 0 and value[3] >= 0 end
    if type(value) == "table" and value.min ~= nil and value.max ~= nil then
        local function valid_bound(bound)
            if finite_number(bound) then return bound >= 0 end
            if finite_vec3(bound) then return bound[1] >= 0 and bound[2] >= 0 and bound[3] >= 0 end
            return false
        end
        if not valid_bound(value.min) or not valid_bound(value.max) then return false end
        if finite_number(value.min) and finite_number(value.max) then return value.min <= value.max end
        return finite_vec3(value.min) and finite_vec3(value.max)
            and value.min[1] <= value.max[1] and value.min[2] <= value.max[2]
            and value.min[3] <= value.max[3]
    end
    return false
end

local function valid_spawn_number(value, parameters, integer)
    if type(value) == "number" then
        return finite_number(value) and value >= 0 and (not integer or value % 1 == 0)
    end
    if type(value) ~= "table" or type(value.parameter) ~= "string" or value.parameter == "scale" then return false end
    local spec = (parameters or {})[value.parameter]
    if spec == nil or spec.type ~= "number" or not finite_number(spec.min)
        or not finite_number(spec.max) or spec.min < 0 then return false end
    if integer and (spec.min % 1 ~= 0 or spec.max % 1 ~= 0) then return false end
    return valid_parameter_reference(value, parameters, {number = true})
end

local function validate_parameter_schema(id, parameters)
    for name, spec in pairs(parameters or {}) do
        if type(name) ~= "string" or name == "" or type(spec) ~= "table" then
            return false, id .. ": each parameter needs a non-empty name and an object definition"
        end
        local kind = spec.type
        if kind ~= "number" and kind ~= "boolean" and kind ~= "vec3" and kind ~= "color" and kind ~= "enum" then
            return false, id .. ": parameter " .. name .. " has unsupported type " .. tostring(kind)
        end
        if kind == "number" then
            for _, key in ipairs({"default", "min", "max"}) do
                if spec[key] ~= nil and not finite_number(spec[key]) then
                    return false, id .. ": parameter " .. name .. "." .. key .. " must be finite"
                end
            end
            if spec.min ~= nil and spec.max ~= nil and spec.min > spec.max then
                return false, id .. ": parameter " .. name .. " min must not exceed max"
            end
        elseif kind == "boolean" then
            if spec.default ~= nil and type(spec.default) ~= "boolean" then
                return false, id .. ": parameter " .. name .. ".default must be boolean"
            end
        elseif kind == "vec3" then
            if spec.default ~= nil and not finite_vec3(spec.default) then
                return false, id .. ": parameter " .. name .. ".default must be a finite vec3"
            end
        elseif kind == "color" then
            if spec.default ~= nil and not valid_color_value(spec.default) then
                return false, id .. ": parameter " .. name .. ".default must be RGB or RGBA"
            end
        elseif kind == "enum" then
            if type(spec.values) ~= "table" or #spec.values == 0 then
                return false, id .. ": parameter " .. name .. " enum needs a non-empty values array"
            end
            if spec.default ~= nil then
                local found = false
                for _, item in ipairs(spec.values) do if item == spec.default then found = true; break end end
                if not found then return false, id .. ": parameter " .. name .. ".default must be one of values" end
            end
        end
    end
    return true
end

local function validate_curve(id, label, curve, kind)
    if curve == nil then return true end
    if type(curve) ~= "table" then return false, id .. ": " .. label .. " must be an array" end
    local previous = -math.huge
    for index, key in ipairs(curve) do
        if type(key) ~= "table" or not finite_number(key[1]) or key[1] < 0 or key[1] > 1
            or key[1] < previous then
            return false, id .. ": " .. label .. " key " .. index .. " needs an ordered time in [0, 1]"
        end
        local valid = kind == "color" and valid_color_value(key[2])
            or kind == "scale" and valid_scale_value(key[2])
            or kind == "number" and finite_number(key[2])
        if not valid then return false, id .. ": " .. label .. " key " .. index .. " has an invalid value" end
        previous = key[1]
    end
    if #curve == 0 then return false, id .. ": " .. label .. " cannot be empty" end
    return true
end

local function validate_model_variants(id, label, variants)
    if variants == nil then return true end
    if type(variants) ~= "table" or #variants == 0 then
        return false, id .. ": " .. label .. " must be a non-empty array"
    end
    for index, variant in ipairs(variants) do
        local model = type(variant) == "string" and variant
            or type(variant) == "table" and (variant.model or variant.id)
        if type(model) ~= "string" or model == "" then
            return false, id .. ": " .. label .. " entry " .. index .. " needs a model id"
        end
        if type(variant) == "table" and variant.weight ~= nil
            and (not finite_number(variant.weight) or variant.weight < 0) then
            return false, id .. ": " .. label .. " entry " .. index .. " has an invalid weight"
        end
    end
    return true
end

function API.validate(id, def)
    if type(def) ~= "table" then return false, "definition must be a JSON object" end
    if def.schema ~= API.SCHEMA_VERSION then
        return false, id .. ": unsupported schema " .. tostring(def.schema)
    end
    if type(def.emitters) ~= "table" then return false, id .. ": emitters array is required" end
    local motion = def.motion or "simulated"
    if motion ~= "simulated" and motion ~= "controlled" and motion ~= "hybrid" then
        return false, id .. ": motion must be simulated, controlled, or hybrid"
    end
    if def.controller ~= nil and type(def.controller) ~= "table" then
        return false, id .. ": controller must be an object"
    end
    if def.parameters ~= nil and type(def.parameters) ~= "table" then
        return false, id .. ": parameters must be an object"
    end
    local parameters_ok, parameters_error = validate_parameter_schema(id, def.parameters)
    if not parameters_ok then return false, parameters_error end
    local audio_sources, audio_error = normalize_audio_sources(id, def.audio, id .. ": audio")
    if not audio_sources then return false, audio_error end
    local parameter_refs_ok, parameter_refs_error = validate_parameter_references(id, def)
    if not parameter_refs_ok then return false, parameter_refs_error end
    local controller_ok, controller_error = validate_controller_config(id, "controller", def.controller)
    if not controller_ok then return false, controller_error end
    if def.world ~= nil and (type(def.world) ~= "table" or (def.world.placeable ~= nil and type(def.world.placeable) ~= "boolean")) then
        return false, id .. ": world metadata must be an object with an optional boolean placeable"
    end
    if def.events ~= nil then
        local allowed_events = {on_start = true, on_spawn = true, on_collision = true,
            on_particle_death = true, on_stop = true, on_finished = true}
        if type(def.events) ~= "table" then return false, id .. ": events must be an object" end
        for event, actions in pairs(def.events) do
            if not allowed_events[event] then return false, id .. ": unsupported event " .. tostring(event) end
            if type(actions) == "table" and actions.type then actions = {actions} end
            if type(actions) ~= "table" then return false, id .. ": events." .. event .. " must be an action array" end
            for index, action in ipairs(actions) do
                if type(action) ~= "table" or type(action.type) ~= "string" then
                    return false, id .. ": events." .. event .. " action " .. index .. " needs a type"
                end
                local supported = {spawn_effect = true, change_parameter = true, release_particles = true,
                    callback = true, destroy_particle = true}
                if not supported[action.type] then return false, id .. ": unsupported event action " .. action.type end
                if action.type == "spawn_effect" and type(action.effect) ~= "string" then
                    return false, id .. ": events." .. event .. " spawn_effect needs an effect id"
                elseif action.type == "change_parameter" and type(action.name) ~= "string" then
                    return false, id .. ": events." .. event .. " change_parameter needs a name"
                elseif action.type == "callback" and not valid_extension_id(action.id) then
                    return false, id .. ": events." .. event .. " callback needs a namespaced id"
                end
            end
        end
    end
    for index, emitter in ipairs(def.emitters) do
        if type(emitter) ~= "table" then
            return false, id .. ": emitter " .. index .. " must be an object"
        end
        local backend = emitter.backend
        if backend ~= "billboard" and backend ~= "mesh" and backend ~= "entity" then
            return false, id .. ": emitter " .. index .. " has unknown backend " .. tostring(backend)
        end
        if backend == "billboard" and emitter.preset == nil then
            return false, id .. ": billboard emitter " .. index .. " needs preset"
        end
        if backend == "entity" and not (emitter.particle or emitter.entity) then
            return false, id .. ": entity emitter " .. index .. " needs particle Content ID"
        end
        if emitter.spawn ~= nil then
            if type(emitter.spawn) ~= "table" then
                return false, id .. ": emitter " .. index .. " spawn must be an object"
            end
            local mode = emitter.spawn.mode
            if mode ~= nil and mode ~= "burst" and mode ~= "rate" then
                return false, id .. ": emitter " .. index .. " spawn.mode must be burst or rate"
            end
            if emitter.spawn.count ~= nil and not valid_spawn_number(emitter.spawn.count, def.parameters, true) then
                return false, id .. ": emitter " .. index .. " spawn.count must be a non-negative integer or number parameter"
            end
            if emitter.spawn.rate ~= nil and not valid_spawn_number(emitter.spawn.rate, def.parameters, false) then
                return false, id .. ": emitter " .. index .. " spawn.rate must be a non-negative number or number parameter"
            end
            if emitter.spawn.limit ~= nil and not valid_spawn_number(emitter.spawn.limit, def.parameters, true) then
                return false, id .. ": emitter " .. index .. " spawn.limit must be a non-negative integer or number parameter"
            end
        end
        if backend == "mesh" and emitter.settings ~= nil and type(emitter.settings) ~= "table" then
            return false, id .. ": mesh emitter " .. index .. " settings must be an object"
        end
        if backend == "mesh" and type(emitter.settings) == "table"
            and emitter.settings.bounds_model_radius ~= nil
            and not valid_spawn_number(emitter.settings.bounds_model_radius, def.parameters, false) then
            return false, id .. ": mesh emitter " .. index
                .. " settings.bounds_model_radius must be a non-negative number or number parameter"
        end
        if emitter.appearance ~= nil and type(emitter.appearance) ~= "table" then
            return false, id .. ": emitter " .. index .. " appearance must be an object"
        end
        local appearance = emitter.appearance or {}
        if appearance.scale ~= nil and not valid_scale_value(appearance.scale)
            and not valid_scale_parameter_reference(appearance.scale, def.parameters) then
            return false, id .. ": emitter " .. index .. " appearance.scale must be a non-negative number, vec3, min/max range, or compatible parameter reference"
        end
        if appearance.size ~= nil and not valid_scale_value(appearance.size)
            and not valid_scale_parameter_reference(appearance.size, def.parameters) then
            return false, id .. ": emitter " .. index .. " appearance.size must be a non-negative number, vec3, min/max range, or compatible parameter reference"
        end
        if appearance.scale_range ~= nil and not valid_scale_value(appearance.scale_range) then
            return false, id .. ": emitter " .. index .. " appearance.scale_range must be a non-negative min/max range"
        end
        if appearance.color ~= nil then
            local color_valid = valid_color_value(appearance.color)
                or valid_parameter_reference(appearance.color, def.parameters, {color = true})
            if type(appearance.color) == "table" and type(appearance.color.min) == "table"
                and type(appearance.color.max) == "table" then
                color_valid = valid_color_value(appearance.color.min) and valid_color_value(appearance.color.max)
            end
            if not color_valid then return false, id .. ": emitter " .. index .. " appearance.color must be RGB/RGBA or an RGB/RGBA min/max range" end
        end
        if appearance.color_range ~= nil and (type(appearance.color_range) ~= "table"
            or not valid_color_value(appearance.color_range.min)
            or not valid_color_value(appearance.color_range.max)) then
            return false, id .. ": emitter " .. index .. " appearance.color_range needs RGB/RGBA min and max arrays"
        end
        if appearance.opacity ~= nil and (not finite_number(appearance.opacity)
            or appearance.opacity < 0 or appearance.opacity > 1) then
            return false, id .. ": emitter " .. index .. " appearance.opacity must be in [0, 1]"
        end
        local model_variants = appearance.models or appearance.model_variants
        if model_variants == nil and type(emitter.settings) == "table" then
            model_variants = emitter.settings.models or emitter.settings.model_variants
        end
        local variants_ok, variants_error = validate_model_variants(id,
            "emitter " .. index .. " appearance.models", model_variants)
        if not variants_ok then return false, variants_error end
        local settings = emitter.settings
        if type(settings) ~= "table" then settings = nil end
        local color_curve = emitter.color_over_life
        local scale_curve = emitter.scale_over_life
        local alpha_curve = emitter.alpha_over_life
        if settings then
            color_curve = color_curve or settings.color_over_life
            scale_curve = scale_curve or settings.scale_over_life
            alpha_curve = alpha_curve or settings.alpha_over_life
        end
        local curves = {
            {color_curve, "color_over_life", "color"},
            {scale_curve, "scale_over_life", "scale"},
            {alpha_curve, "alpha_over_life", "number"},
        }
        for _, entry in ipairs(curves) do
            local curve_ok, curve_error = validate_curve(id, "emitter " .. index .. " " .. entry[2], entry[1], entry[3])
            if not curve_ok then return false, curve_error end
        end
        local emitter_motion = emitter.motion or motion
        if emitter_motion ~= "simulated" and emitter_motion ~= "controlled" and emitter_motion ~= "hybrid" then
            return false, id .. ": emitter " .. index .. " has invalid motion mode"
        end
        if backend == "billboard" and emitter_motion ~= "simulated" then
            return false, id .. ": billboard backend cannot provide controlled transforms"
        end
        local emitter_controller_ok, emitter_controller_error = validate_controller_config(id,
            "emitter " .. index .. " controller", emitter.controller)
        if not emitter_controller_ok then return false, emitter_controller_error end
        local collision_ok, collision_error = validate_collision_config(id, "emitter " .. index,
            backend, emitter_motion, emitter.collision)
        if not collision_ok then return false, collision_error end
        if emitter.modifiers ~= nil and type(emitter.modifiers) ~= "table" then
            return false, id .. ": emitter " .. index .. " modifiers must be an array"
        end
        local shape_ok, shape_error = validate_shape_config(id, "emitter " .. index, emitter.shape, def.parameters)
        if not shape_ok then return false, shape_error end
        if backend == "mesh" and emitter.shape then
            local kind = emitter.shape.type or "point"
            if kind == "line" or shape_extensions[kind] then
                return false, id .. ": mesh emitter " .. index .. " does not implement line or registered custom shapes"
            end
        end
        if backend == "mesh" and emitter.settings and emitter.settings.shape then
            shape_ok, shape_error = validate_shape_config(id, "mesh emitter " .. index, emitter.settings.shape, def.parameters)
            if not shape_ok then return false, shape_error end
            local kind = emitter.settings.shape.type or "point"
            if kind == "line" or shape_extensions[kind] then
                return false, id .. ": mesh emitter " .. index .. " does not implement line or registered custom shapes"
            end
        end
        for modifier_index, modifier in ipairs(emitter.modifiers or {}) do
            local built_in = {gravity = true, drag = true, rotation = true, wind = true, turbulence = true, vortex = true}
            if type(modifier) ~= "table" or type(modifier.type) ~= "string" then
                return false, id .. ": emitter " .. index .. " modifier " .. modifier_index .. " needs a type"
            end
            if not built_in[modifier.type] and not modifier_extensions[modifier.type] then
                return false, id .. ": emitter " .. index .. " modifier " .. tostring(modifier.type) .. " is not registered"
            end
            if not built_in[modifier.type] and backend ~= "entity" then
                return false, id .. ": custom modifiers currently require the entity backend"
            end
            local backend_modifiers = {
                billboard = {},
                mesh = {gravity = true, drag = true, wind = true, turbulence = true, vortex = true},
                entity = {gravity = true, drag = true, rotation = true, wind = true, turbulence = true},
            }
            if not backend_modifiers[backend][modifier.type] and not modifier_extensions[modifier.type] then
                return false, id .. ": emitter " .. index .. " modifier " .. modifier.type
                    .. " is not implemented by the " .. backend .. " backend"
            end
        end
    end
    return true
end

function API.register(id, definition)
    if type(id) ~= "string" or not split_id(id) then
        return nil, "effect id must use a namespace, for example mypack:my_effect"
    end
    local ok, err = API.validate(id, definition)
    if not ok then return nil, err end
    definitions[id] = clone(definition)
    return true
end

function API.get_definition(id)
    local definition, err = load_definition(id)
    if not definition then return nil, err end
    return clone(definition)
end

function API.list_definitions(options)
    options = options or {}
    if type(options) ~= "table" then return {}, {"definition listing options must be an object"} end
    local installed = pack.get_installed()
    local results, errors, seen = {}, {}, {}
    local function scan(pack_id, directory, depth)
        if depth > 12 or not file.isdir(directory) then return end
        local ok, entries = pcall(file.list, directory)
        if not ok or type(entries) ~= "table" then
            errors[#errors + 1] = directory .. ": " .. tostring(entries)
            return
        end
        for _, entry in ipairs(entries) do
            local path = entry
            if type(path) == "string" and not path:find(":", 1, true) then
                path = file.join(directory, path)
            end
            if type(path) == "string" and file.isdir(path) then
                scan(pack_id, path, depth + 1)
            elseif type(path) == "string" and path:match("%.effect%.json$") then
                local relative = path:match("^[^:]+:effects/(.+)%.effect%.json$")
                if relative then
                    local id = pack_id .. ":" .. relative
                    if not seen[id] then
                        seen[id] = true
                        local definition, err = load_definition(id)
                        if definition then
                            local placeable = definition.world and definition.world.placeable == true or false
                            local query = type(options.search) == "string" and options.search:lower() or ""
                            local matches = query == "" or id:lower():find(query, 1, true) ~= nil
                            if matches and (not options.placeable_only or placeable) then
                                results[#results + 1] = {
                                    id = id,
                                    namespace = pack_id,
                                    name = relative,
                                    placeable = placeable,
                                    definition = clone(definition),
                                }
                            end
                        else
                            errors[#errors + 1] = id .. ": " .. tostring(err)
                        end
                    end
                end
            end
        end
    end
    for _, pack_id in ipairs(installed or {}) do
        if type(pack_id) == "string" and pack_id:match("^[%w_-]+$") then
            scan(pack_id, pack_id .. ":effects", 0)
        end
    end
    table.sort(results, function(a, b) return a.id < b.id end)
    return results, errors
end

function API.clear_definition_cache(id)
    if id then definitions[id] = nil else definitions = {} end
end

local function resolve_parameters(def, options)
    local parameters = {}
    local supplied = options.parameters or {}
    for name, spec in pairs(def.parameters or {}) do
        local value = supplied[name]
        if value == nil then value = options[name] end
        if value == nil then value = spec.default end
        if spec.type == "number" then
            value = tonumber(value) or tonumber(spec.default) or 0
            if not finite_number(value) then value = tonumber(spec.default) or 0 end
            if spec.min ~= nil then value = math.max(spec.min, value) end
            if spec.max ~= nil then value = math.min(spec.max, value) end
        elseif spec.type == "boolean" then
            value = not not value
        elseif spec.type == "color" or spec.type == "vec3" then
            if not is_vec3(value) and spec.type == "vec3" then value = clone(spec.default or {0, 0, 0}) end
            if spec.type == "color" and (type(value) ~= "table" or #value < 3) then
                value = clone(spec.default or {1, 1, 1})
            end
            value = clone(value)
            if spec.type == "color" then
                for index = 1, 3 do value[index] = math.max(0, math.min(1, tonumber(value[index]) or 0)) end
                if #value == 3 then value[4] = 1 end
                value[4] = math.max(0, math.min(1, tonumber(value[4]) or 1))
            end
        elseif spec.type == "enum" and spec.values then
            local allowed = false
            for _, item in ipairs(spec.values) do if item == value then allowed = true end end
            if not allowed then value = spec.default end
        end
        parameters[name] = value
    end
    return parameters
end

local function validate_parameter_overrides(definition, supplied, label)
    label = label or "parameters"
    if supplied == nil then return {} end
    if type(supplied) ~= "table" then return nil, label .. " must be an object" end
    local probe = {}
    for name, value in pairs(supplied) do
        local spec = (definition.parameters or {})[name]
        if not spec then return nil, label .. " contains unknown parameter " .. tostring(name) end
        if spec.type == "number" then
            if not finite_number(value) then return nil, label .. "." .. name .. " must be a finite number" end
        elseif spec.type == "boolean" then
            if type(value) ~= "boolean" then return nil, label .. "." .. name .. " must be boolean" end
        elseif spec.type == "vec3" then
            if not finite_vec3(value) then return nil, label .. "." .. name .. " must be a finite vec3" end
        elseif spec.type == "color" then
            if type(value) ~= "table" or (#value ~= 3 and #value ~= 4) then
                return nil, label .. "." .. name .. " must be RGB or RGBA"
            end
            for index = 1, #value do
                if not finite_number(value[index]) then return nil, label .. "." .. name .. " has a non-finite channel" end
            end
        elseif spec.type == "enum" then
            local found = false
            for _, choice in ipairs(spec.values or {}) do if choice == value then found = true; break end end
            if not found then return nil, label .. "." .. name .. " is not one of the declared enum values" end
        else
            return nil, label .. "." .. name .. " has unsupported definition parameter type " .. tostring(spec.type)
        end
        probe[name] = value
    end
    local normalized = resolve_parameters(definition, {parameters = probe})
    local result = {}
    for name in pairs(probe) do result[name] = clone(normalized[name]) end
    return result
end

current_position = function(effect)
    return effect_transform(effect).position
end

local function effect_audio_position(effect, source, details)
    local transform = effect_transform(effect)
    local position = details and details.position
    if not finite_vec3(position) and details and details.uid and entities.exists(details.uid) then
        local ok, entity = pcall(entities.get, details.uid)
        if ok and entity then
            local got_position, entity_position = pcall(function() return entity.transform:get_pos() end)
            if got_position and finite_vec3(entity_position) then position = entity_position end
        end
    end
    if not finite_vec3(position) then position = transform.position end
    return vadd(position, rotate_vector(transform.rotation, source.offset or {0, 0, 0}))
end

local function play_effect_audio_source(effect, source, details)
    if type(audio) ~= "table" then
        effect.audio_error = "VoxelCore audio Lua API is unavailable"
        return
    end
    local ok, result = pcall(function()
        if source.spatial then
            local position = effect_audio_position(effect, source, details)
            if source.type == "stream" then
                return audio.play_stream(source.resource, position[1], position[2], position[3],
                    source.volume, source.pitch, source.channel, source.loop)
            end
            return audio.play_sound(source.resource, position[1], position[2], position[3],
                source.volume, source.pitch, source.channel, source.loop)
        end
        if source.type == "stream" then
            return audio.play_stream_2d(source.resource, source.volume, source.pitch,
                source.channel, source.loop)
        end
        return audio.play_sound_2d(source.resource, source.volume, source.pitch,
            source.channel, source.loop)
    end)
    if not ok then
        effect.audio_error = tostring(result)
        return
    end
    local speaker_id = tonumber(result)
    if not speaker_id or speaker_id <= 0 then
        effect.audio_error = "VoxelCore did not start audio resource " .. tostring(source.resource)
        return
    end
    effect.audio_speakers = effect.audio_speakers or {}
    effect.audio_speakers[#effect.audio_speakers + 1] = {
        id = speaker_id,
        source = source,
    }
    effect.audio_error = nil
end

play_effect_audio_event = function(effect, event, details)
    for _, source in ipairs(effect.audio_sources or {}) do
        if source.event == event then play_effect_audio_source(effect, source, details) end
    end
end

local function update_effect_audio(effect)
    local speakers = effect.audio_speakers
    if not speakers then return end
    for index = #speakers, 1, -1 do
        local entry = speakers[index]
        local alive = false
        if type(audio) == "table" then
            local ok, playing = pcall(audio.is_playing, entry.id)
            local paused_ok, paused = pcall(audio.is_paused, entry.id)
            alive = (ok and playing == true) or (paused_ok and paused == true)
        end
        if not alive then
            table.remove(speakers, index)
        elseif not effect.paused and entry.source.follow and entry.source.spatial then
            local position = effect_audio_position(effect, entry.source)
            pcall(audio.set_position, entry.id, position[1], position[2], position[3])
        end
    end
end

local function stop_effect_audio(effect, reason, force)
    local speakers = effect.audio_speakers
    if not speakers then return end
    for index = #speakers, 1, -1 do
        local entry = speakers[index]
        local source = entry.source
        local should_stop = force
            or reason == "destroy"
            and source.stop_on_destroy
            or reason == "stop" and source.stop_on_stop
            or reason == "finish" and source.stop_on_finish
            or reason == "restart" and (source.loop or source.follow)
        if should_stop then
            if type(audio) == "table" then pcall(audio.stop, entry.id) end
            table.remove(speakers, index)
        end
    end
end

local function pause_effect_audio(effect, paused)
    for _, entry in ipairs(effect.audio_speakers or {}) do
        if type(audio) == "table" then
            if paused then pcall(audio.pause, entry.id)
            else pcall(audio.resume, entry.id) end
        end
    end
end

local controller_context

local function make_controller(effect, requested_config)
    local config = requested_config or effect.controller_config
    if type(config) ~= "table" then return nil end
    local kind = config.type
    local factory = controller_extensions[kind]
    if kind == "script" then
        if type(config.module) ~= "string" then
            return nil, "script controller requires a namespaced module"
        end
        local ok, module = pcall(require, config.module)
        if not ok then return nil, "cannot load controller module " .. config.module .. ": " .. tostring(module) end
        factory = module
    end
    if not factory then
        if kind == "follow" or kind == "orbit" or kind == "points" or kind == "path" or kind == "source_target" then
            return {kind = kind, config = clone(config)}
        end
        return nil, "unknown controller " .. tostring(kind)
    end
    local ok, controller
    if type(factory) == "function" then
        ok, controller = pcall(factory, clone(config), effect)
    else
        ok, controller = true, clone(factory)
    end
    if not ok then return nil, "controller factory failed: " .. tostring(controller) end
    if type(controller) ~= "table" then return nil, "controller factory must return a table" end
    local context = {effect = effect, parameters = effect.parameters, anchors = {
        effect = effect_transform(effect), source = resolve_anchor(effect.source_anchor),
        target = resolve_anchor(effect.target_anchor),
    }}
    if type(controller.init) == "function" then
        local initialized, err = pcall(controller.init, controller, clone(config), context)
        if not initialized then return nil, "controller init failed: " .. tostring(err) end
    end
    controller.config = clone(config)
    return controller
end

local function controller_anchor_snapshot(effect, transform)
    transform = transform or effect_transform(effect)
    local source, source_valid = resolve_anchor(effect.source_anchor, effect.last_source_transform or transform)
    local target, target_valid = resolve_anchor(effect.target_anchor, effect.last_target_transform or transform)
    if source_valid then effect.last_source_transform = clone(source) end
    if target_valid then effect.last_target_transform = clone(target) end
    return {effect = transform, source = source, target = target,
        source_valid = source_valid, target_valid = target_valid}
end

controller_context = function(effect, dt, index, count, particle, emitter, anchor_snapshot)
    local anchors = anchor_snapshot or controller_anchor_snapshot(effect)
    local transform = anchors.effect
    local slot_age = (emitter and emitter.controller_ages and emitter.controller_ages[index])
        or (effect.controller_ages and effect.controller_ages[index]) or 0
    local slot_lifetime = (emitter and emitter.controller_lifetimes and emitter.controller_lifetimes[index])
        or effect.duration or 1
    local normalized_slot_age = slot_age
    if emitter and emitter.mode == "loop" and slot_lifetime > 0 then
        normalized_slot_age = slot_age % slot_lifetime
    end
    return {
        dt = dt,
        time = effect.age,
        effect_time = effect.age,
        particle_index = index,
        particle_count = count,
        normalized_index = count <= 1 and 0 or (index - 1) / (count - 1),
        particle_age = particle and particle.age or slot_age,
        normalized_age = particle and particle.lifetime and math.min(1, particle.age / particle.lifetime)
            or math.min(1, normalized_slot_age / math.max(0.001, slot_lifetime)),
        emitter_index = emitter and emitter.index or nil,
        emitter = emitter and emitter.definition or nil,
        parameters = effect.parameters,
        anchors = anchors,
        effect_transform = transform,
        seed = effect.seed,
        rng = effect.random,
    }
end

local function update_controller(effect, controller, dt, emitter)
    if not controller or type(controller.update) ~= "function" then return end
    local context = controller_context(effect, dt, nil, nil, nil, emitter)
    local ok, frame = pcall(controller.update, controller, dt, context)
    if ok then
        if type(frame) == "table" and finite_vec3(frame.position) then
            if emitter then emitter.controller_frame = frame else effect.controller_frame = frame end
        end
    else
        if emitter then emitter.controller_error = tostring(frame)
        else effect.controller_error = tostring(frame) end
    end
end

local function destroy_controller(effect, controller, emitter)
    if not controller or controller.destroyed then return end
    if type(controller.destroy) == "function" then
        local context = controller_context(effect, 0, nil, nil, nil, emitter)
        pcall(controller.destroy, controller, context)
    end
    controller.destroyed = true
end

local function destroy_effect_controllers(effect)
    destroy_controller(effect, effect.controller_instance)
    for _, emitter in ipairs(effect.emitters or {}) do
        if emitter.controller_instance ~= effect.controller_instance then
            destroy_controller(effect, emitter.controller_instance, emitter)
        end
    end
end

local function world_point(effect, point, space, transform)
    if space == "world" then return clone(point) end
    return point_in_transform(transform or effect_transform(effect).anchor, point, effect.inherit_scale)
end

local function path_point(config, normalized)
    return path_evaluate(config, normalized)
end

local function built_in_particle_pose(effect, index, count, dt, particle, emitter, frame)
    local config = frame and frame.config or resolve(
        (emitter and emitter.controller_config) or effect.controller_config or {}, effect, effect.random)
    local kind = config.type or "follow"
    local context = controller_context(effect, dt, index, count, particle, emitter,
        frame and frame.anchors)
    local root = context.effect_transform
    local point, rotation, scale, color
    if kind == "orbit" then
        local axis = vnorm(config.axis or {0, 1, 0})
        local helper = math.abs(axis[2]) < 0.9 and {0, 1, 0} or {1, 0, 0}
        local tangent = vnorm({axis[2] * helper[3] - axis[3] * helper[2], axis[3] * helper[1] - axis[1] * helper[3], axis[1] * helper[2] - axis[2] * helper[1]})
        local bitangent = {axis[2] * tangent[3] - axis[3] * tangent[2], axis[3] * tangent[1] - axis[1] * tangent[3], axis[1] * tangent[2] - axis[2] * tangent[1]}
        local angle = (config.phase or 0) + effect.age * (config.speed or 1)
            + (index - 1) * (config.phase_step or (math.pi * 2 / math.max(1, count)))
        local radius = tonumber(config.radius) or 1
        local local_point = vadd(vmul(axis, config.height or 0), vadd(vmul(tangent, math.cos(angle) * radius), vmul(bitangent, math.sin(angle) * radius)))
        point = point_in_transform(root, local_point, effect.inherit_scale)
    elseif kind == "points" then
        local points = effect.points or config.points or {}
        if #points == 0 then return nil, context end
        local point_index = count <= 1 and 1 or (math.floor(context.normalized_index * (#points - 1) + 0.5) + 1)
        point = world_point(effect, points[point_index], config.space or effect.space, root)
    elseif kind == "path" then
        local path = config.path or config
        local sample = path_point(path, context.normalized_index)
        point = world_point(effect, sample, config.space or effect.space, root)
    elseif kind == "source_target" then
        local source, target = context.anchors.source, context.anchors.target
        if not context.anchors.source_valid or not context.anchors.target_valid then return nil, context end
        local direction = vsub(target.position, source.position)
        point = vadd(source.position, vmul(direction, context.normalized_index))
        local wave = tonumber(config.wave) or 0
        if wave ~= 0 then
            local side = vnorm({direction[3], 0, -direction[1]})
            point = vadd(point, vmul(side, math.sin(effect.age * (config.frequency or 1) * math.pi * 2 + context.normalized_index * math.pi * 2) * wave))
        end
    elseif kind == "follow" then
        local local_offset = particle and particle.local_offset or {0, 0, 0}
        if finite_vec3(config.offset) then local_offset = vadd(local_offset, config.offset) end
        local inherit_scale = config.inherit_scale
        if inherit_scale == nil then inherit_scale = effect.inherit_scale end
        point = point_in_transform(root, local_offset, inherit_scale)
    end
    if not point then return nil, context end
    rotation = config.inherit_rotation == false and mat4.idt() or root.rotation
    scale = config.scale or 1
    color = config.color
    return {position = point, rotation = rotation, scale = scale, color = color, space = "world"}, context
end

local rotation_matrix

local function controller_particle_pose(effect, index, count, dt, particle, emitter, frame)
    local controller = (emitter and emitter.controller_instance) or effect.controller_instance
    local pose, context
    if controller and type(controller.update_particle) == "function" then
        context = controller_context(effect, dt, index, count, particle, emitter)
        local ok, result = pcall(controller.update_particle, controller, particle, dt, context)
        if ok and type(result) == "table" and finite_vec3(result.position) then
            pose = result
        elseif not ok then
            effect.controller_error = tostring(result)
        end
    else
        pose, context = built_in_particle_pose(effect, index, count, dt, particle, emitter, frame)
    end
    local frame = (emitter and emitter.controller_frame) or effect.controller_frame
    if not pose and frame and finite_vec3(frame.position) then
        pose, context = clone(frame), controller_context(effect, dt, index, count, particle, emitter)
    end
    if not pose then return nil end
    local controller_space = (controller and controller.config and controller.config.space) or (controller and controller.space) or "local"
    if pose.space ~= "world" and controller and controller_space ~= "world" then
        pose.position = world_point(effect, pose.position, pose.space or controller_space, context and context.effect_transform)
    end
    pose.rotation = rotation_matrix(pose.rotation, context and context.effect_transform.rotation)
    pose.scale = pose.scale or 1
    if pose.model ~= nil and type(pose.model) ~= "string" then pose.model = nil end
    return pose
end

local function scale_vector(value, multiplier)
    if type(value) == "number" then return {value * multiplier, value * multiplier, value * multiplier} end
    if finite_vec3(value) then return vmul(value, multiplier) end
    return {multiplier, multiplier, multiplier}
end

rotation_matrix = function(value, fallback)
    if finite_mat4(value) then return clone(value) end
    if finite_vec3(value) then
        local matrix = mat4.idt()
        if value[1] ~= 0 then mat4.rotate(matrix, {1, 0, 0}, value[1], matrix) end
        if value[2] ~= 0 then mat4.rotate(matrix, {0, 1, 0}, value[2], matrix) end
        if value[3] ~= 0 then mat4.rotate(matrix, {0, 0, 1}, value[3], matrix) end
        return matrix
    end
    return finite_mat4(fallback) and clone(fallback) or mat4.idt()
end

local function point_to_local(point, transform, parent_inverse)
    local relative = vsub(point, transform.position)
    if parent_inverse then
        relative = rotate_vector(parent_inverse, relative)
    else
        local ok, inverse = pcall(mat4.inverse, transform.rotation)
        if ok then relative = rotate_vector(inverse, relative) end
    end
    return relative
end

local function rotation_to_local(rotation, parent_rotation, parent_inverse)
    local inverse = parent_inverse
    if not inverse then
        local ok, calculated = pcall(mat4.inverse, parent_rotation)
        if not ok then return rotation end
        inverse = calculated
    end
    local success, result = pcall(mat4.mul, inverse, rotation)
    return success and result or rotation
end

local function contains_random_range(value)
    if type(value) ~= "table" then return false end
    if type(value.range) == "table" then return true end
    for _, item in pairs(value) do
        if contains_random_range(item) then return true end
    end
    return false
end

local mesh_settings
local spawn_entity_particle

local function update_controlled_emitter(emitter, effect, dt)
    local transform = effect_transform(effect)
    if emitter.particles then
        if emitter.running and emitter.mode == "rate" then
            local spawn = resolve(emitter.definition.spawn or {}, effect, effect.random)
            emitter.accumulator = emitter.accumulator + math.max(0, tonumber(spawn.rate) or 0) * dt
            local births = math.floor(emitter.accumulator)
            emitter.accumulator = emitter.accumulator - births
            if spawn.limit then births = math.min(births, math.max(0, math.floor(spawn.limit - emitter.emitted))) end
            for _ = 1, births do
                local ok, spawned = pcall(spawn_entity_particle, emitter, effect)
                if ok and spawned then emitter.emitted = emitter.emitted + 1; effect.spawn_error = nil
                elseif not ok then effect.spawn_error = tostring(spawned) end
            end
            if spawn.limit and emitter.emitted >= spawn.limit then
                emitter.running = false
                emitter.finished_emission = true
            end
        end
        local count = #emitter.particles
        for index, particle in ipairs(emitter.particles) do
            if not particle.dead and entities.exists(particle.uid) then
                particle.age = (particle.age or 0) + dt
                if particle.age >= particle.lifetime then
                    entities.despawn(particle.uid)
                    particle.dead = true
                    fire_event(effect, "on_particle_death", {
                        emitter = emitter.index, particle = index, uid = particle.uid,
                        reason = "lifetime",
                    })
                else
                local pose = controller_particle_pose(effect, index, count, dt, particle, emitter)
                    if pose then
                        local entity = entities.get(particle.uid)
                        if entity then
                            entity.transform:set_pos(pose.position)
                            entity.transform:set_rot(pose.rotation)
                            local life_ratio = math.max(0, math.min(1, particle.age / particle.lifetime))
                            local base_scale = particle.base_scale or {1, 1, 1}
                            local scale = vhadamard(base_scale, scale_vector(pose.scale, effect.scale))
                            local curve_scale = scale_vector(curve_sample(particle.scale_curve, life_ratio, 1), 1)
                            entity.transform:set_size(vhadamard(scale, curve_scale))
                            local color = pose.color or curve_sample(particle.color_curve, life_ratio, particle.base_color)
                            color = apply_alpha(color, particle.alpha_curve, life_ratio, particle.opacity)
                            if color then safe_call(entity.skeleton, "set_color", color) end
                            particle.last_pose = pose
                        end
                    end
                end
            elseif not particle.dead then
                particle.dead = true
                fire_event(effect, "on_particle_death", {
                    emitter = emitter.index, particle = index, uid = particle.uid,
                    reason = "entity_removed",
                })
            end
        end
        -- Rate emitters can run indefinitely. Retaining dead particle records
        -- would grow the array and distort controller particle_count/index.
        for index = #emitter.particles, 1, -1 do
            if emitter.particles[index].dead then table.remove(emitter.particles, index) end
        end
    elseif emitter.containers then
        local inverse_ok, parent_inverse = pcall(mat4.inverse, transform.rotation)
        if not inverse_ok then parent_inverse = nil end
        local controller = emitter.controller_instance or effect.controller_instance
        local controller_config = emitter.controller_config or effect.controller_config or {}
        local cache_built_in = not (controller and type(controller.update_particle) == "function")
            and not contains_random_range(controller_config)
        local controller_frame_cache
        emitter.pose_history = emitter.pose_history or {}
        emitter.container_bounds = emitter.container_bounds or {}
        for container_index, uid in ipairs(emitter.containers) do
            local entity = entities.exists(uid) and entities.get(uid)
            local component = entity and entity:get_component("wisplib:mesh_emitter")
            if entity then
                entity.transform:set_pos(transform.position)
                entity.transform:set_rot(transform.rotation)
                local settings = mesh_settings(emitter, effect, effect.random)
                local model_radius = math.max(0, tonumber(settings.bounds_model_radius) or 1)
                local history = emitter.pose_history[container_index] or {}
                emitter.pose_history[container_index] = history
                local old_bound = emitter.container_bounds[container_index] or 1
                local new_bound = old_bound
                if cache_built_in and settings.loop ~= false and not controller_frame_cache then
                    controller_frame_cache = {
                        config = resolve(controller_config, effect, effect.random),
                        anchors = controller_anchor_snapshot(effect, transform),
                    }
                end
                local capacity = settings.capacity or 512
                local count = settings.count or 0
                local first = (container_index - 1) * capacity + 1
                local last = math.min(count, first + capacity - 1)
                emitter.pose_batches = emitter.pose_batches or {}
                local pose_updates = emitter.pose_batches[container_index] or {}
                emitter.pose_batches[container_index] = pose_updates
                local pose_count = 0
                for particle_index = first, last do
                    emitter.controller_ages = emitter.controller_ages or {}
                    emitter.controller_lifetimes = emitter.controller_lifetimes or {}
                    emitter.controller_ages[particle_index] = (emitter.controller_ages[particle_index] or 0) + dt
                    local local_index = particle_index - first + 1
                    local particle_lifetime = component and component.get_particle_lifetime
                        and component.get_particle_lifetime(local_index) or 1
                    emitter.controller_lifetimes[particle_index] = particle_lifetime
                    if settings.loop == false and emitter.controller_ages[particle_index] >= particle_lifetime then
                        if component and component.expire_particle then component.expire_particle(local_index) end
                        history[local_index] = nil
                    else
                        local pose = controller_particle_pose(effect, particle_index, count, dt,
                            nil, emitter, settings.loop ~= false and controller_frame_cache or nil)
                        if pose and component and component.set_particle_pose then
                            local local_position = point_to_local(pose.position, transform, parent_inverse)
                            if effect.inherit_scale then
                                for axis = 1, 3 do
                                    local divisor = transform.scale[axis]
                                    if math.abs(divisor) > 0.000001 then local_position[axis] = local_position[axis] / divisor end
                                end
                            end
                            local local_rotation = rotation_to_local(pose.rotation, transform.rotation,
                                parent_inverse)
                            local life_age = emitter.controller_ages[particle_index]
                            if settings.loop ~= false then
                                life_age = life_age % math.max(0.001, particle_lifetime)
                            end
                            local life_ratio = math.max(0, math.min(1,
                                life_age / math.max(0.001, particle_lifetime)))
                            local base_scale = component.get_particle_scale
                                and component.get_particle_scale(local_index)
                                or scale_vector(settings.size or 0.06, 1)
                            local life_scale = scale_vector(curve_sample(settings.scale_over_life, life_ratio, 1), 1)
                            local pose_scale = vhadamard(scale_vector(pose.scale, effect.scale), life_scale)
                            local base_color = component.get_particle_color
                                and component.get_particle_color(local_index) or settings.color
                            local color = pose.color or curve_sample(settings.color_over_life, life_ratio, base_color)
                            color = apply_alpha(color, settings.alpha_over_life, life_ratio, settings.opacity)
                            local raw_scale = vhadamard(base_scale, pose_scale)
                            local extent = math.sqrt(local_position[1] * local_position[1]
                                + local_position[2] * local_position[2]
                                + local_position[3] * local_position[3]) + model_radius * math.max(
                                math.abs(raw_scale[1]), math.abs(raw_scale[2]), math.abs(raw_scale[3]))
                            if finite_number(extent) then new_bound = math.max(new_bound, extent) end
                            local update = history[local_index] or {index = local_index}
                            history[local_index] = update
                            pose_count = pose_count + 1
                            pose_updates[pose_count] = update
                            update.raw_position = local_position
                            update.rotation = local_rotation
                            update.raw_scale = raw_scale
                            update.color = color
                            update.model = pose.model
                        end
                    end
                end
                while #pose_updates > pose_count do pose_updates[#pose_updates] = nil end
                if new_bound > old_bound then
                    emitter.container_bounds[container_index] = new_bound
                    entity.transform:set_size({new_bound, new_bound, new_bound})
                    -- Previously visible slots must be renormalized too, including
                    -- slots whose controller returned no pose this frame.
                    pose_count = 0
                    for _, update in pairs(history) do
                        pose_count = pose_count + 1
                        pose_updates[pose_count] = update
                    end
                    while #pose_updates > pose_count do pose_updates[#pose_updates] = nil end
                end
                local inverse_bound = 1 / new_bound
                for index = 1, pose_count do
                    local update = pose_updates[index]
                    update.position = vmul(update.raw_position, inverse_bound)
                    update.scale = vmul(update.raw_scale, inverse_bound)
                end
                if pose_count > 0 and component and component.set_particle_poses then
                    component.set_particle_poses(pose_updates)
                elseif component and component.set_particle_pose then
                    for _, pose in ipairs(pose_updates) do
                        component.set_particle_pose(pose.index, pose.position, pose.rotation,
                            pose.scale, pose.color, pose.model)
                    end
                end
            end
        end
    end
end

local function load_particle_preset(reference)
    if type(reference) == "table" then return clone(reference) end
    if type(reference) ~= "string" then return nil, "preset must be a table or namespaced asset id" end
    local uri = reference
    if not uri:match("%.json$") then uri = uri .. ".json" end
    return read_json(uri)
end

local function apply_motion_method(def, entity, effect, physics)
    if not def.motion_component or not def.motion_method then return end
    local component_id = def.motion_component:gsub("__", ":")
    local ok, component = pcall(function() return entity:get_component(component_id) end)
    if not ok then return end
    if not component or type(component[def.motion_method]) ~= "function" then return end
    local args = {}
    for index, path in ipairs(def.motion_args or {}) do
        local parameter = path:match("^parameter:(.+)$")
        if parameter then
            args[index] = effect.parameters[parameter]
        else
            local root, field = path:match("^([^.]+)%.(.+)$")
            args[index] = root and physics[root] and physics[root][field] or physics[path]
        end
    end
    pcall(component[def.motion_method], unpack(args))
end

local function merge_parameter_overrides(preset, overrides, effect, random)
    if not overrides then return preset end
    return merge(preset, resolve(overrides, effect, random))
end

mesh_settings = function(emitter, effect, random, count)
    local runtime_count = emitter.runtime_count
    local runtime_motion = emitter.motion
    emitter = emitter.definition or emitter
    local settings = resolve(emitter.settings or {}, effect, random)
    local appearance = resolve(emitter.appearance or {}, effect, random)
    settings.shape = settings.shape or resolve(emitter.shape, effect, random)
    settings.model = settings.model or appearance.model
    settings.models = settings.models or appearance.models
    settings.model_variants = settings.model_variants or appearance.model_variants
    settings.size = settings.size or appearance.size or appearance.scale
    settings.size_range = settings.size_range or appearance.size_range or appearance.scale_range
    settings.size_variation = settings.size_variation or appearance.size_variation
    settings.rotation = settings.rotation or appearance.rotation
    settings.rotation_axis = settings.rotation_axis or appearance.rotation_axis
    settings.angular_velocity = settings.angular_velocity or appearance.angular_velocity
    settings.color = settings.color or appearance.color
    settings.color_range = settings.color_range or appearance.color_range
    settings.color_multiplier = settings.color_multiplier or appearance.color_multiplier
    settings.opacity = settings.opacity or appearance.opacity
    settings.color_over_life = settings.color_over_life or resolve(emitter.color_over_life, effect, random)
    settings.alpha_over_life = settings.alpha_over_life or resolve(emitter.alpha_over_life, effect, random)
    settings.scale_over_life = settings.scale_over_life or resolve(emitter.scale_over_life, effect, random)
    settings.modifiers = settings.modifiers or resolve(emitter.modifiers, effect, random)
    if runtime_count ~= nil then settings.count = runtime_count end
    if count then settings.count = count end
    if settings.count == nil then settings.count = 128 end
    settings.capacity = math.max(1, math.min(512, math.floor(tonumber(settings.capacity) or 512)))
    settings.count = math.max(0, math.floor(tonumber(settings.count) or 0))
    settings.seed = (effect.seed or 1) + (emitter.index or 0)
    settings.position = current_position(effect)
    settings.motion = runtime_motion or emitter.motion or effect.motion
    return settings
end

local function spawn_mesh_container(emitter, effect, count, container_index)
    local settings = mesh_settings(emitter, effect, effect.random, count)
    settings.seed = settings.seed + container_index * 9973
    local entity = entities.spawn(emitter.definition.container or "wisplib:mesh_emitter",
        current_position(effect), {
            wisplib__mesh_emitter = {settings = settings},
        })
    if not entity then error("could not spawn mesh emitter container") end
    if emitter.motion == "controlled" or emitter.motion == "hybrid" then
        safe_call(entity.transform, "set_rot", effect_transform(effect).rotation)
        safe_call(entity.transform, "set_size", {1, 1, 1})
        local component = entity:get_component("wisplib:mesh_emitter")
        if component and component.set_controlled then component.set_controlled(true) end
    elseif effect.scale ~= 1 then
        safe_call(entity.transform, "set_size", {effect.scale, effect.scale, effect.scale})
    end
    local uid = entity:get_uid()
    table.insert(emitter.containers, uid)
end

local function start_mesh(emitter, effect)
    local settings = mesh_settings(emitter, effect, effect.random)
    emitter.motion = effect.motion_override or emitter.definition.motion or effect.motion
    settings.motion = emitter.motion
    local capacity = math.max(1, math.floor(settings.capacity or 512))
    local count = math.max(0, math.floor(settings.count or 128))
    local remaining = count
    local index = 1
    repeat
        local batch = math.min(capacity, remaining)
        spawn_mesh_container(emitter, effect, batch, index)
        index = index + 1
        remaining = remaining - batch
    until remaining <= 0
    emitter.controller_count = count
    emitter.controller_capacity = capacity
    emitter.mode = settings.loop == false and "burst" or "loop"
    emitter.finite = emitter.mode == "burst"
    emitter.running = true
end

local verified_particle_textures = {}

local function require_particle_texture(texture, effect, emitter)
    if type(texture) ~= "string" or texture == "" then
        error("effect " .. effect.name .. " emitter " .. emitter.index
            .. ": billboard preset needs a texture alias")
    end
    if verified_particle_textures[texture] then return end
    if type(assets) ~= "table" or type(assets.to_canvas) ~= "function" then
        error("effect " .. effect.name .. " emitter " .. emitter.index
            .. ": client assets.to_canvas is unavailable")
    end
    local ok, canvas = pcall(assets.to_canvas, texture)
    if not ok or canvas == nil then
        error("effect " .. effect.name .. " emitter " .. emitter.index
            .. ": billboard texture alias " .. texture .. " is unavailable")
    end
    verified_particle_textures[texture] = true
end

local function start_billboard(emitter, effect)
    local def = emitter.definition
    local preset, err = load_particle_preset(def.preset)
    if not preset then error(err) end
    preset = merge_parameter_overrides(preset, def.overrides, effect, effect.random)
    require_particle_texture(preset.texture, effect, emitter)
    for _, frame_texture in ipairs(preset.frames or {}) do
        require_particle_texture(frame_texture, effect, emitter)
    end
    if effect.scale ~= 1 then
        if is_vec3(preset.size) then preset.size = vmul(preset.size, effect.scale) end
        if is_vec3(preset.spawn_spread) then preset.spawn_spread = vmul(preset.spawn_spread, effect.scale) end
    end
    local spawn = resolve(def.spawn or {}, effect, effect.random)
    local mode = spawn.mode or "rate"
    local count = mode == "burst" and math.max(0, math.floor(spawn.count or 1))
        or (spawn.limit and math.floor(spawn.limit))
        or (spawn.count and math.floor(spawn.count) or -1)
    if mode == "rate" then
        if spawn.rate and spawn.rate > 0 then
            preset.spawn_interval = 1.0 / spawn.rate
        else
            count = 0
        end
    end
    local origin = effect.parent_uid and (effect.parent_offset[1] == 0
        and effect.parent_offset[2] == 0 and effect.parent_offset[3] == 0)
        and effect.parent_uid or current_position(effect)
    emitter.native_id = gfx.particles.emit(origin, count, preset)
    emitter.preset = preset
    -- VoxelCore's is_alive() reports whether the emitter still has a spawn count,
    -- not whether particles it already emitted are still visible. Wait out the
    -- preset's longest possible particle lifetime after emission ends.
    emitter.native_particle_lifetime = finite_number(preset.lifetime)
        and math.max(0, preset.lifetime) or 5.0
    emitter.native_drain_elapsed = 0
    emitter.running = mode == "rate"
    emitter.mode = mode
    emitter.emitted = count > 0 and count or 0
    emitter.finite = mode == "burst" or count >= 0
end

spawn_entity_particle = function(emitter, effect)
    local def = emitter.definition
    local controlled = emitter.motion == "controlled" or emitter.motion == "hybrid"
    local spawn_config = resolve(def.spawn or {}, effect, effect.random)
    local shape = resolve(def.shape or {type = "point"}, effect, effect.random)
    local reusable_slot
    if controlled and emitter.mode == "rate" then
        for index, existing in ipairs(emitter.particles) do
            if existing.dead then reusable_slot = index; break end
        end
    end
    local particle_index = reusable_slot or (#emitter.particles + 1)
    local particle_count = #emitter.particles
    local shape_context = {
        effect_time = effect.age,
        particle_index = particle_index,
        particle_count = tonumber(spawn_config.count) or tonumber(emitter.runtime_count) or 0,
        normalized_index = (particle_index - 1) / math.max(1, tonumber(spawn_config.count) or particle_count or 1),
        parameters = effect.parameters,
        anchors = {effect = effect_transform(effect), source = effect.source_anchor, target = effect.target_anchor},
        seed = effect.seed,
        rng = effect.random,
        shape = shape,
    }
    for key, value in pairs(shape) do
        if shape_context[key] == nil then shape_context[key] = value end
    end
    local offset = sample_shape(shape, effect.random, shape_context)
    offset = vmul(offset, effect.scale)
    local transform = effect_transform(effect)
    local position = (effect.space ~= "world" and effect.anchor)
        and point_in_transform(transform, offset, effect.inherit_scale)
        or vadd(transform.position, offset)
    local life = random_range(resolve(def.lifetime or 2.0, effect, effect.random), effect.random)
    local velocity = initial_velocity(resolve(def, effect, effect.random), effect.random, offset)
    local component_args = resolve(def.component_args or {}, effect, effect.random)
    if def.motion_component then
        component_args[def.motion_component] = component_args[def.motion_component] or {}
        component_args[def.motion_component].velocity = velocity
        component_args[def.motion_component].lifetime = life
    end
    local entity = entities.spawn(def.particle or def.entity, position, component_args)
    if not entity then return false end
    local uid = entity:get_uid()
    local collision = resolve(def.collision or {type = "native_rigidbody"}, effect, effect.random)
    local physics = resolve(def.physics or {}, effect, effect.random)
    local modifiers = resolve(def.modifiers or {}, effect, effect.random)
    local rotation_speed = random_range(resolve(def.rotation_speed or 0, effect, effect.random), effect.random)
    local rotation_axis = resolve(def.rotation_axis or {0, 1, 0}, effect, effect.random)
    local wind = def.wind and resolve(def.wind, effect, effect.random) or nil
    local turbulence = resolve(def.turbulence or 0, effect, effect.random)
    for _, modifier in ipairs(modifiers) do
        if modifier.type == "gravity" then physics.gravity = modifier.strength end
        if modifier.type == "drag" then physics.linear_damping = modifier.strength end
        if modifier.type == "rotation" then
            rotation_speed = random_range(modifier.speed or 0, effect.random)
            rotation_axis = modifier.axis or rotation_axis
        end
        if modifier.type == "wind" then wind = modifier.vector end
        if modifier.type == "turbulence" then turbulence = turbulence + (modifier.strength or 0) end
    end
    apply_motion_method(def, entity, effect, physics)
    if physics.gravity ~= nil then safe_call(entity.rigidbody, "set_gravity_scale", physics.gravity) end
    if physics.elasticity ~= nil then safe_call(entity.rigidbody, "set_elasticity", physics.elasticity) end
    if physics.mass ~= nil then safe_call(entity.rigidbody, "set_mass", physics.mass) end
    if physics.linear_damping ~= nil then safe_call(entity.rigidbody, "set_linear_damping", physics.linear_damping) end
    if is_vec3(velocity) then safe_call(entity.rigidbody, "set_vel", velocity) end
    if controlled or collision.type == "raycast" or collision.type == "custom" then
        safe_call(entity.rigidbody, "set_enabled", false)
    end
    local appearance = resolve(def.appearance or {}, effect, effect.random)
    local base_scale = sample_scale(appearance.scale or appearance.size or appearance.scale_range, effect.random, {1, 1, 1})
    local base_color = sample_color(appearance.color or appearance.color_range, effect.random)
    safe_call(entity.transform, "set_size", vmul(base_scale, effect.scale))
    if appearance.rotation then safe_call(entity.transform, "set_rot", rotation_matrix(appearance.rotation)) end
    if base_color then safe_call(entity.skeleton, "set_color", base_color) end
    local particle_record = {
        uid = uid,
        age = 0,
        lifetime = math.max(0.01, life),
        gravity = physics.gravity,
        wind = wind,
        turbulence = turbulence,
        phase = effect.random() * math.pi * 2,
        velocity = clone(velocity),
        base_scale = base_scale,
        base_color = base_color,
        color_curve = resolve(def.color_over_life, effect, effect.random),
        scale_curve = resolve(def.scale_over_life, effect, effect.random),
        alpha_curve = resolve(def.alpha_over_life, effect, effect.random),
        opacity = appearance.opacity or 1,
        rotation_speed = rotation_speed,
        rotation_axis = rotation_axis,
        local_offset = clone(offset),
        controlled = controlled,
        custom_modifiers = clone(modifiers),
        collision = clone(collision),
        collision_position = clone(position),
    }
    if reusable_slot then
        emitter.particles[reusable_slot] = particle_record
    else
        table.insert(emitter.particles, particle_record)
    end
    if fire_event then fire_event(effect, "on_spawn", {emitter = emitter.index, particle = particle_index, uid = uid}) end
    return true
end

local function start_entity(emitter, effect)
    emitter.particles = {}
    emitter.motion = effect.motion_override or emitter.definition.motion or effect.motion
    emitter.running = true
    emitter.accumulator = 0
    emitter.emitted = 0
    local spawn = resolve(emitter.definition.spawn or {}, effect, effect.random)
    emitter.mode = spawn.mode or "burst"
    if emitter.mode == "burst" then
        local count = math.max(0, math.floor(emitter.runtime_count or spawn.count or 1))
        for _ = 1, count do
            if spawn_entity_particle(emitter, effect) then emitter.emitted = emitter.emitted + 1 end
        end
        emitter.running = false
        emitter.finished_emission = true
    end
    emitter.finite = emitter.mode == "burst" or spawn.limit ~= nil
end

local function stop_emitter(emitter)
    emitter.running = false
    if emitter.native_id then gfx.particles.stop(emitter.native_id) end
    for _, uid in ipairs(emitter.containers or {}) do
        local entity = entities.exists(uid) and entities.get(uid)
        local component = entity and entity:get_component("wisplib:mesh_emitter")
        if component and component.stop then component.stop() end
    end
end

local function destroy_emitter(emitter)
    stop_emitter(emitter)
    for _, particle in ipairs(emitter.particles or {}) do
        if entities.exists(particle.uid) then entities.despawn(particle.uid) end
    end
    for _, uid in ipairs(emitter.containers or {}) do
        if entities.exists(uid) then entities.despawn(uid) end
    end
end

local function has_looping_audio(effect)
    for _, source in ipairs(effect.audio_sources or {}) do
        if source.loop then return true end
    end
    return false
end

local function start_all_emitters(effect)
    effect.emitters = {}
    local finite = true
    local controller, controller_error = make_controller(effect)
    if controller_error then return false, controller_error end
    effect.controller_instance = controller
    for index, definition in ipairs(effect.definition.emitters) do
        local emitter = {definition = clone(definition), index = index, running = false}
        emitter.definition.index = index
        if emitter.definition.backend == "mesh" then emitter.containers = {} end
        if emitter.definition.backend == "entity" then emitter.particles = {} end
        emitter.motion = effect.motion_override or emitter.definition.motion or effect.motion
        table.insert(effect.emitters, emitter)
        if emitter.definition.controller ~= nil then
            emitter.controller_config = clone(emitter.definition.controller)
            local emitter_controller, emitter_controller_error = make_controller(effect, emitter.controller_config)
            if emitter_controller_error then
                destroy_effect_controllers(effect)
                return false, "emitter " .. index .. " controller: " .. emitter_controller_error
            end
            emitter.controller_instance = emitter_controller
        end
        local ok, err = pcall(function()
            if emitter.definition.backend == "billboard" then
                start_billboard(emitter, effect)
            elseif emitter.definition.backend == "mesh" then
                start_mesh(emitter, effect)
            elseif emitter.definition.backend == "entity" then
                start_entity(emitter, effect)
            end
        end)
        if not ok then
            for _, previous in ipairs(effect.emitters) do destroy_emitter(previous) end
            effect.emitters = {}
            destroy_effect_controllers(effect)
            return false, tostring(err)
        end
        if not emitter.finite then finite = false end
    end
    -- An audio-only loop has no emitter completion event to keep its handle
    -- alive. Leave it running until stop/destroy (or an explicit duration).
    if #effect.emitters == 0 and has_looping_audio(effect) then finite = false end
    effect.auto_finish = finite
    return true
end

local function stop_effect(effect)
    if effect.state ~= "running" then return end
    effect.state = "stopping"
    effect.paused = false
    pause_effect_audio(effect, false)
    if not effect.stop_notified then
        fire_event(effect, "on_stop", {time = effect.age})
        effect.stop_notified = true
    end
    stop_effect_audio(effect, "stop")
    for _, emitter in ipairs(effect.emitters) do
        if emitter.containers then
            for _, uid in ipairs(emitter.containers) do
                local entity = entities.exists(uid) and entities.get(uid)
                local component = entity and entity:get_component("wisplib:mesh_emitter")
                if component and component.pause then component.pause(false) end
            end
        elseif emitter.particles then
            for _, particle in ipairs(emitter.particles) do
                if particle.body_was_enabled ~= nil and entities.exists(particle.uid) then
                    local entity = entities.get(particle.uid)
                    safe_call(entity and entity.rigidbody, "set_enabled", particle.body_was_enabled)
                    particle.body_was_enabled = nil
                end
            end
        end
        stop_emitter(emitter)
    end
end

local function emitter_finished(emitter)
    if emitter.native_id then
        return not gfx.particles.is_alive(emitter.native_id)
            and emitter.native_drain_elapsed >= (emitter.native_particle_lifetime or 5.0)
    end
    if emitter.containers then
        local alive = false
        for _, uid in ipairs(emitter.containers) do
            if entities.exists(uid) then
                local entity = entities.get(uid)
                local component = entity and entity:get_component("wisplib:mesh_emitter")
                if component and component.is_finished and not component.is_finished() then
                    alive = true
                end
            end
        end
        return not alive
    end
    if emitter.particles then
        for _, particle in ipairs(emitter.particles) do
            if entities.exists(particle.uid) then return false end
        end
    end
    return emitter.finished_emission == true
end

local function entity_update(emitter, effect, delta)
    local def = emitter.definition
    local spawn = resolve(def.spawn or {}, effect, effect.random)
    if emitter.running and emitter.mode == "rate" then
        local rate = math.max(0, tonumber(spawn.rate) or 0)
        emitter.accumulator = emitter.accumulator + rate * delta
        local count = math.floor(emitter.accumulator)
        emitter.accumulator = emitter.accumulator - count
        if spawn.limit then
            count = math.min(count, math.max(0, math.floor(spawn.limit - emitter.emitted)))
        end
        for _ = 1, count do
            local ok, spawned = pcall(spawn_entity_particle, emitter, effect)
            if ok and spawned then emitter.emitted = emitter.emitted + 1; effect.spawn_error = nil
            elseif not ok then effect.spawn_error = tostring(spawned) end
        end
        if spawn.limit and emitter.emitted >= spawn.limit then
            emitter.running = false
            emitter.finished_emission = true
        end
    end

    for index = #emitter.particles, 1, -1 do
        local particle = emitter.particles[index]
        if not entities.exists(particle.uid) then
            table.remove(emitter.particles, index)
        else
            particle.age = particle.age + delta
            if particle.age >= particle.lifetime then
                entities.despawn(particle.uid)
                fire_event(effect, "on_particle_death", {emitter = emitter.index, particle = index, uid = particle.uid, reason = "lifetime"})
                table.remove(emitter.particles, index)
            else
                local entity = entities.get(particle.uid)
                local body = entity and entity.rigidbody
                local collision = particle.collision or {type = "native_rigidbody"}
                for _, modifier in ipairs(particle.custom_modifiers or {}) do
                    local updater = modifier_extensions[modifier.type]
                    if updater then
                        local context = controller_context(effect, delta, index, #emitter.particles, particle)
                        context.entity = entity
                        if collision.type == "raycast" or collision.type == "custom" then
                            context.velocity = clone(particle.velocity or {0, 0, 0})
                        elseif body then
                            local got_velocity, velocity = pcall(function() return body:get_vel() end)
                            if got_velocity then context.velocity = velocity end
                        end
                        local ok, output = pcall(updater, particle, context, modifier)
                        if ok and type(output) == "table" then
                            if (collision.type == "raycast" or collision.type == "custom")
                                and finite_vec3(output.acceleration) then
                                particle.velocity = vadd(particle.velocity or {0, 0, 0}, vmul(output.acceleration, delta))
                            elseif (collision.type == "raycast" or collision.type == "custom")
                                and finite_vec3(output.velocity) then
                                particle.velocity = clone(output.velocity)
                            elseif body and finite_vec3(output.acceleration) then
                                local velocity = body:get_vel()
                                velocity = vadd(velocity, vmul(output.acceleration, delta))
                                safe_call(body, "set_vel", velocity)
                            elseif body and finite_vec3(output.velocity) then
                                safe_call(body, "set_vel", output.velocity)
                            end
                            if entity and finite_vec3(output.position) then entity.transform:set_pos(output.position) end
                            if entity and finite_mat4(output.rotation) then entity.transform:set_rot(output.rotation) end
                            if entity and finite_vec3(output.scale) then entity.transform:set_size(output.scale) end
                            if entity and type(output.color) == "table" then safe_call(entity.skeleton, "set_color", output.color) end
                        elseif not ok then
                            effect.controller_error = tostring(output)
                        end
                    end
                end
                if body and collision.type ~= "raycast" and collision.type ~= "custom"
                    and (particle.wind or particle.turbulence > 0) then
                    local velocity = body:get_vel()
                    if particle.wind then velocity = vadd(velocity, vmul(particle.wind, delta)) end
                    if particle.turbulence > 0 then
                        local t = particle.age
                        velocity[1] = velocity[1] + math.sin(t * 7 + particle.phase) * particle.turbulence * delta
                        velocity[3] = velocity[3] + math.cos(t * 5 + particle.phase) * particle.turbulence * delta
                    end
                    safe_call(body, "set_vel", velocity)
                end
                local collision_destroyed = false
                if entity and collision.type == "raycast" then
                    local position = entity.transform:get_pos()
                    local previous = particle.collision_position or position
                    local gravity = collision.gravity or {0, -22.6 * (particle.gravity or 1), 0}
                    local velocity = vadd(particle.velocity or {0, 0, 0}, vmul(gravity, delta))
                    local next_position = vadd(previous, vmul(velocity, delta))
                    local travel = vsub(next_position, previous)
                    local distance = vlen(travel)
                    local hit
                    if distance > 0.0001 then
                        raycasts_this_update = raycasts_this_update + 1
                        local ok, result = pcall(world.raycast, {
                            start = previous,
                            dir = vmul(travel, 1 / distance),
                            distance = distance + (collision.radius or 0),
                            entities = collision.entities == true,
                            ignore_uid = particle.uid,
                            nonselect_entities = collision.nonselect_entities == true,
                        })
                        if ok then hit = result else effect.collision_error = tostring(result) end
                    end
                    if hit and finite_vec3(hit.endpoint) then
                        local normal = finite_vec3(hit.normal) and vnorm(hit.normal) or {0, 1, 0}
                        local response = collision.response or "bounce"
                        local corrected = vadd(hit.endpoint, vmul(normal, (collision.radius or 0) + (collision.skin or 0.004)))
                        if response == "stop" then
                            velocity = {0, 0, 0}
                        elseif response == "bounce" then
                            local normal_speed = velocity[1] * normal[1] + velocity[2] * normal[2] + velocity[3] * normal[3]
                            if normal_speed < 0 then
                                velocity = vsub(velocity, vmul(normal, (1 + (collision.restitution or 0.5)) * normal_speed))
                            end
                            velocity = vmul(velocity, collision.damping or 1)
                        elseif response == "destroy" then
                            collision_destroyed = true
                        end
                        next_position = corrected
                        fire_event(effect, "on_collision", {
                            emitter = emitter.index, particle = index, uid = particle.uid,
                            position = clone(hit.endpoint), normal = clone(normal),
                            block = hit.block, entity = hit.entity, mode = "raycast",
                        })
                        if collision_destroyed then
                            entities.despawn(particle.uid)
                            fire_event(effect, "on_particle_death", {
                                emitter = emitter.index, particle = index, uid = particle.uid, reason = "collision",
                            })
                        end
                    end
                    particle.velocity = velocity
                    particle.collision_position = next_position
                    if not collision_destroyed then entity.transform:set_pos(next_position) end
                elseif entity and collision.type == "custom" then
                    local resolver = collision_extensions[collision.id]
                    local context = controller_context(effect, delta, index, #emitter.particles, particle, emitter)
                    context.entity = entity
                    context.position = entity.transform:get_pos()
                    context.velocity = clone(particle.velocity or {0, 0, 0})
                    local ok, output = pcall(resolver, particle, context, clone(collision))
                    if ok and type(output) == "table" then
                        if finite_vec3(output.position) then entity.transform:set_pos(output.position) end
                        if finite_vec3(output.velocity) then particle.velocity = clone(output.velocity) end
                        if finite_mat4(output.rotation) then entity.transform:set_rot(output.rotation) end
                        if finite_vec3(output.scale) then entity.transform:set_size(output.scale) end
                        if type(output.color) == "table" then safe_call(entity.skeleton, "set_color", output.color) end
                        if type(output.hit) == "table" then
                            fire_event(effect, "on_collision", merge(output.hit, {
                                emitter = emitter.index, particle = index, uid = particle.uid, mode = "custom",
                            }))
                        end
                        if output.destroy then
                            entities.despawn(particle.uid)
                            fire_event(effect, "on_particle_death", {
                                emitter = emitter.index, particle = index, uid = particle.uid, reason = "collision",
                            })
                            collision_destroyed = true
                        end
                    else
                        effect.collision_error = tostring(output)
                    end
                end
                if collision_destroyed then
                    table.remove(emitter.particles, index)
                elseif entity then
                    local life_ratio = math.max(0, math.min(1, particle.age / particle.lifetime))
                    local scale_factor = scale_vector(curve_sample(particle.scale_curve, life_ratio, 1), 1)
                    if particle.base_scale then
                        safe_call(entity.transform, "set_size", vmul(vhadamard(particle.base_scale, scale_factor), effect.scale))
                    end
                    local color = clone(curve_sample(particle.color_curve, life_ratio, particle.base_color))
                    color = apply_alpha(color, particle.alpha_curve, life_ratio, particle.opacity)
                    if color then safe_call(entity.skeleton, "set_color", color) end
                    if particle.rotation_speed ~= 0 then
                        local rotation = mat4.idt()
                        mat4.rotate(rotation, particle.rotation_axis, particle.rotation_speed * particle.age, rotation)
                        safe_call(entity.transform, "set_rot", rotation)
                    end
                end
            end
        end
    end
    if not emitter.running and #emitter.particles == 0 then emitter.finished_emission = true end
end

local function refresh_emitter(emitter, effect)
    if emitter.particles then
        local def = emitter.definition
        local spawn = resolve(def.spawn or {}, effect, effect.random)
        if (spawn.mode or "burst") == "burst" then
            local wanted = math.max(0, math.floor(emitter.runtime_count or spawn.count or 0))
            while #emitter.particles > wanted do
                local particle = table.remove(emitter.particles)
                if entities.exists(particle.uid) then entities.despawn(particle.uid) end
            end
            while #emitter.particles < wanted and emitter.finished_emission do
                if not spawn_entity_particle(emitter, effect) then break end
                emitter.emitted = emitter.emitted + 1
            end
        end
        local physics = resolve(def.physics or {}, effect, effect.random)
        local modifiers = resolve(def.modifiers or {}, effect, effect.random)
        local wind = def.wind and resolve(def.wind, effect, effect.random) or nil
        local turbulence = resolve(def.turbulence or 0, effect, effect.random)
        local rotation_speed = random_range(resolve(def.rotation_speed or 0, effect, effect.random), effect.random)
        local rotation_axis = resolve(def.rotation_axis or {0, 1, 0}, effect, effect.random)
        for _, modifier in ipairs(modifiers) do
            if modifier.type == "gravity" then physics.gravity = modifier.strength end
            if modifier.type == "drag" then physics.linear_damping = modifier.strength end
            if modifier.type == "wind" then wind = modifier.vector end
            if modifier.type == "turbulence" then turbulence = turbulence + (modifier.strength or 0) end
            if modifier.type == "rotation" then
                rotation_speed = random_range(modifier.speed or 0, effect.random)
                rotation_axis = modifier.axis or rotation_axis
            end
        end
        local appearance = resolve(def.appearance or {}, effect, effect.random)
        for _, particle in ipairs(emitter.particles) do
            local entity = entities.exists(particle.uid) and entities.get(particle.uid)
            if entity then
                particle.base_scale = sample_scale(appearance.scale or appearance.size or appearance.scale_range, effect.random, {1, 1, 1})
                particle.base_color = sample_color(appearance.color or appearance.color_range, effect.random)
                particle.color_curve = resolve(def.color_over_life, effect, effect.random)
                particle.scale_curve = resolve(def.scale_over_life, effect, effect.random)
                particle.alpha_curve = resolve(def.alpha_over_life, effect, effect.random)
                particle.opacity = appearance.opacity or 1
                particle.wind = clone(wind)
                particle.turbulence = turbulence
                particle.rotation_speed = rotation_speed
                particle.rotation_axis = clone(rotation_axis)
                safe_call(entity.transform, "set_size", vmul(particle.base_scale, effect.scale))
                if particle.base_color then safe_call(entity.skeleton, "set_color", particle.base_color) end
                if appearance.rotation then safe_call(entity.transform, "set_rot", rotation_matrix(appearance.rotation)) end
                if physics.gravity ~= nil then safe_call(entity.rigidbody, "set_gravity_scale", physics.gravity) end
                if physics.elasticity ~= nil then safe_call(entity.rigidbody, "set_elasticity", physics.elasticity) end
                if physics.mass ~= nil then safe_call(entity.rigidbody, "set_mass", physics.mass) end
                if physics.linear_damping ~= nil then safe_call(entity.rigidbody, "set_linear_damping", physics.linear_damping) end
                apply_motion_method(def, entity, effect, physics)
            end
        end
        return
    end
    if emitter.native_id then
        if emitter.mode == "burst" then return end
        gfx.particles.stop(emitter.native_id)
        start_billboard(emitter, effect)
        if effect.paused and emitter.mode == "rate" then
            gfx.particles.stop(emitter.native_id)
            emitter.was_rate = true
        end
    elseif emitter.containers then
        local settings = mesh_settings(emitter, effect, effect.random)
        local capacity = math.max(1, math.floor(settings.capacity or 512))
        local count = math.max(0, math.floor(settings.count or 128))
        local batches = math.max(1, math.ceil(count / capacity))
        local previous_count = emitter.controller_count or count
        local replaced = batches ~= #emitter.containers or capacity ~= emitter.controller_capacity
        if replaced then
            emitter.controller_ages = {}
            emitter.controller_lifetimes = {}
            emitter.pose_history = {}
            emitter.container_bounds = {}
            for _, uid in ipairs(emitter.containers) do if entities.exists(uid) then entities.despawn(uid) end end
            emitter.containers = {}
            local remaining = count
            for index = 1, batches do
                local batch = math.min(capacity, remaining)
                spawn_mesh_container(emitter, effect, batch, index)
                remaining = remaining - batch
            end
        else
            if count ~= previous_count and emitter.pose_history then
                for particle_index = math.min(count, previous_count) + 1,
                    math.max(count, previous_count) do
                    local container_index = math.floor((particle_index - 1) / capacity) + 1
                    local history = emitter.pose_history[container_index]
                    if history then
                        history[(particle_index - 1) % capacity + 1] = nil
                    end
                end
            end
            if count > previous_count and emitter.controller_ages then
                for index = previous_count + 1, count do
                    emitter.controller_ages[index] = nil
                    if emitter.controller_lifetimes then emitter.controller_lifetimes[index] = nil end
                end
            end
            for index, uid in ipairs(emitter.containers) do
                local entity = entities.exists(uid) and entities.get(uid)
                local component = entity and entity:get_component("wisplib:mesh_emitter")
                if entity then
                    if emitter.motion ~= "controlled" and emitter.motion ~= "hybrid" then
                        safe_call(entity.transform, "set_size",
                            {effect.scale, effect.scale, effect.scale})
                    end
                end
                if component and component.set_settings then
                    local batch = math.max(0, math.min(capacity, count - (index - 1) * capacity))
                    local per_container = clone(settings)
                    per_container.count = batch
                    component.set_settings(per_container)
                end
            end
        end
        emitter.controller_count = count
        emitter.controller_capacity = capacity
    end
end

function API.spawn(id, options)
    if options == nil then options = {} end
    if type(options) ~= "table" then return nil, "spawn options must be a table" end
    local supplied_anchor = options.anchor
    local legacy_parent = options.parent ~= nil and supplied_anchor == nil
    if legacy_parent then supplied_anchor = {type = "entity", uid = options.parent} end
    local position = options.position or options.origin or (supplied_anchor and options.offset) or {0, 0, 0}
    local offset = options.offset or {0, 0, 0}
    local space = options.space or (legacy_parent and "world" or (supplied_anchor and "local" or "world"))
    local scale = options.scale == nil and 1 or tonumber(options.scale)
    local seed = options.seed == nil and next_id * 104729 or tonumber(options.seed)
    if options.parameters ~= nil and type(options.parameters) ~= "table" then
        return nil, "parameters must be a table"
    end
    if not finite_vec3(position) then return nil, "position must be a finite numeric vec3" end
    if not finite_vec3(offset) then return nil, "offset must be a finite numeric vec3" end
    if not finite_number(scale) or scale <= 0 then return nil, "scale must be a positive finite number" end
    if not finite_number(seed) then return nil, "seed must be a finite number" end
    if options.rotation ~= nil and not finite_mat4(options.rotation) then
        return nil, "rotation must be a finite mat4 matrix"
    end
    if options.points ~= nil then
        if type(options.points) ~= "table" then return nil, "points must be an array of vec3 values" end
        for index, point in ipairs(options.points) do
            if not finite_vec3(point) then return nil, "point " .. index .. " must be a finite vec3" end
        end
    end
    if space ~= "world" and space ~= "local" and space ~= "parent" then
        return nil, "space must be world, local, or parent"
    end
    if space ~= "world" and not valid_anchor(supplied_anchor) then
        return nil, "local/parent space requires a valid world or entity anchor"
    end
    if supplied_anchor and not valid_anchor(supplied_anchor) then
        return nil, "anchor must be a world or entity anchor"
    end
    if supplied_anchor and supplied_anchor.type == "entity" and not entities.exists(supplied_anchor.uid) then
        return nil, "entity anchor UID is not currently alive"
    end
    for _, name in ipairs({"source", "target"}) do
        if options[name] ~= nil and not valid_anchor(options[name]) then
            return nil, name .. " must be a valid world or entity anchor"
        end
        if options[name] and options[name].type == "entity" and not entities.exists(options[name].uid) then
            return nil, name .. " Entity UID is not currently alive"
        end
    end
    local definition, err = load_definition(id)
    if not definition then return nil, err end
    local motion = options.motion or definition.motion or "simulated"
    if motion ~= "simulated" and motion ~= "controlled" and motion ~= "hybrid" then
        return nil, "motion must be simulated, controlled, or hybrid"
    end
    local anchor_policy = options.anchor_policy or definition.anchor_policy or "freeze"
    if anchor_policy ~= "freeze" and anchor_policy ~= "stop" and anchor_policy ~= "destroy" and anchor_policy ~= "detach" then
        return nil, "anchor_policy must be freeze, stop, destroy, or detach"
    end
    local duration = options.duration
    if duration == nil then duration = definition.duration end
    if duration ~= nil and (not finite_number(duration) or duration < 0) then
        return nil, "duration must be a non-negative finite number"
    end
    local ok, validation = API.validate(id, definition)
    if not ok then return nil, validation end
    local requested_audio = definition.audio
    if options.audio ~= nil then requested_audio = options.audio end
    local audio_sources, audio_error = normalize_audio_sources(id,
        requested_audio, id .. ": spawn audio")
    if not audio_sources then return nil, audio_error end
    if options.controller ~= nil and type(options.controller) ~= "table" then
        return nil, "controller must be an object"
    end
    for index, emitter in ipairs(definition.emitters) do
        local emitter_motion = options.motion or emitter.motion or definition.motion or motion
        if emitter.backend == "billboard" and emitter_motion ~= "simulated" then
            return nil, id .. ": emitter " .. index .. " billboard backend has no controlled transform capability"
        end
        local collision_ok, collision_error = validate_collision_config(id, "emitter " .. index,
            emitter.backend, emitter_motion, emitter.collision)
        if not collision_ok then return nil, collision_error end
    end
    if options.controller ~= nil then
        local controller_ok, controller_error = validate_controller_config(id, "spawn controller", options.controller)
        if not controller_ok then return nil, controller_error end
    end

    local instance_id = next_id
    next_id = next_id + 1
    local effect = {
        id = instance_id,
        generation = generation,
        name = id,
        definition = definition,
        parameters = resolve_parameters(definition, options),
        audio_sources = audio_sources,
        audio_speakers = {},
        audio_error = nil,
        position = clone(position),
        anchor = clone(supplied_anchor),
        source_anchor = clone(options.source or (options.source == nil and supplied_anchor or nil)),
        target_anchor = clone(options.target),
        space = space,
        inherit_rotation = options.inherit_rotation ~= false,
        inherit_scale = options.inherit_scale == true,
        legacy_parent = legacy_parent,
        parent_uid = legacy_parent and options.parent or nil,
        parent_offset = clone(offset),
        controller_config = clone(options.controller or definition.controller),
        points = clone(options.points or (options.controller and options.controller.points)
            or (definition.controller and definition.controller.points)),
        motion = motion,
        motion_override = options.motion,
        anchor_policy = anchor_policy,
        local_rotation = options.rotation and clone(options.rotation) or mat4.idt(),
        controller_instance = nil,
        scale = scale,
        seed = seed,
        age = 0,
        state = "running",
        run_generation = 1,
        emitters = {},
        random = rng_for(seed),
        duration = duration,
    }
    instances[instance_id] = effect
    if options.events ~= nil then
        if type(options.events) ~= "table" then
            instances[instance_id] = nil
            return nil, "events must be a table of callback functions"
        end
        for event, callback in pairs(options.events) do
            local registered, event_error = API.on(
                {id = instance_id, generation = effect.generation}, event, callback
            )
            if not registered then
                instances[instance_id] = nil
                event_handlers[instance_id] = nil
                return nil, event_error
            end
        end
    end
    local started, start_error = start_all_emitters(effect)
    if not started then
        instances[instance_id] = nil
        event_handlers[instance_id] = nil
        generation = generation + 1
        return nil, id .. ": " .. start_error
    end
    local handle = setmetatable({id = instance_id, generation = effect.generation}, Handle)
    fire_event(effect, "on_start", {effect = id})
    return handle
end

function API.update(delta_override)
    local now = time.precise_time()
    local measured_delta = now - last_update
    local delta = finite_number(delta_override)
        and math.max(0, math.min(0.1, delta_override))
        or math.max(0, math.min(0.1, measured_delta))
    last_update = now
    local screen_ok, screen_error = pcall(screenfx._update, delta)
    if not screen_ok then screenfx._record_update_error(screen_error) end
    raycasts_this_update = 0
    local finished = {}
    for _, effect in pairs(instances) do
        update_effect_audio(effect)
        for _, emitter in ipairs(effect.emitters) do
            if emitter.native_id then
                if gfx.particles.is_alive(emitter.native_id) then
                    emitter.native_drain_elapsed = 0
                else
                    emitter.native_drain_elapsed = (emitter.native_drain_elapsed or 0) + delta
                end
            end
        end
        if effect.legacy_parent and effect.parent_uid ~= nil and entities.exists(effect.parent_uid) then
            current_position(effect)
        end
        local anchor_lost = false
        local function missing(anchor)
            return anchor and anchor.type == "entity" and not entities.exists(anchor.uid)
        end
        local legacy_parent_lost = effect.legacy_parent and effect.parent_uid ~= nil
            and not entities.exists(effect.parent_uid)
        anchor_lost = missing(effect.anchor) or missing(effect.source_anchor)
            or missing(effect.target_anchor) or legacy_parent_lost
        if legacy_parent_lost and effect.anchor_policy == "freeze" then
            local frozen_position = current_position(effect)
            for _, emitter in ipairs(effect.emitters) do
                if emitter.native_id then gfx.particles.set_origin(emitter.native_id, frozen_position) end
            end
        end
        if anchor_lost and effect.anchor_policy == "stop" then
            stop_effect(effect)
        elseif anchor_lost and effect.anchor_policy == "destroy" then
            API.destroy({id = effect.id, generation = effect.generation})
        elseif anchor_lost and effect.anchor_policy == "detach" then
            local current = effect_transform(effect)
            if effect.anchor or effect.legacy_parent then
                effect.position = clone(current.position)
                effect.anchor = nil
                effect.space = "world"
                effect.legacy_parent = false
                effect.parent_uid = nil
                effect.last_parent_position = nil
                for _, emitter in ipairs(effect.emitters) do
                    if emitter.native_id then gfx.particles.set_origin(emitter.native_id, effect.position) end
                end
            end
            if effect.source_anchor and effect.source_anchor.type == "entity" and effect.last_source_transform then
                effect.source_anchor = {type = "world", position = clone(effect.last_source_transform.position)}
            end
            if effect.target_anchor and effect.target_anchor.type == "entity" and effect.last_target_transform then
                effect.target_anchor = {type = "world", position = clone(effect.last_target_transform.position)}
            end
        end
        for _, item in ipairs({{"source", effect.source_anchor}, {"target", effect.target_anchor}}) do
            if item[2] then
                local transform, valid = resolve_anchor(item[2], item[1] == "source" and effect.last_source_transform or effect.last_target_transform)
                if valid then
                    if item[1] == "source" then effect.last_source_transform = clone(transform)
                    else effect.last_target_transform = clone(transform) end
                end
            end
        end
        if effect.state == "running" and not effect.paused then
            effect.age = effect.age + delta
            if effect.duration and effect.age >= effect.duration then stop_effect(effect) end
            update_controller(effect, effect.controller_instance, delta)
            for _, emitter in ipairs(effect.emitters) do
                if emitter.controller_instance ~= effect.controller_instance then
                    update_controller(effect, emitter.controller_instance, delta, emitter)
                end
                if emitter.native_id and ((effect.anchor and effect.anchor.type == "entity")
                    or effect.legacy_parent) then
                    gfx.particles.set_origin(emitter.native_id, current_position(effect))
                end
                if (emitter.motion == "controlled" or emitter.motion == "hybrid") then
                    update_controlled_emitter(emitter, effect, delta)
                elseif emitter.particles then
                    entity_update(emitter, effect, delta)
                elseif emitter.containers and (effect.anchor or effect.legacy_parent) then
                    local transform = effect_transform(effect)
                    for _, uid in ipairs(emitter.containers) do
                        local entity = entities.exists(uid) and entities.get(uid)
                        if entity then
                            entity.transform:set_pos(transform.position)
                            entity.transform:set_rot(transform.rotation)
                        end
                    end
                end
            end
            if effect.state == "running" and effect.auto_finish then
                local done = true
                for _, emitter in ipairs(effect.emitters) do
                    if not emitter_finished(emitter) then done = false break end
                end
                if done then
                    local completed_run = effect.run_generation
                    effect.state = "finished"
                    fire_event(effect, "on_finished", {time = effect.age})
                    if effect.state == "finished" and effect.run_generation == completed_run then
                        stop_effect_audio(effect, "finish")
                        table.insert(finished, {id = effect.id, run_generation = completed_run})
                    end
                end
            end
            if effect.state == "stopping" then
                local done = true
                for _, emitter in ipairs(effect.emitters) do
                    if not emitter_finished(emitter) then done = false break end
                end
                if done then
                    local completed_run = effect.run_generation
                    effect.state = "finished"
                    fire_event(effect, "on_finished", {time = effect.age})
                    if effect.state == "finished" and effect.run_generation == completed_run then
                        stop_effect_audio(effect, "finish")
                        table.insert(finished, {id = effect.id, run_generation = completed_run})
                    end
                end
            end
        elseif effect.state == "stopping" then
            for _, emitter in ipairs(effect.emitters) do
                if emitter.native_id and effect.parent_uid and
                    (effect.parent_offset[1] ~= 0 or effect.parent_offset[2] ~= 0 or effect.parent_offset[3] ~= 0) then
                    gfx.particles.set_origin(emitter.native_id, current_position(effect))
                end
                if emitter.particles then entity_update(emitter, effect, delta) end
            end
            local done = true
            for _, emitter in ipairs(effect.emitters) do
                if not emitter_finished(emitter) then done = false break end
            end
            if done then
                local completed_run = effect.run_generation
                effect.state = "finished"
                fire_event(effect, "on_finished", {time = effect.age})
                if effect.state == "finished" and effect.run_generation == completed_run then
                    stop_effect_audio(effect, "finish")
                    table.insert(finished, {id = effect.id, run_generation = completed_run})
                end
            end
        end
    end
    for _, completed in ipairs(finished) do
        local effect = instances[completed.id]
        if effect and effect.state == "finished" and effect.run_generation == completed.run_generation then
            for _, emitter in ipairs(effect.emitters) do destroy_emitter(emitter) end
            effect.emitters = {}
            destroy_effect_controllers(effect)
        end
    end
end

function API.stop(handle)
    local effect = get_instance(handle)
    if not effect then return false end
    stop_effect(effect)
    return true
end

function API.destroy(handle)
    local effect = get_instance(handle)
    if not effect then return false end
    for _, entry in ipairs(effect.audio_speakers or {}) do
        if not entry.source.stop_on_destroy and type(audio) == "table" then
            pcall(audio.resume, entry.id)
        end
    end
    stop_effect_audio(effect, "destroy")
    for _, emitter in ipairs(effect.emitters) do destroy_emitter(emitter) end
    effect.state = "destroyed"
    instances[effect.id] = nil
    destroy_effect_controllers(effect)
    event_handlers[effect.id] = nil
    return true
end

function API.exists(handle)
    return get_instance(handle) ~= nil
end

function API.state(handle)
    local effect = get_instance(handle)
    if not effect then return "destroyed" end
    if effect.paused then return "paused" end
    return effect.state
end

function API.set_parameter(handle, name, value)
    local effect = get_instance(handle)
    if not effect then return false, "effect handle is no longer valid" end
    if effect.state == "stopping" then return false, "cannot edit an effect while it is stopping" end
    local spec = (effect.definition.parameters or {})[name]
    if not spec then return false, "unknown effect parameter: " .. tostring(name) end
    local normalized, validation_error = validate_parameter_overrides(effect.definition, {[name] = value})
    if not normalized then return false, validation_error end
    local previous = clone(effect.parameters[name])
    effect.parameters[name] = clone(normalized[name])
    local billboard_rate_recreated = false
    local billboard_burst_deferred = false
    if effect.state == "running" then
        for _, emitter in ipairs(effect.emitters) do
            if emitter.native_id then
                if emitter.mode == "burst" then
                    billboard_burst_deferred = true
                elseif emitter.mode == "rate" then
                    billboard_rate_recreated = true
                end
            end
            local ok, err = pcall(refresh_emitter, emitter, effect)
            if not ok then
                effect.parameters[name] = previous
                for _, restore_emitter in ipairs(effect.emitters) do
                    pcall(refresh_emitter, restore_emitter, effect)
                end
                return false, tostring(err)
            end
        end
    end
    if billboard_rate_recreated and billboard_burst_deferred then
        return true, nil, "billboard_rate_recreated_burst_deferred"
    elseif billboard_rate_recreated then
        return true, nil, "billboard_rate_recreated"
    elseif billboard_burst_deferred then
        return true, nil, "billboard_burst_deferred"
    end
    return true
end

function API.set(handle, name, value)
    local effect = get_instance(handle)
    if not effect then return false, "effect handle is no longer valid" end
    if effect.state == "stopping" then return false, "cannot edit an effect while it is stopping" end
    if name == "scale" then
        value = tonumber(value)
        if not finite_number(value) or value <= 0 then return false, "scale must be a positive finite number" end
        local previous = effect.scale
        effect.scale = value
        for _, emitter in ipairs(effect.emitters) do
            local ok, err = pcall(refresh_emitter, emitter, effect)
            if not ok then
                effect.scale = previous
                for _, restore_emitter in ipairs(effect.emitters) do pcall(refresh_emitter, restore_emitter, effect) end
                return false, tostring(err)
            end
        end
        return true
    elseif name == "rotation" then
        if not finite_mat4(value) then return false, "rotation must be a finite mat4 matrix" end
        effect.local_rotation = clone(value)
        return true
    end
    return API.set_parameter(handle, name, value)
end

function API.get(handle, name)
    local effect = get_instance(handle)
    if not effect then return nil end
    if name == "position" then return current_position(effect) end
    if name == "state" then return API.state(handle) end
    if name == "scale" then return effect.scale end
    if name == "audio" then return clone(effect.audio_sources) end
    if name == "audio_error" then return effect.audio_error end
    if name == "callback_error" then return effect.callback_error end
    if name == "action_error" then return effect.action_error end
    if name == "controller_error" then return effect.controller_error end
    if name == "collision_error" then return effect.collision_error end
    if name == "spawn_error" then return effect.spawn_error end
    return clone(effect.parameters[name])
end

function API.set_audio(handle, sources)
    local effect = get_instance(handle)
    if not effect then return false, "effect handle is no longer valid" end
    local requested = sources
    if requested == nil then requested = effect.definition.audio end
    local normalized, err = normalize_audio_sources(effect.name, requested, effect.name .. ": runtime audio")
    if not normalized then return false, err end
    stop_effect_audio(effect, "replace", true)
    effect.audio_sources = normalized
    effect.audio_error = nil
    if #effect.emitters == 0 then effect.auto_finish = not has_looping_audio(effect) end
    return true
end

function API.get_parameter(handle, name)
    local effect = get_instance(handle)
    if not effect then return nil end
    return clone(effect.parameters[name])
end

function API.move(handle, position)
    local effect = get_instance(handle)
    if not effect or not finite_vec3(position) then return false end
    effect.position = clone(position)
    effect.space = "world"
    effect.anchor = nil
    effect.parent_uid = nil
    effect.legacy_parent = false
    for _, emitter in ipairs(effect.emitters) do
        if emitter.native_id then gfx.particles.set_origin(emitter.native_id, position) end
        for _, uid in ipairs(emitter.containers or {}) do
            local entity = entities.exists(uid) and entities.get(uid)
            if entity then entity.transform:set_pos(position) end
        end
    end
    return true
end

function API.attach(handle, parent_uid, offset)
    local effect = get_instance(handle)
    if not effect or not finite_number(parent_uid) or parent_uid < 0 or parent_uid % 1 ~= 0
        or not entities.exists(parent_uid) then return false end
    offset = offset or {0, 0, 0}
    if not finite_vec3(offset) then return false end
    effect.parent_uid = parent_uid
    effect.anchor = nil
    effect.space = "world"
    effect.legacy_parent = true
    effect.parent_offset = clone(offset)
    effect.last_parent_position = nil
    effect.position = current_position(effect)
    for _, emitter in ipairs(effect.emitters) do
        if emitter.native_id then
            gfx.particles.set_origin(emitter.native_id, current_position(effect))
        end
        for _, uid in ipairs(emitter.containers or {}) do
            local entity = entities.exists(uid) and entities.get(uid)
            if entity then entity.transform:set_pos(current_position(effect)) end
        end
    end
    return true
end

function API.set_anchor(handle, anchor, space)
    local effect = get_instance(handle)
    if not effect or not valid_anchor(anchor) then return false, "anchor must be a world or entity anchor" end
    if anchor.type == "entity" and not entities.exists(anchor.uid) then return false, "anchor Entity UID is not alive" end
    space = space or "local"
    if space ~= "world" and space ~= "local" and space ~= "parent" then
        return false, "space must be world, local, or parent"
    end
    local current_world_position = current_position(effect)
    if space == "world" then
        effect.position = clone(current_world_position)
    else
        local frame = resolve_anchor(anchor)
        effect.position = point_to_local(current_world_position, frame)
        if effect.inherit_scale then
            for index = 1, 3 do
                local divisor = frame.scale[index]
                if math.abs(divisor) > 0.000001 then effect.position[index] = effect.position[index] / divisor end
            end
        end
    end
    effect.anchor = clone(anchor)
    effect.space = space
    effect.legacy_parent = false
    effect.parent_uid = nil
    effect.last_transform = nil
    return true
end

function API.set_source_target(handle, source, target)
    local effect = get_instance(handle)
    if not effect or not valid_anchor(source) or not valid_anchor(target) then
        return false, "source and target must be world or entity anchors"
    end
    if (source.type == "entity" and not entities.exists(source.uid))
        or (target.type == "entity" and not entities.exists(target.uid)) then
        return false, "source and target Entity UIDs must be alive"
    end
    effect.source_anchor, effect.target_anchor = clone(source), clone(target)
    return true
end

function API.set_points(handle, points)
    local effect = get_instance(handle)
    if not effect or type(points) ~= "table" then return false, "points must be an array of vec3 values" end
    for index, point in ipairs(points) do
        if not finite_vec3(point) then return false, "point " .. index .. " must be a finite vec3" end
    end
    effect.points = clone(points)
    return true
end

function API.set_count(handle, count, emitter_index)
    local effect = get_instance(handle)
    count = tonumber(count)
    if not effect or not finite_number(count) or count < 0 or count % 1 ~= 0 then
        return false, "count must be a non-negative integer"
    end
    local changed = false
    for index, emitter in ipairs(effect.emitters) do
        if emitter_index == nil or emitter_index == index then
            if emitter.containers or (emitter.particles and emitter.mode == "burst") then
                emitter.runtime_count = count
                local ok, err = pcall(refresh_emitter, emitter, effect)
                if not ok then return false, tostring(err) end
                changed = true
            end
        end
    end
    if not changed then return false, "no count-controlled mesh or burst Entity emitter matched" end
    return true
end

function API.release_particles(handle, options)
    local effect = get_instance(handle)
    if not effect then return false, "effect handle is no longer valid" end
    options = options or {}
    if type(options) ~= "table" then return false, "release options must be an object" end
    local released = 0
    for _, emitter in ipairs(effect.emitters) do
        if emitter.motion == "controlled" or emitter.motion == "hybrid" then
            if emitter.particles then
                for _, particle in ipairs(emitter.particles) do
                    if entities.exists(particle.uid) then
                        local entity = entities.get(particle.uid)
                        local collision = particle.collision or {type = "native_rigidbody"}
                        local velocity = options.velocity or "radial"
                        if velocity == "radial" then
                            local speed = tonumber(options.speed) or 0
                            velocity = vmul(vnorm(vsub(entity.transform:get_pos(), current_position(effect))), speed)
                        elseif type(velocity) == "table" and velocity.type == "radial" then
                            local speed = tonumber(velocity.speed) or tonumber(options.speed) or 0
                            velocity = vmul(vnorm(vsub(entity.transform:get_pos(), current_position(effect))), speed)
                        elseif type(velocity) ~= "table" or not finite_vec3(velocity) then
                            velocity = particle.velocity or {0, 0, 0}
                        end
                        local owns_motion = collision.type == "raycast" or collision.type == "custom"
                        safe_call(entity.rigidbody, "set_enabled", not owns_motion)
                        if not owns_motion then safe_call(entity.rigidbody, "set_vel", velocity) end
                        particle.velocity = clone(velocity)
                        particle.collision_position = entity.transform:get_pos()
                        particle.controlled = false
                        released = released + 1
                    end
                end
                emitter.motion = "simulated"
            elseif emitter.containers then
                return false, "mesh particles cannot be released as independent rigidbodies"
            end
        end
    end
    if released == 0 then return false, "no controlled Entity particles are available to release" end
    return true, released
end

function API.restart(handle)
    local effect = get_instance(handle)
    if not effect then return false, "effect handle is no longer valid" end
    stop_effect_audio(effect, "restart", true)
    for _, emitter in ipairs(effect.emitters) do destroy_emitter(emitter) end
    destroy_effect_controllers(effect)
    effect.emitters = {}
    effect.controller_instance = nil
    effect.controller_frame = nil
    effect.age = 0
    effect.run_generation = (effect.run_generation or 0) + 1
    effect.state = "running"
    effect.paused = false
    effect.stop_notified = false
    local ok, err = start_all_emitters(effect)
    if not ok then effect.state = "finished"; return false, err end
    fire_event(effect, "on_start", {effect = effect.name, restarted = true})
    return true
end

function API.pause(handle)
    local effect = get_instance(handle)
    if not effect or effect.paused or effect.state ~= "running" then return false end
    effect.paused = true
    pause_effect_audio(effect, true)
    for _, emitter in ipairs(effect.emitters) do
        if emitter.native_id then
            gfx.particles.stop(emitter.native_id)
            emitter.was_rate = emitter.mode == "rate"
        elseif emitter.containers then
            for _, uid in ipairs(emitter.containers) do
                local entity = entities.exists(uid) and entities.get(uid)
                local component = entity and entity:get_component("wisplib:mesh_emitter")
                if component and component.pause then component.pause(true) end
            end
        elseif emitter.particles then
            for _, particle in ipairs(emitter.particles) do
                local entity = entities.exists(particle.uid) and entities.get(particle.uid)
                local body = entity and entity.rigidbody
                if body then
                    particle.body_was_enabled = body:is_enabled()
                    safe_call(body, "set_enabled", false)
                end
            end
        end
    end
    return true
end

function API.resume(handle)
    local effect = get_instance(handle)
    if not effect or not effect.paused or effect.state ~= "running" then return false end
    effect.paused = false
    pause_effect_audio(effect, false)
    for _, emitter in ipairs(effect.emitters) do
        if emitter.native_id and emitter.was_rate then
            start_billboard(emitter, effect)
            emitter.was_rate = false
        elseif emitter.containers then
            for _, uid in ipairs(emitter.containers) do
                local entity = entities.exists(uid) and entities.get(uid)
                local component = entity and entity:get_component("wisplib:mesh_emitter")
                if component and component.pause then component.pause(false) end
            end
        elseif emitter.particles then
            for _, particle in ipairs(emitter.particles) do
                local entity = entities.exists(particle.uid) and entities.get(particle.uid)
                local body = entity and entity.rigidbody
                if body and particle.body_was_enabled ~= nil then
                    safe_call(body, "set_enabled", particle.body_was_enabled)
                    particle.body_was_enabled = nil
                end
            end
        end
    end
    return true
end

function API.capabilities()
    return {
        screen = {
            post_processing = true,
            client_only = true,
            shader_assets = true,
            inputs = {"u_screen", "u_skybox", "u_timer", "u_screenSize",
                "u_projection", "u_view", "u_inverseView", "u_cameraPos"},
            advanced_inputs = {"u_position", "u_normal", "u_emission", "u_noise", "u_ssao"},
            parameters = {"float", "number", "int", "vec2", "vec3", "vec4", "color", "array"},
            array_input = "typed table or packed bytes, checked against declared capacity",
            arrays_required_before_play = true,
            transitions = {"intensity", "float", "vec2", "vec3", "vec4", "color"},
            compute_shader = false,
            custom_texture_binding = false,
            custom_vertex_shader = false,
            custom_framebuffer = false,
            world_geometry = false,
        },
        billboard = {position = true, native_preset = true, controlled_transform = false,
            color = false, scale = false, collision = {"none"},
            pause_semantics = "emission_only"},
        mesh = {position = true, rotation = true, scale = true, color = true,
            color_components = 4, alpha_blending = "material-dependent",
            per_particle_model = true, vector_scale = true, batch_pose = true,
            controlled_transform = true, collision = {"none"}, release_to_rigidbody = false},
        entity = {position = true, rotation = true, scale = true, color = true,
            color_components = 4, alpha_blending = "material-dependent", vector_scale = true,
            controlled_transform = true, collision = {"none", "native_rigidbody", "raycast", "custom"},
            collision_events = {raycast = true, custom = true, native_rigidbody = false},
            release_to_rigidbody = true},
        audio = {sound = true, stream = true, stream_formats = {".ogg", ".OGG", ".wav", ".WAV"},
            direct_url_stream = false, spatial = true, follow_effect = true,
            loop = true, pause_resume = true, events = {
                "on_start", "on_spawn", "on_collision", "on_particle_death", "on_stop", "on_finished",
            }},
    }
end

function API.stop_all()
    local handles = {}
    for id, effect in pairs(instances) do
        handles[#handles + 1] = {id = id, generation = effect.generation}
    end
    for _, handle in ipairs(handles) do API.destroy(handle) end
    screenfx.stop_all()
end

function API.stop_transient_all()
    local persistent = {}
    for _, record in pairs(world_effects) do
        local handle = record.runtime
        if handle then persistent[handle.id .. ":" .. handle.generation] = true end
    end
    local handles = {}
    for id, effect in pairs(instances) do
        local key = id .. ":" .. effect.generation
        if not persistent[key] then handles[#handles + 1] = {id = id, generation = effect.generation} end
    end
    for _, handle in ipairs(handles) do API.destroy(handle) end
    screenfx.stop_all()
end

function API.stats()
    local screen_stats = screenfx.stats()
    local result = {effects = 0, world_effects = 0, billboards = 0, mesh_particles = 0,
        entities = 0, controlled_particles = 0, simulated_particles = 0,
        audio_speakers = 0, raycasts = raycasts_this_update,
        screen_effects = screen_stats.active, screen_effect_handles = screen_stats.handles,
        screen_effect_engine_active = screen_stats.engine_active,
        screen_effect_errors = screen_stats.errors,
        screen_effect_last_update_error = screen_stats.last_update_error}
    for _, effect in pairs(instances) do
        if effect.state ~= "finished" then result.effects = result.effects + 1 end
        for _, entry in ipairs(effect.audio_speakers or {}) do
            if type(audio) == "table" then
                local ok, alive = pcall(audio.is_playing, entry.id)
                local paused_ok, paused = pcall(audio.is_paused, entry.id)
                if (ok and alive) or (paused_ok and paused) then result.audio_speakers = result.audio_speakers + 1 end
            end
        end
        for _, emitter in ipairs(effect.emitters) do
            if emitter.native_id then result.billboards = result.billboards + 1 end
            for _, uid in ipairs(emitter.containers or {}) do
                if entities.exists(uid) then
                    local entity = entities.get(uid)
                    local component = entity and entity:get_component("wisplib:mesh_emitter")
                    if component and component.get_count then result.mesh_particles = result.mesh_particles + component.get_count() end
                end
            end
            for _, particle in ipairs(emitter.particles or {}) do
                if entities.exists(particle.uid) then
                    result.entities = result.entities + 1
                    if particle.controlled then result.controlled_particles = result.controlled_particles + 1
                    else result.simulated_particles = result.simulated_particles + 1 end
                end
            end
        end
    end
    for _ in pairs(world_effects) do result.world_effects = result.world_effects + 1 end
    return result
end

function API.handles()
    local result = {}
    for id, effect in pairs(instances) do
        local handle = setmetatable({id = id, generation = effect.generation}, Handle)
        handle.name = effect.name
        table.insert(result, handle)
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

local WorldAPI = {}
local WorldHandle = {}
WorldHandle.__index = WorldHandle
local world_next_id = 1
local world_load_error = nil
local client_autostart_pending = {}

local function json_safe(value, seen, label)
    label = label or "value"
    local kind = type(value)
    if kind == "nil" or kind == "boolean" or kind == "string" then return true end
    if kind == "number" then
        if finite_number(value) then return true end
        return false, label .. " contains a non-finite number"
    end
    if kind ~= "table" then return false, label .. " contains a non-serializable " .. kind end
    if seen[value] then return false, label .. " contains a cyclic table" end
    seen[value] = true
    for key, item in pairs(value) do
        local key_type = type(key)
        if key_type ~= "string" and not (key_type == "number" and key >= 1 and key % 1 == 0) then
            seen[value] = nil
            return false, label .. " contains an unsupported table key"
        end
        local ok, err = json_safe(item, seen, label .. "." .. tostring(key))
        if not ok then seen[value] = nil; return false, err end
    end
    seen[value] = nil
    return true
end

local function storage_path(filename)
    if not world.is_open() then return nil, "world is not open" end
    -- VoxelCore's pack storage helper creates world:data/wisplib and keeps
    -- these records with the world when it is copied or rewritten.
    local ok, path = pcall(pack.data_file, "wisplib", filename or "world_effects.json")
    if not ok then return nil, "cannot access world pack storage: " .. tostring(path) end
    return path
end

-- Adler-32 detects incomplete or changed slot contents; it is not a security signature.
local function world_storage_checksum(content)
    local a, b = 1, 0
    for index = 1, #content do
        a = (a + content:byte(index)) % 65521
        b = (b + a) % 65521
    end
    return string.format("%08x", b * 65536 + a)
end

local world_storage_slots = {"world_effects.a.json", "world_effects.b.json"}

local function valid_world_storage_document(document)
    if type(document) ~= "table" or document.schema ~= 1
        or type(document.effects) ~= "table" then return false end
    local count = 0
    for key in pairs(document.effects) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
        count = count + 1
    end
    return count == #document.effects
end

local function read_world_storage_slot(index)
    local path, path_error = storage_path(world_storage_slots[index])
    if not path then return nil, path_error end
    if not file.exists(path) then return nil end
    local ok, wrapper = pcall(function() return json.parse(file.read(path)) end)
    if not ok or type(wrapper) ~= "table" or wrapper.schema ~= 2
        or type(wrapper.payload) ~= "string" or type(wrapper.checksum) ~= "string"
        or not finite_number(wrapper.generation) or wrapper.generation < 1
        or wrapper.generation % 1 ~= 0
        or wrapper.checksum ~= world_storage_checksum(wrapper.payload) then
        return nil, "saved VFX slot " .. index .. " is incomplete or has an invalid checksum"
    end
    local parsed, document = pcall(json.parse, wrapper.payload)
    if not parsed or not valid_world_storage_document(document) then
        return nil, "saved VFX slot " .. index .. " contains an invalid schema or effects array"
    end
    return {document = document, generation = wrapper.generation,
        payload = wrapper.payload, path = path}
end

local function latest_world_storage_slot()
    local best, best_index, errors, present = nil, nil, {}, false
    for index = 1, #world_storage_slots do
        local path, path_error = storage_path(world_storage_slots[index])
        if not path then return nil, nil, path_error end
        if file.exists(path) then present = true end
        local slot, slot_error = read_world_storage_slot(index)
        if slot_error then errors[#errors + 1] = slot_error end
        if slot and (not best or slot.generation > best.generation) then
            best, best_index = slot, index
        end
    end
    if present and not best then return nil, nil, table.concat(errors, "; ") end
    return best, best_index
end

local function needs_particle_frontend(definition)
    for _, emitter in ipairs(definition.emitters or {}) do
        if emitter.backend == "billboard" then return true end
    end
    return false
end

local function particle_frontend_ready()
    return type(gfx) == "table" and type(gfx.particles) == "table"
        and type(gfx.particles.emit) == "function"
end

local function persistent_record_valid(record)
    if type(record) ~= "table" or type(record.id) ~= "string"
        or not record.id:match("^world_fx_%d+$") or type(record.effect_id) ~= "string"
        or not valid_extension_id(record.effect_id) then
        return false, "record requires string id and effect_id"
    end
    if record.name ~= nil and (type(record.name) ~= "string" or record.name == "") then
        return false, "name must be a non-empty string when supplied"
    end
    if record.enabled ~= nil and type(record.enabled) ~= "boolean" then
        return false, "enabled must be boolean"
    end
    if record.autostart ~= nil and type(record.autostart) ~= "boolean" then
        return false, "autostart must be boolean"
    end
    if record.anchor_policy ~= nil and record.anchor_policy ~= "freeze" and record.anchor_policy ~= "stop"
        and record.anchor_policy ~= "destroy" and record.anchor_policy ~= "detach" then
        return false, "anchor_policy must be freeze, stop, destroy, or detach"
    end
    if type(record.transform) ~= "table" or not finite_vec3(record.transform.position)
        or not finite_mat4(record.transform.rotation) or not finite_number(record.transform.scale)
        or record.transform.scale <= 0 then
        return false, "transform requires finite position, mat4 rotation, and positive scale"
    end
    for _, key in ipairs({"anchor", "source", "target"}) do
        local anchor = record[key]
        if anchor ~= nil and (not valid_anchor(anchor) or anchor.type ~= "world"
            or not finite_vec3(anchor.position)) then
            return false, key .. " must be a static world anchor to be persistent"
        end
    end
    if record.motion ~= nil and record.motion ~= "simulated" and record.motion ~= "controlled" and record.motion ~= "hybrid" then
        return false, "motion must be simulated, controlled, or hybrid"
    end
    local controller_ok, controller_error = validate_controller_config(
        record.effect_id, "saved controller", record.controller)
    if not controller_ok then return false, controller_error end
    if record.parameters ~= nil and type(record.parameters) ~= "table" then
        return false, "parameters must be an object"
    end
    if record.audio ~= nil then
        local audio_sources, audio_error = normalize_audio_sources(record.effect_id, record.audio,
            "WorldEffect " .. record.id .. " audio")
        if not audio_sources then return false, audio_error end
    end
    if record.points ~= nil then
        if type(record.points) ~= "table" then return false, "points must be an array" end
        for index, point in ipairs(record.points) do
            if not finite_vec3(point) then return false, "point " .. index .. " must be a finite vec3" end
        end
    end
    if record.tags ~= nil then
        if type(record.tags) ~= "table" then return false, "tags must be an array" end
        for index, tag in ipairs(record.tags) do if type(tag) ~= "string" then return false, "tag " .. index .. " must be a string" end end
    end
    local ok, err = json_safe(record, {}, "world effect " .. record.id)
    if not ok then return false, err end
    return true
end

local function world_handle(id)
    if not world_effects[id] then return nil end
    return setmetatable({id = id}, WorldHandle)
end

local function normalized_static_anchor(anchor, fallback_position)
    if not anchor then return nil end
    local result = clone(anchor)
    result.position = finite_vec3(result.position) and clone(result.position)
        or clone(fallback_position or {0, 0, 0})
    result.rotation = finite_mat4(result.rotation) and clone(result.rotation) or mat4.idt()
    result.scale = finite_vec3(result.scale) and clone(result.scale) or {1, 1, 1}
    return result
end

local function spawn_world_record(record, force)
    if not record.enabled or (not force and not record.autostart) or record.runtime then return true end
    local valid, err = persistent_record_valid(record)
    if not valid then return false, err end
    local definition, load_error = load_definition(record.effect_id)
    if not definition then return false, load_error end
    local local_rotation = record.anchor
        and rotation_to_local(record.transform.rotation, record.anchor.rotation or mat4.idt())
        or clone(record.transform.rotation)
    local options = {
        position = clone(record.transform.position),
        rotation = local_rotation,
        scale = record.transform.scale,
        space = "world",
        anchor = clone(record.anchor),
        inherit_scale = record.anchor and record.anchor.inherit_scale == true or false,
        audio = clone(record.audio),
        parameters = clone(record.parameters or {}),
        controller = clone(record.controller),
        points = clone(record.points),
        motion = record.motion,
        source = clone(record.source),
        target = clone(record.target),
        anchor_policy = record.anchor_policy or "freeze",
    }
    local handle, spawn_error = API.spawn(record.effect_id, options)
    if not handle then return false, spawn_error end
    record.runtime = handle
    return true
end

function WorldAPI.create(effect_id, options)
    options = options or {}
    if type(options) ~= "table" then return nil, "world effect options must be an object" end
    for _, key in ipairs({"enabled", "autostart"}) do
        if options[key] ~= nil and type(options[key]) ~= "boolean" then
            return nil, key .. " must be boolean"
        end
    end
    if options.anchor_policy ~= nil and options.anchor_policy ~= "freeze" and options.anchor_policy ~= "stop"
        and options.anchor_policy ~= "destroy" and options.anchor_policy ~= "detach" then
        return nil, "anchor_policy must be freeze, stop, destroy, or detach"
    end
    local path, storage_error = storage_path()
    if not path then return nil, storage_error end
    if world_load_error then return nil, "cannot create WorldEffects after a failed load: " .. world_load_error end
    local definition, err = load_definition(effect_id)
    if not definition then return nil, err end
    local parameter_overrides, parameter_error = validate_parameter_overrides(
        definition, options.parameters, "WorldEffect parameters")
    if not parameter_overrides then return nil, parameter_error end
    local world_audio
    if options.audio ~= nil then
        local audio_error
        world_audio, audio_error = normalize_audio_sources(effect_id, options.audio,
            effect_id .. ": WorldEffect audio")
        if not world_audio then return nil, audio_error end
    end
    local transform = options.transform or {}
    local position = options.position or transform.position or (options.anchor and options.anchor.position) or {0, 0, 0}
    local rotation = options.rotation or transform.rotation or (options.anchor and options.anchor.rotation) or mat4.idt()
    local scale = options.scale == nil and (transform.scale == nil and 1 or tonumber(transform.scale)) or tonumber(options.scale)
    if not finite_vec3(position) then return nil, "world effect position must be a finite vec3" end
    if not finite_mat4(rotation) then return nil, "world effect rotation must be a finite mat4" end
    if not finite_number(scale) or scale <= 0 then return nil, "world effect scale must be positive and finite" end
    for _, key in ipairs({"anchor", "source", "target"}) do
        local anchor = options[key]
        if anchor ~= nil and (not valid_anchor(anchor) or anchor.type ~= "world") then
            return nil, key .. " must be a static world anchor; Entity UID anchors cannot be persisted"
        end
    end
    local tags = clone(options.tags or {})
    if type(tags) ~= "table" then return nil, "tags must be an array of strings" end
    for index, tag in ipairs(tags) do if type(tag) ~= "string" then return nil, "tag " .. index .. " must be a string" end end
    if options.name ~= nil then
        if type(options.name) ~= "string" or options.name == "" then return nil, "name must be a non-empty string" end
        if WorldAPI.get_by_name(options.name) then return nil, "world effect name already exists: " .. options.name end
    end
    local id = "world_fx_" .. world_next_id
    world_next_id = world_next_id + 1
    local record = {
        id = id,
        name = options.name,
        effect_id = effect_id,
        transform = {position = clone(position), rotation = clone(rotation), scale = scale},
        anchor = normalized_static_anchor(options.anchor, position),
        parameters = parameter_overrides,
        audio = clone(world_audio),
        controller = clone(options.controller or definition.controller),
        points = clone(options.points),
        source = clone(options.source),
        target = clone(options.target),
        motion = options.motion or definition.motion or "simulated",
        anchor_policy = options.anchor_policy or "freeze",
        enabled = options.enabled == nil or options.enabled,
        autostart = options.autostart == nil or options.autostart,
        tags = tags,
        placeable = definition.world and definition.world.placeable == true or false,
    }
    local valid, validation_error = persistent_record_valid(record)
    if not valid then return nil, validation_error end
    world_effects[id] = record
    if record.enabled and record.autostart then
        if needs_particle_frontend(definition) and not particle_frontend_ready() then
            if not vc.is_client() then
                world_effects[id] = nil
                return nil, "billboard WorldEffect requires a client frontend"
            end
            client_autostart_pending[id] = true
        else
            local started, start_error = spawn_world_record(record)
            if not started then world_effects[id] = nil; return nil, start_error end
        end
    end
    return world_handle(id)
end

function WorldAPI.get(id) return world_handle(id) end
function WorldAPI.get_by_name(name)
    for _, record in pairs(world_effects) do if record.name == name then return world_handle(record.id) end end
end
function WorldAPI.list()
    local result = {}
    for id in pairs(world_effects) do result[#result + 1] = world_handle(id) end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end
function WorldAPI.find_by_tag(tag)
    local result = {}
    for id, record in pairs(world_effects) do
        for _, value in ipairs(record.tags or {}) do
            if value == tag then result[#result + 1] = world_handle(id); break end
        end
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end
function WorldAPI.delete(id)
    local record = world_effects[id]
    if not record then return false end
    if record.runtime then record.runtime:destroy(); record.runtime = nil end
    client_autostart_pending[id] = nil
    world_effects[id] = nil
    return true
end
function WorldAPI.duplicate(id, overrides)
    local source = world_effects[id]
    if not source then return nil, "unknown world effect " .. tostring(id) end
    local record = clone(source)
    record.runtime = nil
    record.id = nil
    record.name = (overrides and overrides.name) or (source.name and source.name .. " copy")
    for key, value in pairs(overrides or {}) do record[key] = clone(value) end
    record.id = nil
    return WorldAPI.create(record.effect_id, record)
end
function WorldAPI.save()
    local latest, latest_index, storage_error = latest_world_storage_slot()
    if storage_error then return false, storage_error end
    if world_load_error then
        return false, "refusing to overwrite a WorldEffect file that failed to load: " .. world_load_error
    end
    if not file.is_writeable("world:") then
        return false, "current world storage is not writable"
    end
    local list = {}
    for _, record in pairs(world_effects) do
        local saved = clone(record)
        saved.runtime = nil
        list[#list + 1] = saved
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    local document = {schema = 1, next_id = world_next_id, effects = list}
    local ok, content = pcall(json.tostring, document, true)
    if not ok then return false, "cannot encode world effects: " .. tostring(content) end
    local target_index = latest_index == 1 and 2 or 1
    local path, path_error = storage_path(world_storage_slots[target_index])
    if not path then return false, path_error end
    local wrapper = {schema = 2, generation = latest and latest.generation + 1 or 1,
        checksum = world_storage_checksum(content), payload = content}
    local encoded, bytes = pcall(json.tostring, wrapper, true)
    if not encoded then return false, "cannot encode world effects slot: " .. tostring(bytes) end
    if not file.isdir("world:data/wisplib") then
        return false, "cannot create world:data/wisplib storage folder"
    end
    local wrote, write_result = pcall(function()
        return file.write_bytes(path, Bytearray(bytes))
    end)
    if not wrote or write_result ~= true then
        return false, "cannot write world effects: " .. tostring(wrote and "storage device reported a failed write" or write_result)
    end
    local verified, verify_error = read_world_storage_slot(target_index)
    if not verified or verified.payload ~= content
        or verified.generation ~= wrapper.generation then
        return false, "world effects write could not be verified: " .. tostring(verify_error)
    end
    -- After a verified migration, remove the old single-file copy so that a
    -- future missing pair of slots cannot silently resurrect stale records.
    local legacy_path = storage_path()
    if legacy_path and file.exists(legacy_path) then
        local removed, remove_result = pcall(file.remove, legacy_path)
        if not removed or remove_result ~= true then
            return false, "world effects slot was saved, but legacy file cleanup failed"
        end
    end
    return true
end
function WorldAPI.load()
    local latest, _, slot_error = latest_world_storage_slot()
    if slot_error then
        world_load_error = slot_error
        return false, slot_error
    end
    local path, storage_error = storage_path()
    if not path then return false, storage_error end
    local candidate, candidate_next, errors = {}, 1, {}
    if latest or file.exists(path) then
        local ok, loaded
        if latest then
            ok, loaded = true, latest.document
        else
            ok, loaded = pcall(function() return json.parse(file.read(path)) end)
        end
        if not ok or type(loaded) ~= "table" or loaded.schema ~= 1 or type(loaded.effects) ~= "table" then
            world_load_error = "saved VFX file is invalid or uses an unsupported schema"
            return false, world_load_error
        end
        local entry_count = 0
        for key in pairs(loaded.effects) do
            if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
                world_load_error = "saved VFX effects must be a dense array"
                return false, world_load_error
            end
            entry_count = entry_count + 1
        end
        if entry_count ~= #loaded.effects then
            world_load_error = "saved VFX effects must be a dense array"
            return false, world_load_error
        end
        local saved_next = tonumber(loaded.next_id)
        if saved_next and finite_number(saved_next) and saved_next >= 1 then
            candidate_next = math.floor(saved_next)
        end
        for index, record in ipairs(loaded.effects) do
            local valid, validation_error = persistent_record_valid(record)
            if valid and candidate[record.id] then
                valid, validation_error = false, "duplicate persistent id " .. record.id
            end
            if valid and record.name ~= nil then
                for _, existing in pairs(candidate) do
                    if existing.name == record.name then
                        valid, validation_error = false, "duplicate persistent name " .. record.name
                        break
                    end
                end
            end
            if valid then
                local definition, definition_error = load_definition(record.effect_id)
                if not definition then
                    valid, validation_error = false, "definition unavailable: " .. tostring(definition_error)
                else
                    local normalized, parameter_error = validate_parameter_overrides(
                        definition, record.parameters, "parameters")
                    if not normalized then
                        valid, validation_error = false, parameter_error
                    else
                        record.parameters = normalized
                        local controller_ok, controller_error = validate_controller_config(
                            record.effect_id, "saved controller", record.controller)
                        if not controller_ok then valid, validation_error = false, controller_error end
                    end
                end
            end
            if valid then
                record.runtime = nil
                candidate[record.id] = record
                local numeric_id = tonumber(record.id:match("^world_fx_(%d+)$"))
                if numeric_id then candidate_next = math.max(candidate_next, numeric_id + 1) end
            else
                errors[#errors + 1] = "record " .. tostring(index) .. " skipped: " .. tostring(validation_error)
            end
        end
    end

    -- Missing definitions and invalid records must not disappear on the next
    -- automatic world save. Keep the current runtime set until the file can
    -- be loaded intact or the caller explicitly clears it.
    if #errors > 0 then
        world_load_error = "saved VFX file contains invalid records: " .. table.concat(errors, "; ")
        return false, world_load_error
    end

    -- Commit only after parsing and structural validation. A malformed file
    -- must not destroy the active in-memory WorldEffect set.
    for _, record in pairs(world_effects) do if record.runtime then record.runtime:destroy() end end
    world_effects, world_next_id = candidate, candidate_next
    world_load_error = nil
    client_autostart_pending = {}
    for _, record in pairs(world_effects) do
        if record.enabled and record.autostart then
            local definition, definition_error = load_definition(record.effect_id)
            if not definition then
                errors[#errors + 1] = record.id .. ": " .. tostring(definition_error)
            elseif needs_particle_frontend(definition) and not particle_frontend_ready() then
                if vc.is_client() then
                    client_autostart_pending[record.id] = true
                else
                    errors[#errors + 1] = record.id .. ": billboard backend requires a client frontend"
                end
            else
                local started, start_error = spawn_world_record(record)
                if not started then errors[#errors + 1] = record.id .. ": " .. tostring(start_error) end
            end
        end
    end
    return true, errors
end
function WorldAPI.clear()
    local previous_effects, previous_next_id = world_effects, world_next_id
    local previous_error, previous_pending = world_load_error, client_autostart_pending
    world_effects, world_next_id, world_load_error, client_autostart_pending = {}, 1, nil, {}
    local saved, save_error = WorldAPI.save()
    if not saved then
        world_effects, world_next_id = previous_effects, previous_next_id
        world_load_error, client_autostart_pending = previous_error, previous_pending
        return false, save_error
    end
    for _, record in pairs(previous_effects) do
        if record.runtime then record.runtime:destroy() end
    end
    return true
end
function WorldAPI.stop_runtime()
    for _, record in pairs(world_effects) do
        if record.runtime then record.runtime:destroy(); record.runtime = nil end
    end
end
function WorldAPI.start_pending_client()
    if not particle_frontend_ready() then return {} end
    local errors = {}
    for id in pairs(client_autostart_pending) do
        client_autostart_pending[id] = nil
        local record = world_effects[id]
        if record and record.enabled and record.autostart and not record.runtime then
            local started, start_error = spawn_world_record(record)
            if not started then errors[#errors + 1] = id .. ": " .. tostring(start_error) end
        end
    end
    return errors
end
function WorldAPI.close()
    WorldAPI.stop_runtime()
    world_effects, world_next_id = {}, 1
    world_load_error, client_autostart_pending = nil, {}
end

function WorldHandle:exists() return world_effects[self.id] ~= nil end
function WorldHandle:get(name)
    local record = world_effects[self.id]
    if not record then return nil end
    if name == "runtime_state" then return record.runtime and record.runtime:state() or "stopped" end
    if name == "id" or name == "name" or name == "effect_id" or name == "enabled"
        or name == "autostart" or name == "tags" or name == "controller" or name == "points" or name == "audio"
        or name == "motion" or name == "anchor" or name == "source" or name == "target" then
        return clone(record[name])
    end
    if record.transform[name] ~= nil then return clone(record.transform[name]) end
    return clone(record.parameters[name])
end
function WorldHandle:get_parameter(name)
    local record = world_effects[self.id]
    if not record then return nil end
    return clone(record.parameters and record.parameters[name])
end
function WorldHandle:start()
    local record = world_effects[self.id]
    if not record then return false, "world effect was deleted" end
    local was_enabled = record.enabled
    local previous_runtime = record.runtime
    record.enabled = true
    if previous_runtime and previous_runtime:state() == "running" then return true end
    record.runtime = nil
    local ok, err = spawn_world_record(record, true)
    if not ok then
        record.enabled, record.runtime = was_enabled, previous_runtime
        return false, err
    end
    if previous_runtime then previous_runtime:destroy() end
    client_autostart_pending[self.id] = nil
    return true
end
function WorldHandle:stop()
    local record = world_effects[self.id]
    if not record then return false end
    if client_autostart_pending[self.id] then
        client_autostart_pending[self.id] = nil
        return true
    end
    if not record.runtime then return false end
    return record.runtime:stop()
end
function WorldHandle:restart()
    local record = world_effects[self.id]
    if not record then return false, "world effect was deleted" end
    if not record.runtime then return self:start() end
    return record.runtime:restart()
end
function WorldHandle:move(position)
    local record = world_effects[self.id]
    if not record or not finite_vec3(position) then return false end
    local replacement = record.anchor and clone(record.anchor) or nil
    if replacement then replacement.position = clone(position) end
    if record.runtime then
        local moved, move_error = record.runtime:move(position)
        if not moved then return false, move_error end
        if replacement then
            local attached, attach_error = record.runtime:set_anchor(replacement, "world")
            if not attached then
                record.runtime:move(record.transform.position)
                if record.anchor then
                    record.runtime:set_anchor(record.anchor, "world")
                    record.runtime:set("rotation", rotation_to_local(
                        record.transform.rotation, record.anchor.rotation or mat4.idt()))
                else
                    record.runtime:set("rotation", record.transform.rotation)
                end
                return false, attach_error
            end
            local rotated, rotation_error = record.runtime:set("rotation",
                rotation_to_local(record.transform.rotation, replacement.rotation or mat4.idt()))
            if not rotated then
                record.runtime:move(record.transform.position)
                if record.anchor then
                    record.runtime:set_anchor(record.anchor, "world")
                    record.runtime:set("rotation", rotation_to_local(
                        record.transform.rotation, record.anchor.rotation or mat4.idt()))
                else
                    record.runtime:set("rotation", record.transform.rotation)
                end
                return false, rotation_error
            end
        end
    end
    record.transform.position = clone(position)
    record.anchor = replacement
    return true
end
function WorldHandle:set_rotation(rotation)
    local record = world_effects[self.id]
    if not record or not finite_mat4(rotation) then return false end
    if record.runtime then
        local local_rotation = record.anchor
            and rotation_to_local(rotation, record.anchor.rotation or mat4.idt())
            or rotation
        local applied, apply_error = record.runtime:set("rotation", local_rotation)
        if not applied then return false, apply_error end
    end
    record.transform.rotation = clone(rotation)
    return true
end
function WorldHandle:set_scale(scale)
    local record = world_effects[self.id]
    scale = tonumber(scale)
    if not record or not finite_number(scale) or scale <= 0 then return false end
    if record.runtime then
        local applied, apply_error = record.runtime:set("scale", scale)
        if not applied then return false, apply_error end
    end
    record.transform.scale = scale
    return true
end
function WorldHandle:set(name, value)
    local record = world_effects[self.id]
    if not record then return false, "world effect was deleted" end
    local definition, definition_error = load_definition(record.effect_id)
    if not definition then return false, definition_error end
    local normalized, parameter_error = validate_parameter_overrides(definition, {[name] = value}, "parameter")
    if not normalized then return false, parameter_error end
    local ok, err = json_safe(value, {}, "parameter " .. tostring(name))
    if not ok then return false, err end
    local apply_status
    if record.runtime then
        local applied, apply_error, status = record.runtime:set_parameter(name, normalized[name])
        if not applied then return false, apply_error end
        apply_status = status
    end
    record.parameters[name] = clone(normalized[name])
    return true, nil, apply_status
end
function WorldHandle:set_parameter(name, value) return self:set(name, value) end
function WorldHandle:set_name(name)
    local record = world_effects[self.id]
    if not record then return false, "world effect was deleted" end
    if type(name) ~= "string" or name == "" then return false, "name must be a non-empty string" end
    local other = WorldAPI.get_by_name(name)
    if other and other.id ~= self.id then return false, "world effect name already exists: " .. name end
    record.name = name
    return true
end
function WorldHandle:set_autostart(value)
    local record = world_effects[self.id]
    if not record then return false, "world effect was deleted" end
    if type(value) ~= "boolean" then return false, "autostart must be boolean" end
    record.autostart = value
    if not value then client_autostart_pending[self.id] = nil end
    return true
end
function WorldHandle:set_tags(tags)
    local record = world_effects[self.id]
    if not record or type(tags) ~= "table" then return false, "tags must be an array of strings" end
    local copy = clone(tags)
    for index, tag in ipairs(copy) do
        if type(tag) ~= "string" then return false, "tag " .. index .. " must be a string" end
    end
    local ok, err = json_safe(copy, {}, "tags")
    if not ok then return false, err end
    record.tags = copy
    return true
end
function WorldHandle:set_audio(sources)
    local record = world_effects[self.id]
    if not record then return false, "world effect was deleted" end
    local normalized
    if sources ~= nil then
        local err
        normalized, err = normalize_audio_sources(record.effect_id, sources, record.effect_id .. ": WorldEffect audio")
        if not normalized then return false, err end
        local safe, safe_error = json_safe(normalized, {}, "WorldEffect audio")
        if not safe then return false, safe_error end
    end
    if record.runtime then
        local applied, apply_error = record.runtime:set_audio(normalized)
        if not applied then return false, apply_error end
    end
    record.audio = clone(normalized)
    return true
end
function WorldHandle:set_anchor(anchor)
    local record = world_effects[self.id]
    if not record then return false, "world effect was deleted" end
    if anchor ~= nil and (not valid_anchor(anchor) or anchor.type ~= "world") then
        return false, "persistent anchors must be static world anchors"
    end
    local previous = record.anchor
    local replacement = normalized_static_anchor(anchor, record.transform.position)
    if record.runtime then
        if replacement then
            local attached, attach_error = record.runtime:set_anchor(replacement, "world")
            if not attached then return false, attach_error end
            local local_rotation = rotation_to_local(record.transform.rotation, replacement.rotation)
            local rotated, rotation_error = record.runtime:set("rotation", local_rotation)
            if not rotated then
                if previous then
                    record.runtime:set_anchor(previous, "world")
                    record.runtime:set("rotation", rotation_to_local(
                        record.transform.rotation, previous.rotation or mat4.idt()))
                else
                    record.runtime:move(record.transform.position)
                    record.runtime:set("rotation", record.transform.rotation)
                end
                return false, rotation_error
            end
        else
            record.runtime:move(record.transform.position)
            local rotated, rotation_error = record.runtime:set("rotation", record.transform.rotation)
            if not rotated then
                if previous then
                    record.runtime:set_anchor(previous, "world")
                    record.runtime:set("rotation", rotation_to_local(record.transform.rotation, previous.rotation))
                end
                return false, rotation_error
            end
        end
    end
    record.anchor = replacement
    return true
end
function WorldHandle:set_controller(config)
    local record = world_effects[self.id]
    if not record then return false, "world effect was deleted" end
    if config ~= nil then
        local ok, err = validate_controller_config(record.effect_id, "WorldEffect controller", config)
        if not ok then return false, err end
    end
    local valid, err = json_safe(config, {}, "controller")
    if not valid then return false, err end
    local previous_controller, previous_runtime = record.controller, record.runtime
    record.controller = clone(config)
    if previous_runtime and record.enabled then
        record.runtime = nil
        local started, start_error = spawn_world_record(record, true)
        if not started then
            record.controller, record.runtime = previous_controller, previous_runtime
            return false, start_error
        end
        previous_runtime:destroy()
    end
    return true
end
function WorldHandle:enable() return self:start() end
function WorldHandle:disable()
    local record = world_effects[self.id]
    if not record then return false end
    record.enabled = false
    client_autostart_pending[self.id] = nil
    if record.runtime then record.runtime:destroy(); record.runtime = nil end
    return true
end
function WorldHandle:save() return WorldAPI.save() end
function WorldHandle:delete() return WorldAPI.delete(self.id) end
WorldAPI.WorldHandle = WorldHandle
API.world = WorldAPI

function Handle:stop() return API.stop(self) end
function Handle:destroy() return API.destroy(self) end
function Handle:exists() return API.exists(self) end
function Handle:state() return API.state(self) end
function Handle:set(name, value) return API.set(self, name, value) end
function Handle:get(name) return API.get(self, name) end
function Handle:set_parameter(name, value) return API.set_parameter(self, name, value) end
function Handle:get_parameter(name) return API.get_parameter(self, name) end
function Handle:set_audio(sources) return API.set_audio(self, sources) end
function Handle:move(position) return API.move(self, position) end
function Handle:attach(parent_uid, offset) return API.attach(self, parent_uid, offset) end
function Handle:set_anchor(anchor, space) return API.set_anchor(self, anchor, space) end
function Handle:set_source_target(source, target) return API.set_source_target(self, source, target) end
function Handle:set_points(points) return API.set_points(self, points) end
function Handle:set_count(count, emitter_index) return API.set_count(self, count, emitter_index) end
function Handle:release_particles(options) return API.release_particles(self, options) end
function Handle:on(event, callback) return API.on(self, event, callback) end
function Handle:emit(event, details) return API.emit(self, event, details) end
function Handle:pause() return API.pause(self) end
function Handle:resume() return API.resume(self) end
function Handle:restart() return API.restart(self) end

API.screen = screenfx

return API
