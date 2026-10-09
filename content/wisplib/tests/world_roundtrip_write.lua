-- First process of the persistent WorldEffect integration test.
app.reconfig_packs({"base", "wisplib"}, {})
app.new_world("wisplib-persistent-process-test", "791204", "core:default")
assert(world.is_open())
local vfx = require "wisplib:vfx"
assert(vfx.register("wisplib_roundtrip:effect", {schema = 1, motion = "controlled", emitters = {{
    backend = "entity", particle = "wisplib:controlled_particle", motion = "controlled",
    spawn = {mode = "burst", count = 2}, lifetime = 30,
    controller = {type = "points", space = "local", points = {{0, 0, 0}, {1, 0, 0}}},
}}}))
assert(vfx.world.clear())
local fx = assert(vfx.world.create("wisplib_roundtrip:effect", {
    name = "saved_between_processes", position = {24, 50, 12},
    enabled = true, autostart = false, tags = {"roundtrip"},
}))
assert(fx.id == "world_fx_1")
assert(vfx.world.save())
print("WISPLIB_WORLD_WRITE_OK")
app.close_world(true)
