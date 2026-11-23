extends SceneTree
## Compare native packed XYZ with the existing observable ore surface positions.

const Benchmark: GDScript = preload("res://scripts/pressure_native_benchmark.gd")

func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var data: LogisticsData = LogisticsData.new()
	if not data.has_method("sample_display_cells"):
		printerr("RUST_DISPLAY_FAILED missing packed display API")
		quit(1)
		return
	_bridge()
	var blocks: Array[int] = [VoxelWorldData.Block.BELT]
	for block: int in range(VoxelWorldData.Block.BELT_UP, VoxelWorldData.Block.BELT_DOWN_EAST + 1):
		blocks.append(block)
	for block: int in blocks:
		for direction: Vector3i in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]:
			var world: VoxelWorldData = VoxelWorldData.new()
			world.generate_flat()
			var cell: Vector3i = Vector3i(0, 2, 0)
			assert(world.place_block(cell, block))
			data = LogisticsData.new()
			data.bind_world(world)
			data.set_direction(cell, direction)
			data._topology.rebuild()
			var machine: LogisticsMachine = data._topology.machines[0]
			for progress: float in [0.0, 0.5, 1.0]:
				machine.belt_ores.clear()
				var ore: LogisticsOre = LogisticsOre.new(1, Vector3i.FORWARD)
				ore.progress = progress
				machine.belt_ores.append(ore)
				machine.quantity = 1
				data._batch.next_ore_id = 2
				assert(data.enable_rust_transport())
				assert(_equivalent(data, [cell, cell, Vector3i(100, 0, 0)]))
				var checkpoint: Dictionary = data.save_packed_state()
				assert(data.restore_state(checkpoint))
				assert(_equivalent(data, [cell]))
				data._before_rust_edit()
				machine = data._topology.machines[0]
	# Dense adjacent and separated queries retain all rows, limits and identities.
	var builder: PressureSaveBuilder = PressureSaveBuilder.new()
	var snapshot: SessionSnapshot = builder.build(16, 6, "rust")
	assert(snapshot != null)
	data = snapshot.logistics
	assert(data.enable_rust_transport())
	var cells: Array[Vector3i] = data.machine_cells()
	assert(_equivalent(data, cells))
	var bound_count: int = data.work_stats()["rust_display_bind_count"]
	data.advance(0.6)
	assert(_equivalent(data, cells))
	assert(data.work_stats()["rust_display_bind_count"] == bound_count)
	assert(data.set_direction(Vector3i(-4, 2, -6), Vector3i.BACK))
	data.advance(LogisticsData.LOGIC_STEP)
	assert(_equivalent(data, cells))
	_height_view()
	_reconnect_display()
	print("PROJECT_FACTORY_RUST_DISPLAY_PASS")
	quit(0)


func _bridge() -> void:
	var native: Object = ClassDB.instantiate("RustConveyorNetwork")
	assert(native.call("configure", 1.0, 0.01, 0.1)["ok"])
	assert(native.call("add_segment", 1, 1.0, PackedInt64Array([1, 2, 3, 4, 5]),
		PackedFloat64Array([1.0, 0.7, 0.5, 0.3, 0.1]), 1, 1)["ok"])
	var geometry: Dictionary = {
		"segments": PackedInt64Array([1, 1]), "starts": PackedFloat64Array([0.0, 0.5]),
		"lengths": PackedFloat64Array([0.5, 0.5]),
		"centers": PackedVector3Array([Vector3(0.25, 0.08, 0.25), Vector3(0.75, 0.08, 0.25)]),
		"incoming": PackedVector3Array([Vector3.FORWARD, Vector3.RIGHT]),
		"outgoing": PackedVector3Array([Vector3.RIGHT, Vector3.RIGHT]),
		"ports": PackedVector3Array([Vector3.BACK, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]),
		"rises": PackedFloat64Array([0.0, 0.0]), "span": 0.5,
		"fallback_ids": PackedInt64Array([5]), "fallback_directions": PackedVector3Array([Vector3.LEFT])}
	assert(not native.call("sample_display_cells", PackedInt64Array(), 4, Vector3.ZERO)["ok"])
	assert(native.call("set_display_geometry", geometry)["ok"])
	var before: PackedByteArray = native.call("snapshot")
	var page: Dictionary = native.call("sample_display_cells", PackedInt64Array([1, 0]), 1, Vector3.ZERO)
	assert(page["ok"] and page["ids"] == PackedInt64Array([1, 4]))
	assert(page["required"] == PackedInt64Array([3, 2]) and page["queries"] == 1)
	assert(page["offsets"] == PackedInt64Array([0, 1, 2]) and page["row_indices"] == PackedInt64Array([0, 1]))
	page = native.call("sample_display_cells", PackedInt64Array([0]), 4, Vector3.ZERO)
	var positions: PackedVector3Array = page["positions"]
	var fallback: LogisticsOre = LogisticsOre.new(5, Vector3i.LEFT)
	fallback.progress = 0.2
	assert(positions[1] == fallback.surface_position(Vector3i.ZERO, Vector3i.RIGHT))
	page = native.call("sample_display_cells", PackedInt64Array([0, 1]), 0, Vector3.ZERO)
	var empty_ids: PackedInt64Array = page["ids"]
	assert(page["ok"] and empty_ids.is_empty() and page["required"] == PackedInt64Array([2, 3]))
	page = native.call("sample_display_cells", PackedInt64Array(), 4, Vector3.ZERO)
	assert(page["ok"] and page["offsets"] == PackedInt64Array([0]))
	for indices: PackedInt64Array in [PackedInt64Array([-1]), PackedInt64Array([2])]:
		assert(not native.call("sample_display_cells", indices, 4, Vector3.ZERO)["ok"])
	assert(not native.call("sample_display_cells", PackedInt64Array([0]), -1, Vector3.ZERO)["ok"])
	assert(not native.call("sample_display_cells", PackedInt64Array([0]), 4, Vector3(INF, 0.0, 0.0))["ok"])
	for field: String in ["segments", "lengths", "ports", "fallback_ids"]:
		var invalid: Dictionary = geometry.duplicate(true)
		invalid.erase(field)
		assert(not native.call("set_display_geometry", invalid)["ok"])
		assert(native.call("sample_display_cells", PackedInt64Array([0]), 4, Vector3.ZERO)["ok"])
	var invalid: Dictionary = geometry.duplicate(true)
	invalid["starts"][0] = NAN
	assert(not native.call("set_display_geometry", invalid)["ok"])
	invalid = geometry.duplicate(true)
	invalid["span"] = 1e100
	assert(not native.call("set_display_geometry", invalid)["ok"])
	invalid = geometry.duplicate(true)
	invalid["lengths"][1] = pow(2.0, -55.0)
	assert(not native.call("set_display_geometry", invalid)["ok"])
	assert(native.call("sample_display_cells", PackedInt64Array([0]), 4, Vector3.ZERO)["ok"])
	assert(native.call("snapshot") == before)
	assert(not native.call("configure", NAN, 0.01, 0.1)["ok"])
	assert(native.call("sample_display_cells", PackedInt64Array([0]), 4, Vector3.ZERO)["ok"])
	assert(native.call("restore", before)["ok"])
	assert(not native.call("sample_display_cells", PackedInt64Array([0]), 4, Vector3.ZERO)["ok"])
	assert(native.call("set_display_geometry", geometry)["ok"])
	# Known port overrides unknown-entry fallback and survives ordinary ticks.
	assert(native.call("insert_items", 1, 0, PackedInt64Array([6]), 1)["count"] == 1)
	page = native.call("sample_display_cells", PackedInt64Array([0]), 4, Vector3.ZERO)
	var known: LogisticsOre = LogisticsOre.new(6, Vector3i.BACK)
	var ids: PackedInt64Array = page["ids"]
	positions = page["positions"]
	assert(positions[ids.find(6)] == known.surface_position(Vector3i.ZERO, Vector3i.RIGHT))
	assert(native.call("tick", PackedInt64Array(), PackedInt64Array())["ok"])
	assert(native.call("sample_display_cells", PackedInt64Array([0]), 4, Vector3.ZERO)["ok"])
	assert(native.call("add_segment", 2, 0.5, PackedInt64Array(), PackedFloat64Array(), 1, 1)["ok"])
	assert(not native.call("sample_display_cells", PackedInt64Array([0]), 4, Vector3.ZERO)["ok"])
	assert(native.call("set_display_geometry", geometry)["ok"])
	assert(native.call("link_segments", 1, 0, 2, 0)["ok"])
	assert(not native.call("sample_display_cells", PackedInt64Array([0]), 4, Vector3.ZERO)["ok"])


func _height_view() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	var game: FactoryGame = scene.instantiate() as FactoryGame
	root.add_child(game)
	Benchmark.call("isolate_game", game)
	game.game_config.ore_render_distance = 100.0
	game.game_config.ore_render_max_height_above_camera = 0.0
	for block: int in range(VoxelWorldData.Block.BELT_UP, VoxelWorldData.Block.BELT_DOWN_EAST + 1):
		game.world_data.generate_flat()
		assert(game.world_data.place_block(Vector3i.ZERO, block))
		assert(game.logistics_data.enable_rust_transport())
		assert(game.logistics_data.prefill_belts())
		var ores: Array[LogisticsOre] = game.logistics_data.belt_ores(Vector3i.ZERO)
		var position: Vector3 = ores[0].surface_position(Vector3i.ZERO,
			game.logistics_data.direction_at(Vector3i.ZERO), block) + Vector3.UP * LogisticsView.ORE_SURFACE_OFFSET
		game.player.camera.global_position = position
		game.logistics_view.refresh_from_data()
		assert(game.logistics_view.item_render_pool.has_item(ores[0].id))
		assert(game.logistics_view.item_render_pool.item_transform(ores[0].id).origin == position)
		game.player.camera.global_position.y -= 0.001
		game.logistics_view.refresh_from_data()
		assert(not game.logistics_view.item_render_pool.has_item(ores[0].id))
	assert(game.logistics_view.has_method("display_error"))
	var before_tick: int = game.logistics_data.logic_tick()
	var native: Object = game.logistics_data._rust_transport._network
	var checkpoint: PackedByteArray = native.call("snapshot")
	assert(native.call("restore", checkpoint)["ok"])
	game.player.camera.global_position.y = 10.0
	game.logistics_view.refresh_from_data()
	var display_failure: String = game.logistics_view.call("display_error")
	assert(not display_failure.is_empty())
	assert(game.logistics_data.transport_error().is_empty())
	game.logistics_data.advance(LogisticsData.LOGIC_STEP)
	assert(game.logistics_data.logic_tick() == before_tick + 1)
	game.logistics_data._rust_transport._display_ready = false
	game.logistics_view.refresh_from_data()
	display_failure = game.logistics_view.call("display_error")
	assert(display_failure.is_empty())
	game.game_config.ore_render_distance = 0.0
	game.logistics_view.refresh_from_data()
	assert(game.logistics_data.work_stats()["rust_display_queries"] == 0)
	assert(game.logistics_data.work_stats()["rust_display_query_ns"] == 0)
	assert(game.logistics_data.work_stats()["rust_display_xyz_ns"] == 0)
	game.free()


func _reconnect_display() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	world.place_block(Vector3i.RIGHT, VoxelWorldData.Block.BELT)
	var data: LogisticsData = LogisticsData.new()
	data.bind_world(world)
	data.set_direction(Vector3i.ZERO, Vector3i.FORWARD)
	data.set_direction(Vector3i.RIGHT, Vector3i.RIGHT)
	data._topology.rebuild()
	for index: int in range(2):
		var ore: LogisticsOre = LogisticsOre.new(index + 1, Vector3i.RIGHT)
		ore.progress = 1.0 if index == 0 else 0.0
		data._topology.machines[index].belt_ores.append(ore)
		data._topology.machines[index].quantity = 1
	data._batch.next_ore_id = 3
	assert(data.enable_rust_transport())
	assert(data.set_direction(Vector3i.ZERO, Vector3i.RIGHT))
	assert(_equivalent(data, [Vector3i.ZERO, Vector3i.RIGHT]))
	for tick: int in range(60):
		data.advance(LogisticsData.LOGIC_STEP)
		assert(_equivalent(data, [Vector3i.ZERO, Vector3i.RIGHT]))
	var pending: PackedInt64Array = data._rust_transport.save_binding()["pending"]
	assert(pending.is_empty())


func _equivalent(data: LogisticsData, cells: Array[Vector3i]) -> bool:
	if not data._ensure_rust():
		return false
	var before: PackedByteArray = data._rust_transport.snapshot()
	var rows: Array[LogisticsOreQueue] = data.sample_cells(cells)
	var offset: Vector3 = Vector3.UP * LogisticsView.ORE_SURFACE_OFFSET
	var page: Dictionary = data.call("sample_display_cells", cells, offset)
	if not page.get("ok", false):
		printerr(page)
		return false
	var ids: PackedInt64Array = page["ids"]
	var positions: PackedVector3Array = page["positions"]
	var owners: PackedInt64Array = page["row_indices"]
	var requested: Array[Vector3i] = page["cells"]
	var cursor: int = 0
	for row: LogisticsOreQueue in rows:
		if not VoxelWorldData.is_belt(row.block):
			continue
		for ore: LogisticsOre in row.ores:
			if cursor >= ids.size() or ids[cursor] != ore.id or requested[owners[cursor]] != row.cell:
				return false
			var expected: Vector3 = ore.surface_position(row.cell, row.direction, row.block) + offset
			if positions[cursor] != expected:
				printerr("XYZ differs ", positions[cursor], " / ", expected, " at ", row.cell)
				return false
			cursor += 1
	return cursor == ids.size() and data._rust_transport.snapshot() == before
