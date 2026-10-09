-- Second process; run with the same VoxelCore_AI --profile as the writer.
app.reconfig_packs({"base", "wisplib"}, {})
app.open_world("wisplib-persistent-process-test")
assert(world.is_open())
local vfx = require "wisplib:vfx"
assert(vfx.register("wisplib_roundtrip:effect", {schema = 1, motion = "controlled", emitters = {{
    backend = "entity", particle = "wisplib:controlled_particle", motion = "controlled",
    spawn = {mode = "burst", count = 2}, lifetime = 30,
    controller = {type = "points", space = "local", points = {{0, 0, 0}, {1, 0, 0}}},
}}}))
local loaded, errors = vfx.world.load()
assert(loaded and #errors == 0)
local fx = assert(vfx.world.get_by_name("saved_between_processes"))
assert(fx.id == "world_fx_1")
assert(fx:get("position")[1] == 24)
assert(fx:get("runtime_state") == "stopped", "autostart=false must remain stopped")
assert(#vfx.world.find_by_tag("roundtrip") == 1)
assert(fx:start())
app.tick()
assert(vfx.stats().entities == 2)
assert(fx:stop())
print("WISPLIB_WORLD_READ_OK")
app.close_world(true)
