extends SceneTree
## Standalone native host contract check: godot --headless --path . -s this_script.


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	world.place_block(Vector3i(0, 0, 0), VoxelWorldData.Block.MINER)
	world.place_block(Vector3i(1, 0, 0), VoxelWorldData.Block.BELT)
	world.place_block(Vector3i(2, 0, 0), VoxelWorldData.Block.BELT_UP_EAST)
	world.place_block(Vector3i(3, 1, 0), VoxelWorldData.Block.BELT)
	world.place_block(Vector3i(4, 1, 0), VoxelWorldData.Block.CHEST)
	var data: LogisticsData = LogisticsData.new()
	data.bind_world(world, 0.1, 1)
	for cell: Vector3i in data.machine_cells():
		data.set_direction(cell, Vector3i.RIGHT)
	if not data.has_method("enable_rust_transport"):
		printerr("Missing native LogisticsData backend")
		quit(1)
		return
	assert(data.call("enable_rust_transport"))
	assert(data.call("transport_backend") == "rust")
	data.advance(0.7)
	var rows: Array[LogisticsOreQueue] = data.sample_cells([Vector3i(2, 0, 0)])
	assert(rows.size() == 1 and rows[0].ores.size() == 1)
	var ore: LogisticsOre = rows[0].ores[0]
	assert(absf(ore.progress - 0.1 / sqrt(0.5)) < 0.0000001)
	var identity: int = ore.id
	var before: Dictionary = data.save_packed_state()
	assert(before.get("backend") == "rust")
	var restored: LogisticsData = LogisticsData.new()
	restored.bind_world(world)
	assert(restored.restore_state(before))
	assert(restored.call("transport_backend") == "rust")
	assert(restored.sample_cells([Vector3i(2, 0, 0)])[0].ores[0].id == identity)
	var corrupt: Dictionary = before.duplicate(true)
	var bytes: PackedByteArray = corrupt["native"]
	corrupt["native"] = bytes.slice(0, bytes.size() - 1)
	assert(not restored.restore_state(corrupt))
	assert(restored.save_packed_state() == before)
	data.advance(2.0)
	restored.advance(2.0)
	assert(data.save_packed_state() == restored.save_packed_state())
	assert(data.ore_count(Vector3i(4, 1, 0)) > 0)
	var total: int = data.total_ore()
	var sampled: Array[LogisticsOre] = data.belt_ores(Vector3i(2, 0, 0), 10.0)
	sampled.clear()
	assert(data.total_ore() == total)
	assert(data.set_direction(Vector3i(1, 0, 0), Vector3i.FORWARD))
	data.advance(LogisticsData.LOGIC_STEP)
	assert(data.total_ore() >= total)
	assert(world.break_block(Vector3i(2, 0, 0)))
	data.advance(LogisticsData.LOGIC_STEP)
	assert(data.belt_ores(Vector3i(2, 0, 0)).is_empty())
	print("PROJECT_FACTORY_RUST_CONVEYOR_PASS")
	quit(0)
