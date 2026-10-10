-- High-level client-side API for VoxelCore's gfx.posteffects.
-- A content pack still owns the GLSL asset and declares its slot in resources.json.
local API = {API_VERSION = "0.1.0", SCHEMA_VERSION = 1}

local definitions = {}
local handles = {}
local slot_owners = {}
local effect_owners = {}
local next_id = 1
local last_update_error

local Handle = {}
Handle.__index = Handle

local function release_handle(handle)
    handle.state = "destroyed"
    handle.intensity = 0
    handle.intensity_tween = nil
    handle.parameter_tweens = {}
    handles[handle.id] = nil
    if slot_owners[handle.slot] == handle then slot_owners[handle.slot] = nil end
    if effect_owners[handle.definition.effect] == handle then effect_owners[handle.definition.effect] = nil end
end

local PARAM_TYPES = {
    float = 0,
    number = 0,
    int = 0,
    vec2 = 2,
    vec3 = 3,
    vec4 = 4,
    color = 4,
}
local ARRAY_TYPES = {float = true, int = true, vec2 = true, vec3 = true, vec4 = true}
local ARRAY_BYTES = {float = 4, int = 4, vec2 = 8, vec3 = 12, vec4 = 16}
local MAX_FLOAT32 = 3.402823466e38
local MAX_BYTEARRAY_SIZE = 2147483647
local RESERVED_UNIFORMS = {
    u_intensity = true, u_screen = true, u_skybox = true, u_position = true,
    u_normal = true, u_emission = true, u_noise = true, u_ssao = true,
    u_screenSize = true, u_cameraPos = true, u_timer = true,
    u_projection = true, u_view = true, u_inverseView = true,
}
local EASINGS = {linear = true, smooth = true, smoothstep = true, ["in"] = true, ["out"] = true, in_out = true}
local ACTIVE_INTENSITY_THRESHOLD = 1e-4

local function is_finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = clone(item) end
    return result
end

local function namespaced(value)
    return type(value) == "string"
        and value:match("^[%w_]+:[%w_%.%-%_/]+$") ~= nil
        and not value:find("..", 1, true)
end

local function asset_alias(value)
    return type(value) == "string"
        and value:match("^[%w_][%w_%.%-%_/]*$") ~= nil
        and not value:find("..", 1, true)
end

local function split_id(id)
    if not namespaced(id) then return nil, nil end
    local pack, name = id:match("^([^:]+):(.+)$")
    return pack, name
end

local function normalize_value(definition, value)
    local kind = definition.type
    local dimensions = PARAM_TYPES[kind]
    if dimensions == nil then return nil, "unsupported parameter type '" .. tostring(kind) .. "'" end

    if kind == "float" or kind == "number" or kind == "int" then
        if not is_finite(value) then return nil, "expected a finite number" end
        if kind == "int" and value % 1 ~= 0 then return nil, "expected an integer" end
        if is_finite(definition.min) then value = math.max(value, definition.min) end
        if is_finite(definition.max) then value = math.min(value, definition.max) end
        if kind == "int" and (value < -2147483648 or value > 2147483647) then
            return nil, "expected a signed 32-bit integer"
        end
        if kind ~= "int" and math.abs(value) > MAX_FLOAT32 then
            return nil, "value is outside the finite 32-bit float range"
        end
        return value
    end

    if type(value) ~= "table" or #value ~= dimensions then
        return nil, "expected a " .. kind .. " array with " .. dimensions .. " numbers"
    end
    local result = {}
    for index = 1, dimensions do
        local component = value[index]
        if not is_finite(component) then return nil, "component " .. index .. " must be finite" end
        if is_finite(definition.min) then component = math.max(component, definition.min) end
        if is_finite(definition.max) then component = math.min(component, definition.max) end
        if math.abs(component) > MAX_FLOAT32 then
            return nil, "component " .. index .. " is outside the finite 32-bit float range"
        end
        result[index] = component
    end
    return result
end

local function validate_definition(id, definition)
    if not namespaced(id) then return false, "screen effect ID must be namespaced" end
    if type(definition) ~= "table" then return false, id .. ": definition must be an object" end
    if definition.schema ~= API.SCHEMA_VERSION then
        return false, id .. ": unsupported schema; expected " .. API.SCHEMA_VERSION
    end
    if not namespaced(definition.slot) then
        return false, id .. ": slot must be a namespaced post-effect-slot ID"
    end
    if not asset_alias(definition.effect) then
        return false, id .. ": effect must be an unqualified asset alias declared in preload.json"
    end
    if definition.parameters ~= nil and type(definition.parameters) ~= "table" then
        return false, id .. ": parameters must be an object"
    end
    local uniforms = {}
    for name, parameter in pairs(definition.parameters or {}) do
        if type(name) ~= "string" or name == "" or type(parameter) ~= "table" then
            return false, id .. ": each parameter must have a name and object definition"
        end
        if type(parameter.uniform) ~= "string"
            or parameter.uniform:match("^[%a_][%w_]*$") == nil then
            return false, id .. ": parameter '" .. name .. "' needs a GLSL uniform name"
        end
        if RESERVED_UNIFORMS[parameter.uniform] then
            return false, id .. ": parameter '" .. name .. "' uses VoxelCore-reserved uniform '"
                .. parameter.uniform .. "'"
        end
        if uniforms[parameter.uniform] then
            return false, id .. ": parameters '" .. uniforms[parameter.uniform]
                .. "' and '" .. name .. "' use the same GLSL uniform"
        end
        uniforms[parameter.uniform] = name
        if parameter.type ~= "array" and PARAM_TYPES[parameter.type] == nil then
            return false, id .. ": parameter '" .. name .. "' has unsupported type"
        end
        if parameter.type == "array" then
            if not ARRAY_TYPES[parameter.element_type] then
                return false, id .. ": array parameter '" .. name .. "' needs element_type float/int/vec2/vec3/vec4"
            end
            if not is_finite(parameter.capacity) or parameter.capacity < 1 or parameter.capacity % 1 ~= 0 then
                return false, id .. ": array parameter '" .. name .. "' needs a positive integer capacity"
            end
            if parameter.capacity > math.floor(MAX_BYTEARRAY_SIZE / ARRAY_BYTES[parameter.element_type]) then
                return false, id .. ": array parameter '" .. name .. "' exceeds Bytearray's signed 32-bit size limit"
            end
            if parameter.default ~= nil or parameter.min ~= nil or parameter.max ~= nil then
                return false, id .. ": array parameter '" .. name .. "' cannot declare default, min, or max"
            end
        elseif parameter.default == nil then
            return false, id .. ": parameter '" .. name .. "' needs a default value"
        else
            local _, err = normalize_value(parameter, parameter.default)
            if err then return false, id .. ": parameter '" .. name .. "' default: " .. err end
        end
        if parameter.min ~= nil and not is_finite(parameter.min) then
            return false, id .. ": parameter '" .. name .. "' min must be finite"
        end
        if parameter.max ~= nil and not is_finite(parameter.max) then
            return false, id .. ": parameter '" .. name .. "' max must be finite"
        end
        if parameter.type == "int" then
            if parameter.min ~= nil and parameter.min % 1 ~= 0 then
                return false, id .. ": integer parameter '" .. name .. "' min must be an integer"
            end
            if parameter.max ~= nil and parameter.max % 1 ~= 0 then
                return false, id .. ": integer parameter '" .. name .. "' max must be an integer"
            end
        end
        if is_finite(parameter.min) and is_finite(parameter.max) and parameter.min > parameter.max then
            return false, id .. ": parameter '" .. name .. "' min exceeds max"
        end
    end
    if definition.intensity ~= nil and not is_finite(definition.intensity) then
        return false, id .. ": intensity must be finite"
    end
    return true
end

local function load_definition(id)
    if definitions[id] then return definitions[id] end
    local pack, name = split_id(id)
    if not pack then return nil, "screen effect ID must use a namespace, e.g. mypack:thermal_vision" end
    local path = pack .. ":screen-effects/" .. name .. ".screenfx.json"
    local ok, definition = pcall(function()
        return json.parse(file.read(path))
    end)
    if not ok or type(definition) ~= "table" then
        return nil, "cannot load " .. path .. ": " .. tostring(definition)
    end
    local valid, err = validate_definition(id, definition)
    if not valid then return nil, err end
    definitions[id] = clone(definition)
    return definitions[id]
end

local function native_api()
    if type(vc) ~= "table" or type(vc.is_client) ~= "function" then
        return nil, "screen effects are available only in a client HUD"
    end
    local ok, client = pcall(vc.is_client)
    if not ok or not client then return nil, "screen effects are available only in a client HUD" end
    if type(gfx) ~= "table" or type(gfx.posteffects) ~= "table" then
        return nil, "VoxelCore gfx.posteffects API is not available yet; call this after the HUD opens"
    end
    return gfx.posteffects
end

local function safe_native(method, ...)
    local ok, result, detail = pcall(method, ...)
    if not ok then return false, tostring(result) end
    return true, result, detail
end

local function slot_for(native, slot_id)
    local ok, index = safe_native(native.index, slot_id)
    if not ok then return nil, index end
    if type(index) ~= "number" or index < 0 then
        return nil, "post-effect slot '" .. slot_id .. "' is not declared in this content pack's resources.json"
    end
    return index
end

local function public_values(definition, values)
    local output = {}
    for name, value in pairs(values or {}) do
        local parameter = (definition.parameters or {})[name]
        if not parameter then return nil, "unknown screen effect parameter '" .. tostring(name) .. "'" end
        if parameter.type == "array" then
            return nil, "array parameter '" .. name .. "' must be set with handle:set_array()"
        end
        local normalized, err = normalize_value(parameter, value)
        if err then return nil, "parameter '" .. name .. "': " .. err end
        output[parameter.uniform] = normalized
    end
    return output
end

local function pack_array_values(parameter, values)
    if type(values) ~= "table" then return nil, "typed array data must be a table" end
    for key in pairs(values) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > parameter.capacity then
            return nil, "array entries must use integer indices from 1 to capacity"
        end
    end

    local format = parameter.element_type == "int" and "=i" or "=f"
    local dimensions = PARAM_TYPES[parameter.element_type]
    local buffer = Bytearray(0)
    for index = 1, parameter.capacity do
        local value = values[index]
        local packed
        if dimensions == 0 then
            if value == nil then value = 0 end
            if not is_finite(value) then return nil, "array element " .. index .. " must be finite" end
            if parameter.element_type == "int" and value % 1 ~= 0 then
                return nil, "array element " .. index .. " must be an integer"
            end
            if parameter.element_type == "int" and (value < -2147483648 or value > 2147483647) then
                return nil, "array element " .. index .. " is outside the 32-bit integer range"
            end
            if parameter.element_type ~= "int" and math.abs(value) > MAX_FLOAT32 then
                return nil, "array element " .. index .. " is outside the finite 32-bit float range"
            end
            packed = byteutil.pack(format, value)
        else
            if value == nil then value = {} end
            if type(value) ~= "table" then
                return nil, "array element " .. index .. " must contain " .. dimensions .. " numbers"
            end
            for key in pairs(value) do
                if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > dimensions then
                    return nil, "array element " .. index .. " must use component indices 1 through " .. dimensions
                end
            end
            local components = {}
            for component = 1, dimensions do
                local current = value[component]
                if current == nil then current = 0 end
                if not is_finite(current) then
                    return nil, "array element " .. index .. " component " .. component .. " must be finite"
                end
                if math.abs(current) > MAX_FLOAT32 then
                    return nil, "array element " .. index .. " component " .. component
                        .. " is outside the finite 32-bit float range"
                end
                components[component] = current
            end
            if dimensions == 2 then packed = byteutil.pack("=ff", components[1], components[2])
            elseif dimensions == 3 then packed = byteutil.pack("=fff", components[1], components[2], components[3])
            else packed = byteutil.pack("=ffff", components[1], components[2], components[3], components[4]) end
        end
        Bytearray.append(buffer, packed)
    end
    return Bytearray_as_string(buffer)
end

local function normalize_array(parameter, value)
    local snapshot = value
    if type(value) == "table" then
        local expected = parameter.capacity * ARRAY_BYTES[parameter.element_type]
        local is_byte_table = #value == expected
        if is_byte_table then
            local byte_count = 0
            for key, byte in pairs(value) do
                if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > expected
                    or not is_finite(byte) or byte % 1 ~= 0 or byte < 0 or byte > 255 then
                    is_byte_table = false
                    break
                end
                byte_count = byte_count + 1
            end
            if byte_count ~= expected then is_byte_table = false end
        end
        if is_byte_table then
            if type(Bytearray_as_string) ~= "function" then
                return nil, "Bytearray_as_string() is unavailable; pass a packed byte string instead"
            end
            local converted, result = pcall(Bytearray_as_string, value)
            if not converted or type(result) ~= "string" then
                return nil, "could not convert byte table: " .. tostring(result)
            end
            snapshot = result
        else
            local ok, packed, pack_error = pcall(pack_array_values, parameter, value)
            if not ok then return nil, "could not pack typed array: " .. tostring(packed) end
            if not packed then return nil, pack_error end
            snapshot = packed
        end
    elseif type(value) ~= "string" then
        if type(Bytearray_as_string) ~= "function" then
            return nil, "Bytearray_as_string() is unavailable; pass a packed byte string instead"
        end
        local converted, result = pcall(Bytearray_as_string, value)
        if not converted or type(result) ~= "string" then
            return nil, "array data must be a Bytearray, typed table, or packed byte string"
        end
        snapshot = result
    end

    local expected = parameter.capacity * ARRAY_BYTES[parameter.element_type]
    if #snapshot ~= expected then
        return nil, "expected " .. expected .. " bytes for capacity " .. parameter.capacity
            .. " of " .. parameter.element_type .. ", got " .. #snapshot
    end
    return snapshot
end

local function normalize_arrays(definition, values)
    if values == nil then values = {} end
    if type(values) ~= "table" then return nil, "options.arrays must be an object" end
    for name in pairs(values) do
        local parameter = (definition.parameters or {})[name]
        if not parameter or parameter.type ~= "array" then
            return nil, "unknown array parameter '" .. tostring(name) .. "'"
        end
    end

    local result = {}
    for name, parameter in pairs(definition.parameters or {}) do
        if parameter.type == "array" then
            if values[name] == nil then
                return nil, "array parameter '" .. name .. "' must be initialized before play"
            end
            local normalized, err = normalize_array(parameter, values[name])
            if not normalized then return nil, "array parameter '" .. name .. "': " .. err end
            result[name] = normalized
        end
    end
    return result
end

local function configure_native(native, slot, definition, uniforms, arrays, intensity)
    local ok, err = safe_native(native.set_effect, slot, definition.effect)
    if not ok then return false, "cannot assign shader effect: " .. err end
    ok, err = safe_native(native.set_intensity, slot, 0)
    if not ok then return false, "cannot mute shader slot: " .. err end
    if next(uniforms) then
        ok, err = safe_native(native.set_params, slot, uniforms)
        if not ok then return false, "cannot set shader parameters: " .. err end
    end
    for name, bytes in pairs(arrays) do
        local parameter = definition.parameters[name]
        ok, err = safe_native(native.set_array, slot, parameter.uniform, bytes)
        if not ok then return false, "cannot set array '" .. name .. "': " .. err end
    end
    ok, err = safe_native(native.set_intensity, slot, intensity)
    if not ok then return false, "cannot set shader intensity: " .. err end
    return true
end

local function restore_handle(native, handle)
    local uniforms = {}
    for name, value in pairs(handle.values) do
        local parameter = handle.definition.parameters[name]
        if parameter and parameter.type ~= "array" then
            uniforms[parameter.uniform] = clone(value)
        end
    end
    local ok, err = configure_native(
        native, handle.slot, handle.definition, uniforms, handle.arrays, handle.intensity
    )
    if not ok then handle.error = err else handle.error = nil end
    return ok, err
end

local function defaults(definition)
    local output = {}
    for name, parameter in pairs(definition.parameters or {}) do
        if parameter.default ~= nil and parameter.type ~= "array" then
            local normalized = normalize_value(parameter, parameter.default)
            output[parameter.uniform] = normalized
        end
    end
    return output
end

local function set_uniforms(handle, values)
    local native = native_api()
    if not native then return false, "client post-effect API is unavailable" end
    local ok, err = safe_native(native.set_params, handle.slot, values)
    if not ok then handle.error = err; return false, err end
    handle.error = nil
    return true
end

local function apply_all_parameters(handle, values)
    local normalized, err = public_values(handle.definition, values)
    if not normalized then return false, err end
    if next(normalized) then
        local ok, set_error = set_uniforms(handle, normalized)
        if not ok then return false, set_error end
    end
    for name, value in pairs(values or {}) do
        local parameter = handle.definition.parameters[name]
        handle.values[name] = clone(normalize_value(parameter, value))
        handle.parameter_tweens[name] = nil
    end
    return true
end

local function clamp_intensity(value)
    if not is_finite(value) then return nil, "intensity must be finite" end
    return math.max(0, math.min(1, value))
end

local function ease_value(t, easing)
    if easing == "smooth" or easing == "smoothstep" then return t * t * (3 - 2 * t) end
    if easing == "in" then return t * t end
    if easing == "out" then return 1 - (1 - t) * (1 - t) end
    if easing == "in_out" then
        if t < 0.5 then return 2 * t * t end
        return 1 - ((-2 * t + 2) ^ 2) / 2
    end
    return t
end

local function interpolate(from, to, t)
    if type(from) == "number" then return from + (to - from) * t end
    local result = {}
    for index = 1, #from do result[index] = from[index] + (to[index] - from[index]) * t end
    return result
end

local function begin_tween(from, to, duration, easing)
    if not is_finite(duration) or duration < 0 then return nil, "duration must be a finite non-negative number" end
    easing = easing or "linear"
    if not EASINGS[easing] then return nil, "unsupported easing '" .. tostring(easing) .. "'" end
    return {from = clone(from), to = clone(to), duration = duration, elapsed = 0, easing = easing}
end

local function advance_tween(tween, delta)
    if tween.duration <= 0 then return clone(tween.to), true end
    tween.elapsed = math.min(tween.duration, tween.elapsed + delta)
    local amount = ease_value(tween.elapsed / tween.duration, tween.easing)
    return interpolate(tween.from, tween.to, amount), tween.elapsed >= tween.duration
end

function API.validate(id, definition)
    return validate_definition(id, definition)
end

function API.register(id, definition)
    local ok, err = validate_definition(id, definition)
    if not ok then return false, err end
    definitions[id] = clone(definition)
    return true
end

function API.get_definition(id)
    local definition, err = load_definition(id)
    if not definition then return nil, err end
    return clone(definition)
end

function API.pack_array(id, name, values)
    local definition, err = load_definition(id)
    if not definition then return nil, err end
    local parameter = (definition.parameters or {})[name]
    if not parameter or parameter.type ~= "array" then
        return nil, "unknown array parameter '" .. tostring(name) .. "'"
    end
    return normalize_array(parameter, values)
end

function API.clear_definition_cache(id)
    if id ~= nil then definitions[id] = nil else definitions = {} end
    return true
end

function API.last_error()
    return last_update_error
end

function API.clear_error()
    last_update_error = nil
    for _, handle in pairs(handles) do handle.error = nil end
    return true
end

function API._record_update_error(err)
    last_update_error = tostring(err)
end

function API.play(id, options)
    options = options or {}
    if type(options) ~= "table" then return nil, "options must be an object" end
    if options.replace ~= nil and type(options.replace) ~= "boolean" then
        return nil, "replace must be boolean"
    end
    local definition, load_error = load_definition(id)
    if not definition then return nil, load_error end
    local native, native_error = native_api()
    if not native then return nil, native_error end
    local slot, slot_error = slot_for(native, definition.slot)
    if not slot then return nil, id .. ": " .. slot_error end

    local input_parameters = options.parameters == nil and {} or options.parameters
    if type(input_parameters) ~= "table" then return nil, "options.parameters must be an object" end
    local supplied_uniforms, parameter_error = public_values(definition, input_parameters)
    if not supplied_uniforms then return nil, id .. ": " .. parameter_error end
    local initial_arrays, arrays_error = normalize_arrays(definition, options.arrays)
    if not initial_arrays then return nil, id .. ": " .. arrays_error end
    local requested_intensity = options.intensity
    if requested_intensity == nil then requested_intensity = definition.intensity end
    if requested_intensity == nil then requested_intensity = 1 end
    local intensity, intensity_error = clamp_intensity(requested_intensity)
    if not intensity then return nil, id .. ": " .. intensity_error end
    local fade_in = options.fade_in == nil and 0 or options.fade_in
    if not is_finite(fade_in) or fade_in < 0 then return nil, id .. ": fade_in must be non-negative" end
    if fade_in > 0 and intensity <= ACTIVE_INTENSITY_THRESHOLD then
        return nil, id .. ": fade_in target must exceed VoxelCore's active intensity threshold"
    end
    local should_fade = fade_in > 0
    local intensity_tween
    if should_fade then
        local tween_error
        intensity_tween, tween_error = begin_tween(0, intensity, fade_in, options.easing or "smooth")
        if not intensity_tween then return nil, id .. ": " .. tween_error end
    end

    local previous = slot_owners[slot]
    local asset_owner = effect_owners[definition.effect]
    if asset_owner and asset_owner ~= previous and asset_owner.state ~= "destroyed" then
        return nil, "post-effect asset '" .. definition.effect .. "' is already used by "
            .. asset_owner.effect_id .. "; VoxelCore shares mutable state for one asset ID"
    end
    if previous and previous.state ~= "destroyed" then
        if not options.replace then
            return nil, "post-effect slot '" .. definition.slot .. "' is already owned by " .. previous.effect_id
        end
    elseif not options.replace then
        local active_ok, active = safe_native(native.is_active, slot)
        if active_ok and active then
            return nil, "post-effect slot '" .. definition.slot .. "' is active outside WispLib; pass replace=true to take it over"
        end
    end

    local initial = defaults(definition)
    for uniform, value in pairs(supplied_uniforms) do initial[uniform] = value end
    local configured, configure_error = configure_native(native, slot, definition, initial, initial_arrays,
        should_fade and 0 or intensity)
    if not configured then
        if previous and previous.state ~= "destroyed" then
            restore_handle(native, previous)
        else
            safe_native(native.set_intensity, slot, 0)
        end
        return nil, id .. ": " .. configure_error
    end

    local handle = setmetatable({
        id = next_id,
        effect_id = id,
        definition = definition,
        slot = slot,
        slot_id = definition.slot,
        state = intensity > ACTIVE_INTENSITY_THRESHOLD and "running" or "stopped",
        intensity = should_fade and 0 or intensity,
        target_intensity = intensity,
        resume_intensity = intensity,
        values = {},
        initial_parameters = clone(input_parameters),
        arrays = initial_arrays,
        parameter_tweens = {},
        intensity_tween = intensity_tween,
        stop_after_fade = false,
        error = nil,
    }, Handle)
    next_id = next_id + 1

    if previous and previous.state ~= "destroyed" then release_handle(previous) end

    for name, parameter in pairs(definition.parameters or {}) do
        if parameter.default ~= nil and parameter.type ~= "array" then
            local normalized = normalize_value(parameter, parameter.default)
            handle.values[name] = clone(normalized)
        end
    end
    for name, value in pairs(input_parameters) do
        handle.values[name] = clone(normalize_value(definition.parameters[name], value))
    end

    handles[handle.id] = handle
    slot_owners[slot] = handle
    effect_owners[definition.effect] = handle
    return handle
end

function API.get(id)
    return handles[id]
end

function API.list()
    local result = {}
    for _, handle in pairs(handles) do
        result[#result + 1] = {
            id = handle.id, effect = handle.effect_id, slot = handle.slot_id,
            state = handle.state, intensity = handle.intensity,
        }
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

function API._update(delta)
    if not is_finite(delta) then return end
    delta = math.max(0, math.min(0.1, delta))
    local native = native_api()
    if not native then return end

    for _, handle in pairs(handles) do
        if handle.state == "running" or handle.state == "stopping" then
            if handle.intensity_tween then
                local value, finished = advance_tween(handle.intensity_tween, delta)
                handle.intensity = value
                local ok, err = safe_native(native.set_intensity, handle.slot, value)
                if ok then handle.error = nil else handle.error = err end
                if finished then
                    handle.intensity_tween = nil
                    if handle.stop_after_fade or handle.intensity <= ACTIVE_INTENSITY_THRESHOLD then
                        handle.state = "stopped"
                        handle.stop_after_fade = false
                    end
                end
            end
            local changed = {}
            for name, tween in pairs(handle.parameter_tweens) do
                local parameter = handle.definition.parameters[name]
                if parameter then
                    local value, finished = advance_tween(tween, delta)
                    if parameter.type == "int" then value = math.floor(value + 0.5) end
                    handle.values[name] = clone(value)
                    changed[parameter.uniform] = value
                    if finished then handle.parameter_tweens[name] = nil end
                else
                    handle.parameter_tweens[name] = nil
                end
            end
            if next(changed) then
                local ok, err = safe_native(native.set_params, handle.slot, changed)
                if ok then handle.error = nil else handle.error = err end
            end
        end
    end
end

function API.stop_all()
    local pending = {}
    for _, handle in pairs(handles) do pending[#pending + 1] = handle end
    for _, handle in ipairs(pending) do handle:destroy() end
end

function API.stats()
    local native = native_api()
    local result = {handles = 0, active = 0, engine_active = 0, tweens = 0,
        errors = 0, last_update_error = last_update_error}
    for _, handle in pairs(handles) do
        result.handles = result.handles + 1
        if handle.intensity > ACTIVE_INTENSITY_THRESHOLD then result.active = result.active + 1 end
        if native then
            local ok, active = safe_native(native.is_active, handle.slot)
            if ok and active then result.engine_active = result.engine_active + 1 end
        end
        if handle.error then result.errors = result.errors + 1 end
        if handle.intensity_tween then result.tweens = result.tweens + 1 end
        for _ in pairs(handle.parameter_tweens) do result.tweens = result.tweens + 1 end
    end
    return result
end

function Handle:exists()
    return self.state ~= "destroyed" and handles[self.id] == self
end

function Handle:status()
    return self.state
end

function Handle:last_error()
    return self.error
end

function Handle:is_active()
    if not self:exists() then return false, "screen effect handle was destroyed" end
    local native, native_error = native_api()
    if not native then return nil, native_error end
    local ok, active = safe_native(native.is_active, self.slot)
    if not ok then self.error = active; return nil, active end
    return active
end

function Handle:observed_intensity()
    if not self:exists() then return nil, "screen effect handle was destroyed" end
    local native, native_error = native_api()
    if not native then return nil, native_error end
    local ok, intensity = safe_native(native.get_intensity, self.slot)
    if not ok then self.error = intensity; return nil, intensity end
    return intensity
end

function Handle:get_intensity()
    return self.intensity
end

function Handle:set_intensity(value)
    if not self:exists() then return false, "screen effect handle was destroyed" end
    local intensity, err = clamp_intensity(value)
    if intensity == nil then return false, err end
    local native, native_error = native_api()
    if not native then return false, native_error end
    local ok, set_error = safe_native(native.set_intensity, self.slot, intensity)
    if not ok then self.error = set_error; return false, set_error end
    local previous_intensity = self.intensity
    self.intensity = intensity
    self.target_intensity = intensity
    self.resume_intensity = intensity > ACTIVE_INTENSITY_THRESHOLD and intensity or previous_intensity
    self.intensity_tween = nil
    self.stop_after_fade = false
    self.state = intensity > ACTIVE_INTENSITY_THRESHOLD and "running" or "stopped"
    self.error = nil
    return true
end

function Handle:fade_to(value, duration, easing)
    if not self:exists() then return false, "screen effect handle was destroyed" end
    local intensity, err = clamp_intensity(value)
    if intensity == nil then return false, err end
    if duration == 0 then return self:set_intensity(intensity) end
    local tween, tween_error = begin_tween(self.intensity, intensity, duration, easing)
    if not tween then return false, tween_error end
    self.target_intensity = intensity
    self.intensity_tween = tween
    self.stop_after_fade = intensity <= ACTIVE_INTENSITY_THRESHOLD
    self.state = self.stop_after_fade and "stopping" or "running"
    return true
end

function Handle:stop(duration, easing)
    if not self:exists() then return false, "screen effect handle was destroyed" end
    if duration == nil then duration = 0 end
    if not is_finite(duration) or duration < 0 then
        return false, "duration must be a finite non-negative number"
    end
    self.resume_intensity = self.target_intensity > ACTIVE_INTENSITY_THRESHOLD
        and self.target_intensity or self.intensity
    if duration == 0 then
        local resume_intensity = self.resume_intensity
        local ok, err = self:set_intensity(0)
        self.resume_intensity = resume_intensity
        return ok, err
    end
    local tween, err = begin_tween(self.intensity, 0, duration, easing or "smooth")
    if not tween then return false, err end
    self.intensity_tween = tween
    self.target_intensity = 0
    self.stop_after_fade = true
    self.state = "stopping"
    return true
end

function Handle:resume(duration, easing)
    if not self:exists() then return false, "screen effect handle was destroyed" end
    return self:fade_to(self.resume_intensity, duration or 0, easing or "smooth")
end

function Handle:set(name, value)
    if not self:exists() then return false, "screen effect handle was destroyed" end
    local parameter = (self.definition.parameters or {})[name]
    if not parameter then return false, "unknown screen effect parameter '" .. tostring(name) .. "'" end
    if parameter.type == "array" then return false, "use set_array() for array parameters" end
    local normalized, err = normalize_value(parameter, value)
    if err then return false, "parameter '" .. name .. "': " .. err end
    local ok, set_error = set_uniforms(self, {[parameter.uniform] = normalized})
    if not ok then return false, set_error end
    self.error = nil
    self.values[name] = clone(normalized)
    self.parameter_tweens[name] = nil
    return true
end

function Handle:set_params(values)
    if not self:exists() then return false, "screen effect handle was destroyed" end
    if type(values) ~= "table" then return false, "parameters must be an object" end
    local ok, err = apply_all_parameters(self, values)
    if ok then self.error = nil end
    return ok, err
end

function Handle:get(name)
    if not self:exists() then return nil, "screen effect handle was destroyed" end
    local parameter = (self.definition.parameters or {})[name]
    if not parameter then return nil, "unknown screen effect parameter '" .. tostring(name) .. "'" end
    if parameter.type == "array" then return self.arrays[name] end
    return clone(self.values[name])
end

function Handle:tween(name, value, duration, easing)
    if not self:exists() then return false, "screen effect handle was destroyed" end
    local parameter = (self.definition.parameters or {})[name]
    if not parameter or parameter.type == "array" then
        return false, "parameter '" .. tostring(name) .. "' is not an animatable scalar/vector"
    end
    local target, err = normalize_value(parameter, value)
    if err then return false, "parameter '" .. name .. "': " .. err end
    local source = self.values[name]
    if source == nil then return false, "parameter '" .. name .. "' needs a default or an initial value before tweening" end
    if duration == 0 then return self:set(name, target) end
    local tween, tween_error = begin_tween(source, target, duration, easing)
    if not tween then return false, tween_error end
    self.parameter_tweens[name] = tween
    return true
end

function Handle:set_array(name, bytes)
    if not self:exists() then return false, "screen effect handle was destroyed" end
    local parameter = (self.definition.parameters or {})[name]
    if not parameter or parameter.type ~= "array" then
        return false, "parameter '" .. tostring(name) .. "' is not declared as an array"
    end
    local snapshot, snapshot_error = normalize_array(parameter, bytes)
    if not snapshot then return false, "array parameter '" .. name .. "': " .. snapshot_error end
    local native, native_error = native_api()
    if not native then return false, native_error end
    local ok, err = safe_native(native.set_array, self.slot, parameter.uniform, snapshot)
    if not ok then self.error = err; return false, err end
    self.arrays[name] = snapshot
    self.error = nil
    return true
end

function Handle:restart(options)
    if not self:exists() then return false, "screen effect handle was destroyed" end
    options = options or {}
    if type(options) ~= "table" then return false, "restart options must be an object" end
    local native, native_error = native_api()
    if not native then return false, native_error end
    local input = options.parameters == nil and self.initial_parameters or options.parameters
    if type(input) ~= "table" then return false, "restart parameters must be an object" end
    local initial, initial_error = public_values(self.definition, input)
    if not initial then return false, initial_error end
    local next_arrays = self.arrays
    if options.arrays ~= nil then
        local arrays_error
        next_arrays, arrays_error = normalize_arrays(self.definition, options.arrays)
        if not next_arrays then return false, arrays_error end
    end
    local target = options.intensity
    if target == nil then target = self.definition.intensity end
    if target == nil then target = 1 end
    local intensity, intensity_error = clamp_intensity(target)
    if intensity == nil then return false, intensity_error end
    local fade = options.fade_in == nil and 0 or options.fade_in
    if not is_finite(fade) or fade < 0 then return false, "fade_in must be non-negative" end
    if fade > 0 and intensity <= ACTIVE_INTENSITY_THRESHOLD then
        return false, "fade_in target must exceed VoxelCore's active intensity threshold"
    end
    local should_fade = fade > 0
    local intensity_tween
    if should_fade then
        local tween_error
        intensity_tween, tween_error = begin_tween(0, intensity, fade, options.easing or "smooth")
        if not intensity_tween then return false, tween_error end
    end
    local next_initial_parameters = options.parameters ~= nil
        and clone(options.parameters) or self.initial_parameters
    local base = defaults(self.definition)
    for uniform, value in pairs(initial) do base[uniform] = value end
    local next_values = {}
    for name, parameter in pairs(self.definition.parameters or {}) do
        if parameter.default ~= nil and parameter.type ~= "array" then
            next_values[name] = clone(normalize_value(parameter, parameter.default))
        end
    end
    for name, value in pairs(input or {}) do
        next_values[name] = clone(normalize_value(self.definition.parameters[name], value))
    end
    local next_intensity = should_fade and 0 or intensity
    local configured, configure_error = configure_native(
        native, self.slot, self.definition, base, next_arrays, next_intensity
    )
    if not configured then
        restore_handle(native, self)
        self.error = configure_error
        return false, configure_error
    end

    self.values = next_values
    self.parameter_tweens = {}
    self.target_intensity = intensity
    self.resume_intensity = intensity
    self.intensity = next_intensity
    self.state = intensity > ACTIVE_INTENSITY_THRESHOLD and "running" or "stopped"
    self.stop_after_fade = false
    self.intensity_tween = intensity_tween
    self.initial_parameters = clone(next_initial_parameters)
    self.arrays = next_arrays
    self.error = nil
    return true
end

function Handle:destroy()
    if not self:exists() then return false end
    local native = native_api()
    if native then safe_native(native.set_intensity, self.slot, 0) end
    release_handle(self)
    return true
end

return API
