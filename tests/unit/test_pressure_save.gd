extends GdUnitTestSuite


func test_large_single_floor_snapshot_and_far_facility_roundtrip() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world)
	var state: Dictionary = {
		"version": 4, "generator": 1,
		"minimum": Vector3i(-64, -1, -64), "maximum": Vector3i(64, 63, 64),
		"floor_depth": 1, "flat": true, "chunks": {}, "structures": [],
		"logistics": logistics.save_state(), "inventory": InventoryData.new().save_state(),
		"player": {"position": Vector3(0, 0.01, 0), "velocity": Vector3.ZERO,
			"spawn": Vector3(0, 0.01, 0), "rotation": Vector3.ZERO, "tool": 6, "build_rotation": 0},
	}
	var snapshot: SessionSnapshot = SessionSnapshot.decode(state)
	assert_object(snapshot).is_not_null()
	if snapshot == null:
		return
	assert_int(snapshot.world.block_count()).is_equal(128 * 128)
	assert_bool(snapshot.world.is_in_bounds(Vector3i(63, 62, 63))).is_true()
	assert_bool(snapshot.world.is_in_bounds(Vector3i(64, 0, 0))).is_false()
	assert_int(snapshot.world.get_block(Vector3i(0, -1, 0))).is_equal(VoxelWorldData.Block.BEDROCK)
	assert_bool(snapshot.world.place_block(Vector3i(63, 62, 63), VoxelWorldData.Block.BELT)).is_true()
	assert_int(snapshot.logistics.machine_cells().size()).is_equal(1)


func test_invalid_large_bounds_are_rejected() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world)
	var state: Dictionary = {
		"version": 4, "generator": 1, "minimum": Vector3i(-64, -1, -64),
		"maximum": Vector3i(65, 63, 64), "floor_depth": 1, "flat": true,
		"chunks": {}, "structures": [], "logistics": logistics.save_state(), "inventory": InventoryData.new().save_state(),
		"player": {},
	}
	assert_object(SessionSnapshot.decode(state)).is_null()


func test_packed_queues_roundtrip_and_reject_truncated_or_duplicate_ore() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world)
	var state: Dictionary = logistics.save_state()
	state["machines"][0]["quantity"] = 2
	state["machines"][0]["ores"] = [
		{"id": 1, "incoming": Vector3i.FORWARD, "progress": 1.0},
		{"id": 2, "incoming": Vector3i.FORWARD, "progress": 0.5},
	]
	state["next_id"] = 3
	assert_bool(logistics.restore_state(state)).is_true()
	var packed: Dictionary = logistics.save_packed_state()
	assert_bool(packed.get("machines") is PackedByteArray).is_true()
	var restored: LogisticsData = LogisticsData.new()
	restored.bind_world(world)
	assert_bool(restored.restore_state(packed)).is_true()
	assert_bool(restored.save_state() == logistics.save_state()).is_true()
	var before: Dictionary = restored.save_state()
	var duplicate: Dictionary = logistics.save_packed_state()
	var duplicate_bytes: PackedByteArray = duplicate["machines"]
	duplicate_bytes.encode_s64(112, 1)
	duplicate["machines"] = duplicate_bytes
	assert_bool(restored.restore_state(duplicate)).is_false()
	assert_bool(restored.save_state() == before).is_true()
	var bytes: PackedByteArray = packed["machines"]
	bytes.resize(bytes.size() - 1)
	packed["machines"] = bytes
	assert_bool(restored.restore_state(packed)).is_false()
	assert_bool(restored.save_state() == before).is_true()


func test_pressure_route_has_four_sources_one_sink_and_every_belt_reaches_sink() -> void:
	var builder: PressureSaveBuilder = PressureSaveBuilder.new()
	var snapshot: SessionSnapshot = builder.build(8, 6)
	assert_object(snapshot).is_not_null()
	if snapshot == null:
		return
	var state: Dictionary = snapshot.logistics.save_state()
	var rows: Array = state["machines"]
	var outgoing: Array = state["outgoing"]
	var sinks: int = 0
	var miners: int = 0
	var belts: int = 0
	for index: int in range(rows.size()):
		var row: Dictionary = rows[index]
		if row["block"] == VoxelWorldData.Block.MINER:
			miners += 1
		elif row["block"] == VoxelWorldData.Block.CHEST:
			sinks += 1
		else:
			belts += 1
			assert_int(row["quantity"]).is_equal(2)
		var cursor: int = index
		var steps: int = 0
		while outgoing[cursor] >= 0 and steps <= rows.size():
			cursor = outgoing[cursor]
			steps += 1
		assert_int(steps).is_less(rows.size())
		assert_int(rows[cursor]["block"]).is_equal(VoxelWorldData.Block.CHEST)
	assert_int(miners).is_equal(4)
	assert_int(sinks).is_equal(1)
	assert_int(snapshot.logistics.total_ore()).is_equal(belts * 2)
	var body: AABB = AABB(snapshot.position - Vector3(0.28, 0, 0.28), Vector3(0.56, 1.75, 0.56))
	for cell: Vector3i in snapshot.world.solid_cells():
		assert_bool(VoxelWorldData.block_intersects_bounds(cell, snapshot.world.get_block(cell), body)).is_false()
	assert_object(SessionSnapshot.decode(PressureSaveBuilder.state_for(snapshot))).is_not_null()


func test_pressure_certificate_rejects_a_broken_chain() -> void:
	var builder: PressureSaveBuilder = PressureSaveBuilder.new()
	var snapshot: SessionSnapshot = builder.build(8, 6)
	var certificate: Dictionary = PressureSaveBuilder.route_certificate(snapshot)
	assert_int(certificate["belts"]).is_equal(252)
	assert_int(certificate["visited_belts"]).is_equal(252)
	snapshot.logistics.set_direction(Vector3i(-1, 0, -4), Vector3i.FORWARD)
	var broken: Dictionary = PressureSaveBuilder.route_certificate(snapshot)
	assert_bool(broken.is_empty()).is_true()
	snapshot.logistics.advance(LogisticsData.LOGIC_STEP)
	broken = PressureSaveBuilder.route_certificate(snapshot)
	assert_bool(broken.is_empty()).is_true()
