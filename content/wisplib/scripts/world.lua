local vfx = require "wisplib:vfx"

function on_world_open()
    -- The Lua VM can outlive a world. Never carry its records into the next one.
    vfx.stop_transient_all()
    vfx.world.close()
    local ok, errors = vfx.world.load()
    if not ok then
        print("[wisplib] Could not load saved WorldEffects: " .. tostring(errors))
        return
    end
    for _, err in ipairs(errors or {}) do print("[wisplib] WorldEffect skipped: " .. tostring(err)) end
end

function on_world_tick()
    -- Clients update at render cadence from hud.lua; headless/server has no HUD.
    if not vc.is_client() then vfx.update() end
end

function on_world_save()
    local ok, err = vfx.world.save()
    if not ok then print("[wisplib] Could not save WorldEffects: " .. tostring(err)) end
end

function on_world_quit()
    local ok, err = vfx.world.save()
    if not ok then print("[wisplib] Could not save WorldEffects on quit: " .. tostring(err)) end
    vfx.stop_transient_all()
    vfx.world.close()
end
