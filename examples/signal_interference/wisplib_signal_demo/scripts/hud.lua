local vfx = require "wisplib:vfx"

local profile_id = "wisplib_signal_demo:radio"
local handle
local player_id
local motion = 0
local jump_pulse = 0
local previous_y_speed = 0
local send_timer = 0
local profile_ready = false
local update_warning = false

-- Keep the profile beside its Lua controller so the example needs no extra JSON file.
local registered, register_error = vfx.screen.register(profile_id, {
    schema = 1,
    slot = "wisplib_signal_demo:radio",
    effect = "wisplib_signal_demo_radio",
    intensity = 0.9,
    parameters = {
        noise = {uniform = "p_noise", type = "float", default = 0.028, min = 0, max = 0.08},
        tearing = {uniform = "p_tearing", type = "float", default = 0.035, min = 0, max = 0.07},
        vignette = {uniform = "p_vignette", type = "float", default = 0.42, min = 0, max = 0.8},
        motion = {uniform = "p_motion", type = "float", default = 0, min = 0, max = 1},
        jump = {uniform = "p_jump", type = "float", default = 0, min = 0, max = 1}
    }
})

profile_ready = registered
if not registered then
    print("[wisplib_signal_demo] Profile error: " .. tostring(register_error))
end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function smooth(current, target, rate, delta)
    return current + (target - current) * (1 - math.exp(-rate * delta))
end

function on_hud_open()
    if not profile_ready then return end

    player_id = hud.get_player()
    motion, jump_pulse, send_timer = 0, 0, 0
    update_warning = false
    local _, y_speed = player.get_vel(player_id)
    previous_y_speed = y_speed or 0

    local err
    handle, err = vfx.screen.play(profile_id, {fade_in = 0.25})
    if not handle then
        print("[wisplib_signal_demo] Could not start effect: " .. tostring(err))
    end
end

function on_hud_render()
    if not handle or not handle:exists() or not player_id then return end

    local delta = clamp(time.delta() or 0, 0, 0.1)
    local vx, vy, vz = player.get_vel(player_id)
    if not vx or not vy or not vz then return end

    -- Walking adds steady noise; takeoff gives a brief stronger pulse.
    local horizontal_speed = math.sqrt(vx * vx + vz * vz)
    motion = smooth(motion, clamp((horizontal_speed - 0.1) / 2.8, 0, 1), 7, delta)

    if previous_y_speed <= 0.35 and vy > 1 then
        jump_pulse = 1
    end
    previous_y_speed = vy
    jump_pulse = math.max(0, jump_pulse * math.exp(-delta * 3.5))

    -- Updating uniforms 30 times per second is enough; GLSL still renders each frame.
    send_timer = send_timer + delta
    if send_timer >= 1 / 30 then
        send_timer = 0
        local ok, err = handle:set_params({motion = motion, jump = jump_pulse})
        if not ok and not update_warning then
            print("[wisplib_signal_demo] Parameter update failed: " .. tostring(err))
            update_warning = true
        end
    end
end

function on_hud_close()
    if handle then
        handle:destroy()
        handle = nil
    end
    player_id = nil
end
