-- Generic transform-driven 3D mesh particle container.
-- The skeleton's children are reusable slots; the effect definition chooses model,
-- shape, lifetime, motion modifiers, scale and color curves.
local transform = entity.transform
local skeleton = entity.skeleton
-- This entity only hosts the particle meshes. VoxelCore's solver still applies
-- gravity to KINEMATIC bodies, so native physics would fight the VFX transform.
entity.rigidbody:set_enabled(false)
local CAPACITY = 512
local MAX_FRAME_DELTA = 0.10
local MAX_STEP = 1.0 / 60.0
local settings = ARGS.settings or {}
local particles = {}
local active_count = 0
local live_count = 0
local running = settings.loop ~= false
local paused = false
local controlled = settings.motion == "controlled" or settings.motion == "hybrid"
local simulation_time = 0

local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = clone(item) end
    return result
end

local seed = math.floor(math.abs(tonumber(settings.seed) or 1)) % 2147483647
if seed == 0 then seed = 1 end
local function random()
    seed = (seed * 48271) % 2147483647
    return (seed - 1) / 2147483646
end

local function clamp(x, a, b) return math.max(a, math.min(b, x)) end
local function add(a, b) return {a[1] + b[1], a[2] + b[2], a[3] + b[3]} end
local function sub(a, b) return {a[1] - b[1], a[2] - b[2], a[3] - b[3]} end
local function mul(a, n) return {a[1] * n, a[2] * n, a[3] * n} end
local function length(a) return math.sqrt(a[1]^2 + a[2]^2 + a[3]^2) end
local function normalize(a)
    local d = length(a)
    if d < 0.000001 then return {0, 1, 0} end
    return mul(a, 1 / d)
end
local function random_range(value, fallback)
    if type(value) == "number" then return value end
    if type(value) == "table" and type(value[1]) == "number" and type(value[2]) == "number" then
        return value[1] + (value[2] - value[1]) * random()
    end
    return fallback or 0
end
local function as_vec3(value, fallback)
    if type(value) == "number" then return {value, value, value} end
    if type(value) == "table" and type(value[1]) == "number"
        and type(value[2]) == "number" and type(value[3]) == "number" then
        return {value[1], value[2], value[3]}
    end
    return {fallback[1], fallback[2], fallback[3]}
end
local function sample_vec3(value, fallback)
    if type(value) == "table" and value.min ~= nil and value.max ~= nil then
        local minimum, maximum = as_vec3(value.min, fallback), as_vec3(value.max, fallback)
        return {
            minimum[1] + (maximum[1] - minimum[1]) * random(),
            minimum[2] + (maximum[2] - minimum[2]) * random(),
            minimum[3] + (maximum[3] - minimum[3]) * random(),
        }
    end
    return as_vec3(value, fallback)
end
local function sample_color(value, range)
    local color
    range = range or (type(value) == "table" and value.min ~= nil and value or nil)
    if type(range) == "table" and type(range.min) == "table" and type(range.max) == "table" then
        color = {}
        for channel = 1, 4 do
            local low = tonumber(range.min[channel]) or (channel == 4 and 1 or 1)
            local high = tonumber(range.max[channel]) or low
            color[channel] = low + (high - low) * random()
        end
    else
        color = clone(value or {1, 1, 1, 1})
    end
    if type(color) ~= "table" then return {1, 1, 1, 1} end
    if #color == 3 then color[4] = 1 end
    for channel = 1, 4 do
        color[channel] = clamp(tonumber(color[channel]) or (channel == 4 and 1 or 1), 0, 1)
    end
    return color
end
local function rotation_matrix(value)
    if type(value) == "table" and #value == 16 then return clone(value) end
    local angles = sample_vec3(value, {0, 0, 0})
    local matrix = mat4.idt()
    if angles[1] ~= 0 then mat4.rotate(matrix, {1, 0, 0}, angles[1], matrix) end
    if angles[2] ~= 0 then mat4.rotate(matrix, {0, 1, 0}, angles[2], matrix) end
    if angles[3] ~= 0 then mat4.rotate(matrix, {0, 0, 1}, angles[3], matrix) end
    return matrix
end
local function choose_model()
    local variants = settings.models or settings.model_variants
    if type(variants) ~= "table" or #variants == 0 then return settings.model end
    local total = 0
    for _, variant in ipairs(variants) do
        local weight = type(variant) == "table" and tonumber(variant.weight) or 1
        total = total + math.max(0, weight or 0)
    end
    if total <= 0 then return settings.model end
    local selected = random() * total
    for _, variant in ipairs(variants) do
        local weight = type(variant) == "table" and tonumber(variant.weight) or 1
        weight = math.max(0, weight or 0)
        selected = selected - weight
        if selected <= 0 then
            if type(variant) == "string" then return variant end
            if type(variant) == "table" then return variant.model or variant.id end
        end
    end
    local last = variants[#variants]
    if type(last) == "string" then return last end
    return type(last) == "table" and (last.model or last.id) or settings.model
end
local function set_particle_model(index, particle, model)
    if type(model) ~= "string" or model == "" or particle.model == model then return end
    local ok = pcall(function() skeleton:set_model(index, model) end)
    if ok then particle.model = model end
end
local function random_direction()
    local y = random() * 2 - 1
    local a = random() * math.pi * 2
    local r = math.sqrt(math.max(0, 1 - y * y))
    return {math.cos(a) * r, y, math.sin(a) * r}
end

local function sample_shape(shape, age_ratio)
    shape = shape or {type = "point"}
    local kind = shape.type or "point"
    if kind == "sphere" then
        return mul(random_direction(), random_range(shape.radius, 1) * math.pow(random(), 1 / 3))
    elseif kind == "box" then
        local size = shape.size or {1, 1, 1}
        return {(random() - 0.5) * size[1], (random() - 0.5) * size[2], (random() - 0.5) * size[3]}
    elseif kind == "ring" or kind == "disk" then
        local inner, outer = shape.inner_radius or 0, shape.radius or 1
        local radius = math.sqrt(inner * inner + random() * (outer * outer - inner * inner))
        local angle = random() * math.pi * 2
        return {math.cos(angle) * radius, 0, math.sin(angle) * radius}
    elseif kind == "cone" then
        local t = age_ratio or random()
        local height = shape.height or 1
        local radius = (shape.radius or 1) * (1 - t)
        local angle = random() * math.pi * 2
        local radial = radius * math.sqrt(random())
        return {math.cos(angle) * radial, height * t, math.sin(angle) * radial}
    end
    return {0, 0, 0}
end

local function sample_velocity(value, position)
    if type(value) == "table" and value.type == "radial" then
        local direction = normalize(position or random_direction())
        direction[2] = direction[2] + (value.vertical_bias or 0)
        return mul(normalize(direction), random_range(value.speed, 1))
    elseif type(value) == "table" and value.type == "up" then
        return {random_range(value.horizontal, 0), random_range(value.speed, 1), random_range(value.depth, 0)}
    elseif type(value) == "table" and type(value[1]) == "number" then
        return {value[1], value[2], value[3]}
    end
    return {0, 0, 0}
end

local function curve_sample(curve, t, fallback)
    if type(curve) ~= "table" or #curve == 0 then return fallback end
    local left = curve[1]
    if t <= left[1] then return left[2] end
    for index = 2, #curve do
        local right = curve[index]
        if t <= right[1] then
            local span = math.max(0.000001, right[1] - left[1])
            local f = clamp((t - left[1]) / span, 0, 1)
            if type(left[2]) == "number" then
                return left[2] + (right[2] - left[2]) * f
            end
            local result = {}
            for channel = 1, #left[2] do
                result[channel] = left[2][channel] + (right[2][channel] - left[2][channel]) * f
            end
            return result
        end
        left = right
    end
    return left[2]
end

local function modifiers_of()
    return settings.modifiers or {}
end

local function plume_radius(shape, t)
    local tip = shape.tip_radius or 0
    return tip + ((shape.radius or 0.25) - tip) * math.pow(1 - clamp(t, 0, 1), shape.taper or 1.3)
end

local function seed_particle(particle, random_age, index)
    particle.lifetime = math.max(0.02, random_range(settings.lifetime, 1.0))
    particle.age = random_age and random() * particle.lifetime or 0
    local t = particle.age / particle.lifetime
    local shape = settings.shape or {type = "point"}
    if shape.type == "cone" then
        local angle = random() * math.pi * 2
        local radius = plume_radius(shape, t) * math.sqrt(random())
        particle.position = {math.cos(angle) * radius, (shape.height or 1) * t, math.sin(angle) * radius}
    else
        particle.position = sample_shape(shape)
    end
    particle.velocity = sample_velocity(settings.velocity, particle.position)
    particle.phase = random() * math.pi * 2
    particle.spin = (random() * 2 - 1) * (settings.spin or 0)
    particle.rotation_angle = 0
    particle.angular_velocity = random_range(settings.angular_velocity or 0, 0)
    particle.rotation_axis = normalize(as_vec3(settings.rotation_axis, {0, 1, 0}))
    particle.base_rotation = rotation_matrix(settings.rotation)
    local variation = math.max(0, tonumber(settings.size_variation) or 0.2)
    particle.size_scale = random_range({1 - variation, 1 + variation}, 1)
    particle.base_scale = sample_vec3(settings.size_range or settings.size, {0.06, 0.06, 0.06})
    particle.base_color = sample_color(settings.color, settings.color_range)
    particle.matrix = mat4.idt()
    particle.alive = true
    set_particle_model(index, particle, choose_model())
end

local function set_particle_pose(index, particle)
    local t = clamp(particle.age / particle.lifetime, 0, 1)
    local scale = curve_sample(settings.scale_over_life, t, 1)
    local size = clone(particle.base_scale or {0.06, 0.06, 0.06})
    if type(scale) == "number" then
        for axis = 1, 3 do size[axis] = size[axis] * scale end
    else
        local scale_vector = as_vec3(scale, {1, 1, 1})
        for axis = 1, 3 do size[axis] = size[axis] * scale_vector[axis] end
    end
    for axis = 1, 3 do size[axis] = size[axis] * particle.size_scale end
    local color = clone(curve_sample(settings.color_over_life, t, particle.base_color or settings.color or {1, 1, 1, 1}))
    if type(color) ~= "table" then color = {1, 1, 1, 1} end
    if #color == 3 then color[4] = 1 end
    local multiplier = settings.color_multiplier or {1, 1, 1}
    for channel = 1, 3 do color[channel] = clamp((color[channel] or 1) * (multiplier[channel] or 1), 0, 1) end
    local alpha = curve_sample(settings.alpha_over_life, t, settings.opacity or 1)
    color[4] = clamp((color[4] or 1) * (tonumber(alpha) or 1), 0, 1)
    local matrix = particle.matrix
    mat4.idt(matrix)
    mat4.translate(matrix, particle.position, matrix)
    if particle.base_rotation then mat4.mul(matrix, particle.base_rotation, matrix) end
    local angle = (particle.spin or 0) + (particle.rotation_angle or 0)
    if angle ~= 0 then mat4.rotate(matrix, particle.rotation_axis or {0, 1, 0}, angle, matrix) end
    mat4.scale(matrix, size, matrix)
    skeleton:set_matrix(index, matrix)
    skeleton:set_color(color, index)
end

local function set_count(value)
    local wanted = clamp(math.floor((tonumber(value) or 0) + 0.5), 0, CAPACITY)
    for index = 1, CAPACITY do
        local visible = index <= wanted
        skeleton:set_visible(index, visible)
        if visible and index > active_count then
            seed_particle(particles[index], settings.loop ~= false, index)
            live_count = live_count + 1
        elseif not visible and index <= active_count then
            if particles[index].alive then
                live_count = math.max(0, live_count - 1)
                particles[index].alive = false
            end
        end
    end
    active_count = wanted
end

for index = 1, CAPACITY do
    particles[index] = {age = 0, lifetime = 1, position = {0, 0, 0}, velocity = {0, 0, 0}, phase = 0, spin = 0, size_scale = 1, alive = false}
    skeleton:set_visible(index, false)
    skeleton:set_matrix(index, mat4.idt())
    if settings.model then skeleton:set_model(index, settings.model) end
end
skeleton:set_visible(0, false)
transform:set_pos(settings.position or transform:get_pos())
set_count(settings.count or 0)
for index = 1, active_count do set_particle_pose(index, particles[index]) end

local function update_mote(particle, dt)
    local t = clamp(particle.age / particle.lifetime, 0, 1)
    local acceleration = {0, 0, 0}
    local drag = 0
    local turbulence = 0
    local vortex = 0
    for _, modifier in ipairs(modifiers_of()) do
        if modifier.type == "gravity" then
            local force = modifier.vector or {0, -(modifier.strength or 9.8), 0}
            acceleration = add(acceleration, force)
        elseif modifier.type == "wind" then
            acceleration = add(acceleration, modifier.vector or {0, 0, 0})
        elseif modifier.type == "drag" then
            drag = drag + (modifier.strength or 0)
        elseif modifier.type == "turbulence" then
            turbulence = turbulence + (modifier.strength or 0)
        elseif modifier.type == "vortex" then
            vortex = vortex + (modifier.strength or 0)
        end
    end
    if settings.shape and settings.shape.type == "cone" then
        local strength = settings.lift or 0
        acceleration[2] = acceleration[2] + strength
    end
    local phase = particle.phase
    acceleration[1] = acceleration[1] + math.sin(simulation_time * 2.1 + phase + particle.position[2]) * turbulence
    acceleration[3] = acceleration[3] + math.cos(simulation_time * 1.8 + phase + particle.position[1]) * turbulence
    if vortex ~= 0 then
        acceleration[1] = acceleration[1] - particle.position[3] * vortex
        acceleration[3] = acceleration[3] + particle.position[1] * vortex
    end
    particle.velocity = add(particle.velocity, mul(acceleration, dt))
    if drag > 0 then particle.velocity = mul(particle.velocity, math.max(0, 1 - drag * dt)) end
    particle.position = add(particle.position, mul(particle.velocity, dt))
    particle.rotation_angle = (particle.rotation_angle or 0) + (particle.angular_velocity or 0) * dt
    particle.age = particle.age + dt
end

function on_physics_update(delta)
    if paused or controlled then return end
    local elapsed = clamp(delta, 0, MAX_FRAME_DELTA)
    if elapsed <= 0 then return end
    local steps = math.max(1, math.ceil(elapsed / MAX_STEP))
    local step = elapsed / steps
    for _ = 1, steps do
        simulation_time = simulation_time + step
        for index = 1, active_count do
            local particle = particles[index]
            if particle.age >= particle.lifetime then
                if running then
                    seed_particle(particle, false, index)
                else
                    skeleton:set_visible(index, false)
                    if particle.alive then
                        live_count = math.max(0, live_count - 1)
                        particle.alive = false
                    end
                end
            else
                update_mote(particle, step)
            end
        end
    end
    for index = 1, active_count do
        if particles[index].age < particles[index].lifetime then set_particle_pose(index, particles[index]) end
    end
end

this.set_settings = function(value)
    settings = value or {}
    controlled = settings.motion == "controlled" or settings.motion == "hybrid"
    local wanted = settings.count or active_count
    set_count(wanted)
    if settings.model then
        for index = 1, CAPACITY do
            skeleton:set_model(index, settings.model)
            particles[index].model = settings.model
        end
    end
    for index = 1, active_count do
        local particle = particles[index]
        -- Keep each slot's random sample stable across parameter updates while
        -- allowing live size/color/rotation controls to reach existing motes.
        local old_seed = seed
        seed = (math.floor(math.abs(tonumber(settings.seed) or 1)) + index * 104729) % 2147483647
        if seed == 0 then seed = 1 end
        local variation = math.max(0, tonumber(settings.size_variation) or 0.2)
        particle.size_scale = random_range({1 - variation, 1 + variation}, 1)
        particle.base_scale = sample_vec3(settings.size_range or settings.size, {0.06, 0.06, 0.06})
        particle.base_color = sample_color(settings.color, settings.color_range)
        particle.base_rotation = rotation_matrix(settings.rotation)
        particle.rotation_axis = normalize(as_vec3(settings.rotation_axis, {0, 1, 0}))
        particle.angular_velocity = random_range(settings.angular_velocity or 0, 0)
        if settings.models or settings.model_variants then
            set_particle_model(index, particle, choose_model())
        end
        seed = old_seed
        set_particle_pose(index, particle)
    end
end

this.set_controlled = function(value)
    controlled = not not value
end

local function apply_particle_pose(index, update)
    index = math.floor(tonumber(index) or 0)
    if index < 1 or index > active_count or not particles[index] then return false end
    local position, rotation = update.position, update.rotation
    if type(position) ~= "table" or #position < 3 then return false end
    local matrix = particles[index].matrix
    mat4.idt(matrix)
    mat4.translate(matrix, position, matrix)
    if type(rotation) == "table" and #rotation == 16 then
        mat4.mul(matrix, rotation, matrix)
    elseif type(rotation) == "table" and #rotation >= 3 then
        if rotation[1] ~= 0 then mat4.rotate(matrix, {1, 0, 0}, rotation[1], matrix) end
        if rotation[2] ~= 0 then mat4.rotate(matrix, {0, 1, 0}, rotation[2], matrix) end
        if rotation[3] ~= 0 then mat4.rotate(matrix, {0, 0, 1}, rotation[3], matrix) end
    end
    local size = update.scale or particles[index].base_scale or as_vec3(settings.size, {0.06, 0.06, 0.06})
    if type(size) == "number" then size = {size, size, size} end
    mat4.scale(matrix, size, matrix)
    skeleton:set_matrix(index, matrix)
    if type(update.color) == "table" then
        local color = {update.color[1] or 1, update.color[2] or 1, update.color[3] or 1, update.color[4] or 1}
        for channel = 1, 4 do color[channel] = clamp(tonumber(color[channel]) or 1, 0, 1) end
        skeleton:set_color(color, index)
    end
    set_particle_model(index, particles[index], update.model)
    skeleton:set_visible(index, true)
    return true
end

this.set_particle_pose = function(index, position, rotation, scale, color, model)
    return apply_particle_pose(index, {
        position = position, rotation = rotation, scale = scale, color = color, model = model,
    })
end

this.set_particle_poses = function(updates)
    if type(updates) ~= "table" then return false end
    local applied = 0
    for _, update in ipairs(updates) do
        if type(update) == "table" and apply_particle_pose(update.index, update) then
            applied = applied + 1
        end
    end
    return applied
end

this.get_particle_scale = function(index)
    index = math.floor(tonumber(index) or 0)
    local particle = particles[index]
    if not particle or index > active_count then return nil end
    local scale = particle.base_scale or {0.06, 0.06, 0.06}
    local factor = particle.size_scale or 1
    return {scale[1] * factor, scale[2] * factor, scale[3] * factor}
end

this.get_particle_color = function(index)
    index = math.floor(tonumber(index) or 0)
    local particle = particles[index]
    return particle and index <= active_count and clone(particle.base_color) or nil
end

this.get_particle_lifetime = function(index)
    index = math.floor(tonumber(index) or 0)
    local particle = particles[index]
    return particle and index <= active_count and particle.lifetime or nil
end

this.set_origin = function(value)
    settings.position = value
    transform:set_pos(value)
end

this.stop = function()
    running = false
    -- Existing controlled slots become ordinary local simulation slots so a
    -- stopped effect can drain and eventually report is_finished().
    controlled = false
end

this.pause = function(value)
    paused = not not value
end

this.is_finished = function()
    return not running and live_count == 0
end

this.get_count = function()
    return live_count
end
