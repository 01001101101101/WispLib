-- Client lifecycle and frame update for the WispLib runtime.
local vfx = require "wisplib:vfx"

function on_hud_open()
    local errors = vfx.world.start_pending_client()
    for _, err in ipairs(errors) do
        print("[wisplib] WorldEffect could not start: " .. tostring(err))
    end
end

function on_hud_render()
    if vc.is_client() then vfx.update() end
end
