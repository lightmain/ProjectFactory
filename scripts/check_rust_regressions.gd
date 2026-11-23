extends SceneTree
## Real native host regression checks, selectable for RED/GREEN evidence.


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var checks: Array[String] = ["reconnect", "direct", "failure", "binding", "merge", "rogue",
		"ring", "ring_sparse", "ring_input", "rejected_import", "dense_edit", "identity"]
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.is_empty():
		checks.assign(Array(args))
	for name: String in checks:
		if not call("_" + name):
			printerr("RUST_HOST_REGRESSION_FAILED ", name)
			quit(1)
			return
		print("RUST_HOST_REGRESSION_PASS ", name)
	quit(0)


func _identity() -> bool:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	world.place_block(Vector3i.RIGHT, VoxelWorldData.Block.BELT)
	var edge: LogisticsData = LogisticsData.new()
	edge.bind_world(world, 0.01, 1)
	edge.set_direction(Vector3i.ZERO, Vector3i.RIGHT)
	edge.set_direction(Vector3i.RIGHT, Vector3i.RIGHT)
	edge._batch.next_ore_id = SnapshotValues.MAX_INTEGER - 1
	if not edge.enable_rust_transport():
		return false
	edge.advance(LogisticsData.LOGIC_STEP)
	if not edge.transport_error().is_empty() or edge._batch.next_ore_id != SnapshotValues.MAX_INTEGER:
		return false
	var final_valid: Dictionary = edge.save_packed_state()
	if not edge.restore_state(final_valid) or edge.save_packed_state() != final_valid:
		return false
	var data: LogisticsData = LogisticsData.new()
	data.bind_world(world, 0.01, 1)
	data.set_direction(Vector3i.ZERO, Vector3i.RIGHT)
	data.set_direction(Vector3i.RIGHT, Vector3i.RIGHT)
	data._batch.next_ore_id = SnapshotValues.MAX_INTEGER
	if not data.enable_rust_transport():
		return false
	var checkpoint: Dictionary = data.save_packed_state()
	var loaded: LogisticsData = LogisticsData.new()
	loaded.bind_world(world)
	if not loaded.restore_state(checkpoint):
		return false
	var phase: Dictionary = data._topology.machines[0].production_phase()
	data.advance(LogisticsData.LOGIC_STEP)
	if data.transport_error().is_empty() or data.logic_tick() != 0 or (
		data._topology.machines[0].quantity != 0
		or data._topology.machines[0].production_phase() != phase
		or data._batch.next_ore_id != SnapshotValues.MAX_INTEGER
	):
		printerr("Identity exhaustion must reject before host settlement.")
		return false
	loaded.advance(LogisticsData.LOGIC_STEP)
	if loaded.transport_error().is_empty() or loaded.logic_tick() != 0 or (
		loaded._topology.machines[0].quantity != 0
		or loaded._topology.machines[0].production_phase() != phase
		or loaded._batch.next_ore_id != SnapshotValues.MAX_INTEGER
	):
		return false
	return data.restore_state(checkpoint) and data.save_packed_state() == checkpoint


func _reconnect() -> bool:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	world.place_block(Vector3i(0, 0, 0), VoxelWorldData.Block.BELT)
	world.place_block(Vector3i(1, 0, 0), VoxelWorldData.Block.BELT)
	var data: LogisticsData = LogisticsData.new()
	data.bind_world(world)
	data.set_direction(Vector3i(0, 0, 0), Vector3i.FORWARD)
	data.set_direction(Vector3i(1, 0, 0), Vector3i.RIGHT)
	data._topology.rebuild()
	for index: int in range(2):
		var ore: LogisticsOre = LogisticsOre.new(index + 1, Vector3i.RIGHT)
		ore.progress = 1.0 if index == 0 else 0.0
		data._topology.machines[index].belt_ores.append(ore)
		data._topology.machines[index].quantity = 1
		data._topology.machines[index].eligible_quantity = 1
	data._batch.next_ore_id = 3
	if not data.enable_rust_transport() or not data.set_direction(Vector3i.ZERO, Vector3i.RIGHT):
		return false
	data.advance(LogisticsData.LOGIC_STEP)
	if not data.transport_error().is_empty() or data.total_ore() != 2:
		printerr(data.transport_error())
		return false
	var saved: Dictionary = data.save_packed_state()
	var loaded: LogisticsData = LogisticsData.new()
	loaded.bind_world(world)
	if not loaded.restore_state(saved) or loaded.save_packed_state() != saved:
		return false
	data.advance(0.5)
	loaded.advance(0.5)
	if data.save_packed_state() != loaded.save_packed_state():
		for key: Variant in data.save_packed_state():
			if data.save_packed_state()[key] != loaded.save_packed_state().get(key):
				printerr("Reconnect checkpoint differs at ", key)
	if not data.transport_error().is_empty() or not loaded.transport_error().is_empty():
		printerr("Reconnect continuation errors: ", data.transport_error(), " / ", loaded.transport_error())
	return data.total_ore() == 2 and data.transport_error().is_empty() and (
		data.save_packed_state() == loaded.save_packed_state()
	)


func _direct() -> bool:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	for x: int in range(3):
		world.place_block(Vector3i(x, 0, 0), VoxelWorldData.Block.CHEST)
	var data: LogisticsData = LogisticsData.new()
	data.bind_world(world)
	for cell: Vector3i in data.machine_cells():
		data.set_direction(cell, Vector3i.RIGHT)
	data._topology.machines[0].quantity = 7
	if not data.enable_rust_transport():
		return false
	data.advance(LogisticsData.LOGIC_STEP)
	return data.ore_count(Vector3i.ZERO) == 0 and data.ore_count(Vector3i.RIGHT) == 7 and (
		data.ore_count(Vector3i(2, 0, 0)) == 0
	)


func _failure() -> bool:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	world.place_block(Vector3i.RIGHT, VoxelWorldData.Block.BELT)
	var data: LogisticsData = LogisticsData.new()
	data.bind_world(world, 0.01, 1)
	data.set_direction(Vector3i.ZERO, Vector3i.RIGHT)
	data.set_direction(Vector3i.RIGHT, Vector3i.RIGHT)
	if not data.enable_rust_transport():
		return false
	# Force a real native preflight failure exactly when production is due.
	var phase: Dictionary = data._topology.machines[0].production_phase()
	var checkpoint: Dictionary = data.save_packed_state()
	data._rust_transport._producers[11] = 0 # Segment 2, unsupported input slot 3.
	data.advance(LogisticsData.LOGIC_STEP * 3.0)
	if data.transport_error().is_empty():
		return false
	return data.logic_tick() == 0 and data._topology.machines[0].quantity == 0 and (
		data._topology.machines[0].production_phase() == phase
		and data.restore_state(checkpoint)
	)


func _binding() -> bool:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	var data: LogisticsData = LogisticsData.new()
	data.bind_world(world)
	if not data.enable_rust_transport():
		return false
	var saved: Dictionary = data.save_packed_state()
	if not saved.get("binding") is Dictionary:
		return false
	var corrupt: Dictionary = saved.duplicate(true)
	corrupt["binding"]["keys"][0] += 1
	return not data.restore_state(corrupt) and data.save_packed_state() == saved


func _merge() -> bool:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	for cell: Vector3i in [Vector3i.LEFT, Vector3i.BACK, Vector3i.ZERO]:
		world.place_block(cell, VoxelWorldData.Block.BELT)
	var data: LogisticsData = LogisticsData.new()
	data.bind_world(world)
	data.set_direction(Vector3i.LEFT, Vector3i.RIGHT)
	data.set_direction(Vector3i.BACK, Vector3i.FORWARD)
	data.set_direction(Vector3i.ZERO, Vector3i.RIGHT)
	var index: int = data._topology.index_at(Vector3i.BACK)
	var ore: LogisticsOre = LogisticsOre.new(1, Vector3i.FORWARD)
	ore.progress = 1.0
	data._topology.machines[index].belt_ores.append(ore)
	data._topology.machines[index].quantity = 1
	data._batch.next_ore_id = 2
	if not data.enable_rust_transport():
		return false
	data.advance(LogisticsData.LOGIC_STEP)
	var rows: Array[LogisticsOre] = data.belt_ores(Vector3i.ZERO)
	return rows.size() == 1 and rows[0].incoming_direction == Vector3i.FORWARD


func _rogue() -> bool:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	var data: LogisticsData = LogisticsData.new()
	data.bind_world(world)
	if not data.enable_rust_transport():
		return false
	var saved: Dictionary = data.save_packed_state()
	var foreign: Object = ClassDB.instantiate("RustConveyorNetwork")
	foreign.call("configure", 1.0, LogisticsData.LOGIC_STEP, 0.25)
	foreign.call("add_segment", 1, 0.5, PackedInt64Array(), PackedFloat64Array(), 1, 1)
	var frame: Dictionary = foreign.call("tick", PackedInt64Array(), PackedInt64Array([1, 0, 1, 1]))
	if not frame.get("ok", false):
		return false
	var corrupt: Dictionary = saved.duplicate(true)
	corrupt["native"] = foreign.call("snapshot")
	corrupt["time"] = LogisticsData.LOGIC_STEP
	corrupt["tick"] = 1
	return not data.restore_state(corrupt) and data.save_packed_state() == saved


func _ring() -> bool:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var cells: Array[Vector3i] = [Vector3i.ZERO, Vector3i.RIGHT, Vector3i(1, 0, 1), Vector3i.BACK]
	for cell: Vector3i in cells:
		world.place_block(cell, VoxelWorldData.Block.BELT)
	var data: LogisticsData = LogisticsData.new()
	data.bind_world(world)
	for index: int in range(cells.size()):
		data.set_direction(cells[index], cells[(index + 1) % cells.size()] - cells[index])
	if not data.enable_rust_transport() or not data.prefill_belts():
		printerr("Ring preparation failed: ", data.transport_error())
		return false
	# Normalize exact outlet ownership at the first committed boundary.
	data.advance(LogisticsData.LOGIC_STEP)
	var before: Array[LogisticsOreQueue] = data.sample_cells(cells)
	data.advance(1.0)
	var after: Array[LogisticsOreQueue] = data.sample_cells(cells)
	if not data.transport_error().is_empty() or data.total_ore() != 8 or (
		data.work_stats()["rust_segments"] > 2
	):
		printerr("Ring error=", data.transport_error(), " total=", data.total_ore(),
			" segments=", data.work_stats()["rust_segments"])
		return false
	for index: int in range(before.size()):
		for ore_index: int in range(before[index].ores.size()):
			if before[index].ores[ore_index].id != after[index].ores[ore_index].id or (
				before[index].ores[ore_index].progress != after[index].ores[ore_index].progress
			):
				printerr("Full ring moved: ", before[index].ores[ore_index].progress, " -> ",
					after[index].ores[ore_index].progress)
				return false
	return true


func _ring_sparse() -> bool:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var cells: Array[Vector3i] = [Vector3i.ZERO, Vector3i.RIGHT, Vector3i(1, 0, 1), Vector3i.BACK]
	for cell: Vector3i in cells:
		world.place_block(cell, VoxelWorldData.Block.BELT)
	var data: LogisticsData = LogisticsData.new()
	data.bind_world(world)
	for index: int in range(cells.size()):
		data.set_direction(cells[index], cells[(index + 1) % cells.size()] - cells[index])
	if not data.enable_rust_transport():
		return false
	data.advance(0.1)
	if data.total_ore() != 0 or not data.transport_error().is_empty():
		return false
	# One item starts inside a belt, avoiding an ambiguous exact outlet.
	data._before_rust_edit()
	var machine: LogisticsMachine = data._topology.machines[data._topology.index_at(Vector3i.ZERO)]
	var ore: LogisticsOre = LogisticsOre.new(1, Vector3i.FORWARD)
	ore.progress = 0.1
	machine.belt_ores.append(ore)
	machine.quantity = 1
	data._batch.next_ore_id = 2
	data.advance(2.0)
	var items: Array[LogisticsOre] = data.belt_ores(Vector3i.ZERO)
	return data.transport_error().is_empty() and data.total_ore() == 1 and items.size() == 1 and (
		items[0].id == 1 and absf(items[0].progress - 0.1) < 0.0000001
	)


func _ring_input() -> bool:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var cells: Array[Vector3i] = [Vector3i.ZERO, Vector3i.RIGHT, Vector3i(1, 0, 1), Vector3i.BACK]
	for cell: Vector3i in cells:
		world.place_block(cell, VoxelWorldData.Block.BELT)
	world.place_block(Vector3i.LEFT, VoxelWorldData.Block.MINER)
	var data: LogisticsData = LogisticsData.new()
	data.bind_world(world)
	data.set_direction(Vector3i.LEFT, Vector3i.RIGHT)
	for index: int in range(cells.size()):
		data.set_direction(cells[index], cells[(index + 1) % cells.size()] - cells[index])
	if not data.enable_rust_transport() or not data.prefill_belts():
		printerr("Fed ring prepare: ", data.transport_error())
		return false
	data.advance(2.0)
	# C-1 permits one extra item on the external inlet before the common
	# merge neighbourhood; it then blocks while the closed ring stays full.
	if data.total_ore() != 10 or data.ore_count(Vector3i.LEFT) != 1:
		return false
	data.advance(2.0)
	return data.transport_error().is_empty() and data.total_ore() == 12 and (
		data.ore_count(Vector3i.LEFT) == 3 and data.work_stats()["rust_items"] == 9
	)


func _rejected_import() -> bool:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	var data: LogisticsData = LogisticsData.new()
	data.bind_world(world)
	var ore: LogisticsOre = LogisticsOre.new(1, Vector3i.FORWARD)
	ore.progress = 2.0
	data._topology.machines[0].belt_ores.append(ore)
	data._topology.machines[0].quantity = 1
	if data.enable_rust_transport():
		return false
	data.advance(0.1)
	return data.transport_backend() == "rust" and not data.transport_error().is_empty() and data.logic_tick() == 0


func _dense_edit() -> bool:
	var builder: PressureSaveBuilder = PressureSaveBuilder.new()
	var snapshot: SessionSnapshot = builder.build(16, 6, "rust")
	if snapshot == null:
		return false
	var data: LogisticsData = snapshot.logistics
	data.advance(0.6)
	var total: int = data.total_ore()
	var cell: Vector3i = Vector3i(-4, 2, -6)
	if not data.set_direction(cell, Vector3i.BACK):
		return false
	data.advance(LogisticsData.LOGIC_STEP)
	if not data.transport_error().is_empty():
		printerr("Dense edit error: ", data.transport_error())
		return false
	return data.total_ore() == total
