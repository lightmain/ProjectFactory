extends GdUnitTestSuite

const Reference = preload("res://tests/support/logistics_t03_reference.gd")
const Replay = preload("res://tests/support/logistics_replay.gd")
const STEP: float = LogisticsData.LOGIC_STEP


func _reference(logistics: LogisticsData) -> RefCounted:
	var reference: RefCounted = Reference.new()
	reference.call("bind_world", logistics._world)
	assert_bool(reference.call("restore_state", logistics.save_state())).is_true()
	return reference


func _compare(logistics: LogisticsData, reference: RefCounted) -> void:
	var difference: Dictionary = Replay.first_difference(
		Replay.canonical_state(reference.call("save_state")),
		Replay.canonical_state(logistics.save_state())
	)
	assert_bool(difference.is_empty()).override_failure_message(var_to_str(difference)).is_true()


func test_terrain_edit_does_not_materialize_or_disable_an_untouched_ring() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world)
	var cells: Array[Vector3i] = [Vector3i.ZERO, Vector3i.RIGHT, Vector3i(1, 0, 1), Vector3i.BACK]
	for index: int in range(cells.size()):
		assert_bool(world.place_block(cells[index], VoxelWorldData.Block.BELT)).is_true()
		assert_bool(logistics.set_direction(cells[index], cells[(index + 1) % cells.size()] - cells[index])).is_true()
	assert_bool(logistics.prefill_belts()).is_true()
	logistics.advance(STEP)
	var reference: RefCounted = _reference(logistics)
	assert_bool(logistics.enable_transport_lines()).is_true()
	logistics.advance(STEP * 3)
	reference.call("advance", STEP * 3)
	var before: Dictionary[String, int] = logistics.work_stats()
	assert_bool(world.break_block(Vector3i(6, -1, 6))).is_true()
	_compare(logistics, reference)
	var after: Dictionary[String, int] = logistics.work_stats()
	assert_int(after["transport_ring_count"]).is_equal(1)
	assert_int(after["transport_ring_materialized_ores"] - before["transport_ring_materialized_ores"]).is_equal(0)
	for tick: int in range(30):
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)
	assert_int(logistics.work_stats()["transport_ring_count"]).is_equal(1)


func test_cut_only_rebuilds_affected_line_and_other_lines_remain_active() -> void:
	var materialized_counts: Array[int] = []
	var rebuilt_counts: Array[int] = []
	for count: int in [1000, 10000]:
		var world: VoxelWorldData = VoxelWorldData.new()
		assert_bool(world.generate_flat(Vector3i(-2, -4, -2), Vector3i(104, 8, 100))).is_true()
		var logistics: LogisticsData = LogisticsData.new()
		logistics.bind_world(world, INF, 1)
		for lane: int in range(count / 100):
			for x: int in range(100):
				var cell: Vector3i = Vector3i(x, (lane / 32) * 2, (lane % 32) * 3)
				assert_bool(world.place_block(cell, VoxelWorldData.Block.BELT)).is_true()
				assert_bool(logistics.set_direction(cell, Vector3i.RIGHT)).is_true()
		logistics.advance(STEP)
		var state: Dictionary = logistics.save_state()
		var rows: Array = state["machines"]
		for index: int in range(rows.size()):
			rows[index]["ores"] = [{"id": index + 1, "incoming": Vector3i.RIGHT, "progress": 0.1}]
			rows[index]["quantity"] = 1
			rows[index]["eligible"] = 0
		state["next_id"] = count + 1
		assert_bool(logistics.restore_state(state)).is_true()
		var reference: RefCounted = _reference(logistics)
		assert_bool(logistics.enable_transport_lines()).is_true()
		logistics.advance(STEP * 3)
		reference.call("advance", STEP * 3)
		var before: Dictionary[String, int] = logistics.work_stats()
		assert_int(before.get("transport_rebuilt_machines", -1)).is_greater_equal(0)
		assert_bool(world.break_block(Vector3i(50, 0, 0))).is_true()
		_compare(logistics, reference)
		assert_int(logistics.work_stats()["transport_line_count"]).is_greater(0)
		for tick: int in range(8):
			logistics.advance(STEP)
			reference.call("advance", STEP)
		_compare(logistics, reference)
		var after: Dictionary[String, int] = logistics.work_stats()
		var materialized: int = after["transport_materialized_ores"] - before["transport_materialized_ores"]
		var rebuilt: int = after.get("transport_rebuilt_machines", -1) - before.get("transport_rebuilt_machines", -1)
		assert_int(after["transport_line_count"]).is_greater(0)
		assert_int(materialized).is_less_equal(100)
		assert_int(after["transport_fallback_work"] - before["transport_fallback_work"]).is_greater(0)
		assert_int(rebuilt).is_greater(0)
		assert_int(rebuilt).is_less_equal(200)
		assert_int(logistics.total_ore()).is_equal(count - 1)
		materialized_counts.append(materialized)
		rebuilt_counts.append(rebuilt)
	assert_int(materialized_counts[0]).is_equal(materialized_counts[1])
	assert_int(rebuilt_counts[0]).is_equal(rebuilt_counts[1])


func _place(logistics: LogisticsData, cell: Vector3i, block: int, direction: Vector3i) -> void:
	assert_bool(logistics._world.place_block(cell, block)).is_true()
	assert_bool(logistics.set_direction(cell, direction)).is_true()


func _rotate(logistics: LogisticsData, reference: RefCounted, cell: Vector3i, direction: Vector3i) -> void:
	assert_bool(logistics.set_direction(cell, direction)).is_equal(reference.call("set_direction", cell, direction))
	_compare(logistics, reference)


func _advance_pair(logistics: LogisticsData, reference: RefCounted, delta: float) -> void:
	logistics.advance(delta)
	reference.call("advance", delta)
	_compare(logistics, reference)


func test_interleaved_region_ids_and_compaction_keep_formal_and_supplemental_order() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, 0.05, 2)
	# Global target indices interleave the regions, so region-local ID allocation
	# would assign different identities even before the first topology edit.
	for x: int in range(-1, 9):
		for z: int in [0, 3, 6]:
			var block: int = VoxelWorldData.Block.BELT
			if x == -1:
				block = VoxelWorldData.Block.MINER
			elif x == 8:
				block = VoxelWorldData.Block.CHEST
			_place(logistics, Vector3i(x, 0, z), block, Vector3i.RIGHT)
	logistics.advance(STEP)
	var reference: RefCounted = _reference(logistics)
	assert_bool(logistics.enable_transport_lines()).is_true()
	for tick: int in range(80):
		_advance_pair(logistics, reference, STEP)
	_advance_pair(logistics, reference, STEP * 0.25)
	assert_bool(world.break_block(Vector3i(4, 0, 0))).is_true()
	_compare(logistics, reference)
	_rotate(logistics, reference, Vector3i(4, 0, 3), Vector3i.BACK)
	_rotate(logistics, reference, Vector3i(4, 0, 3), Vector3i.RIGHT)
	_rotate(logistics, reference, Vector3i(4, 0, 3), Vector3i.FORWARD)
	_advance_pair(logistics, reference, STEP * 0.75)
	_place(logistics, Vector3i(4, 0, 0), VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	assert_bool(reference.call("set_direction", Vector3i(4, 0, 0), Vector3i.RIGHT)).is_true()
	_compare(logistics, reference)
	# Two edits after the same formal tick must not create a second supplemental
	# transfer of ores just received by an unaffected lane.
	_advance_pair(logistics, reference, STEP * 0.25)
	_rotate(logistics, reference, Vector3i(4, 0, 3), Vector3i.RIGHT)
	_advance_pair(logistics, reference, STEP * 0.75)
	for tick: int in range(360):
		_advance_pair(logistics, reference, STEP)
	assert_int(logistics.work_stats()["transport_line_count"]).is_equal(3)
	for z: int in [0, 3, 6]:
		assert_int(logistics.ore_count(Vector3i(8, 0, z))).is_greater(0)


func test_connected_slope_ring_with_upstream_slope_survives_cut_and_reconnection() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, 0.17, 1)
	var cells: Array[Vector3i] = [
		Vector3i(-1, 0, 0), Vector3i.ZERO, Vector3i(1, 1, 0),
		Vector3i(1, 1, 1), Vector3i(0, 0, 1), Vector3i(-1, 0, 1),
		Vector3i(-1, 0, -1), Vector3i(-1, 1, -2), Vector3i(-1, 1, -3),
	]
	var blocks: Array[int] = [
		VoxelWorldData.Block.BELT, VoxelWorldData.Block.BELT_UP_EAST,
		VoxelWorldData.Block.BELT, VoxelWorldData.Block.BELT,
		VoxelWorldData.Block.BELT_DOWN_WEST, VoxelWorldData.Block.BELT,
		VoxelWorldData.Block.BELT_DOWN, VoxelWorldData.Block.BELT, VoxelWorldData.Block.MINER,
	]
	var directions: Array[Vector3i] = [
		Vector3i.RIGHT, Vector3i.RIGHT, Vector3i.BACK, Vector3i.LEFT,
		Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK, Vector3i.BACK, Vector3i.BACK,
	]
	for index: int in range(cells.size()):
		_place(logistics, cells[index], blocks[index], directions[index])
	assert_bool(logistics.prefill_belts()).is_true()
	logistics.advance(STEP)
	var reference: RefCounted = _reference(logistics)
	assert_bool(logistics.enable_transport_lines()).is_true()
	assert_int(logistics.work_stats()["transport_legacy_belts"]).is_equal(6)
	assert_int(logistics.work_stats()["transport_slope_belts"]).is_equal(1)
	for tick: int in range(60):
		_advance_pair(logistics, reference, STEP)
	_advance_pair(logistics, reference, STEP * 0.5)
	assert_bool(world.break_block(Vector3i.ZERO)).is_true()
	_compare(logistics, reference)
	_advance_pair(logistics, reference, STEP * 0.5)
	_place(logistics, Vector3i.ZERO, VoxelWorldData.Block.BELT_UP_EAST, Vector3i.RIGHT)
	_compare(logistics, reference)
	for tick: int in range(180):
		_advance_pair(logistics, reference, STEP)
	assert_int(logistics.work_stats()["transport_legacy_belts"]).is_equal(6)
	assert_int(logistics.work_stats()["transport_slope_belts"]).is_equal(1)


func test_join_and_split_two_regions_preserves_pending_rotation_and_read_isolation() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, 0.07, 1)
	for x: int in range(-1, 5):
		_place(logistics, Vector3i(x, 0, 0),
			VoxelWorldData.Block.MINER if x == -1 else VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	for z: int in range(1, 5):
		_place(logistics, Vector3i(4, 0, z),
			VoxelWorldData.Block.CHEST if z == 4 else VoxelWorldData.Block.BELT, Vector3i.BACK)
	logistics.advance(STEP)
	var reference: RefCounted = _reference(logistics)
	assert_bool(logistics.enable_transport_lines()).is_true()
	for tick: int in range(50):
		_advance_pair(logistics, reference, STEP)
	for repetition: int in range(4):
		_advance_pair(logistics, reference, STEP * 0.4)
		_rotate(logistics, reference, Vector3i(4, 0, 0), Vector3i.BACK)
		var before: Dictionary = logistics.save_state()
		logistics.sample_cells([Vector3i(3, 0, 0), Vector3i(4, 0, 1)], STEP)
		logistics.save_packed_state()
		assert_bool(logistics.save_state() == before).is_true()
		_advance_pair(logistics, reference, STEP * 0.6)
		for tick: int in range(120):
			_advance_pair(logistics, reference, STEP)
		_rotate(logistics, reference, Vector3i(4, 0, 0), Vector3i.RIGHT)
		_advance_pair(logistics, reference, STEP)
	assert_int(logistics.ore_count(Vector3i(4, 0, 4))).is_greater(0)


func test_seeded_edit_replay_keeps_identity_and_live_dense_indices() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, 0.031, 2)
	for z: int in [0, 2, 4]:
		for x: int in range(-1, 8):
			_place(logistics, Vector3i(x, 0, z),
				VoxelWorldData.Block.MINER if x == -1 else VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	assert_bool(logistics.prefill_belts()).is_true()
	logistics.advance(STEP)
	var reference: RefCounted = _reference(logistics)
	assert_bool(logistics.enable_transport_lines()).is_true()
	var random: RandomNumberGenerator = RandomNumberGenerator.new()
	random.seed = 14013
	var directions: Array[Vector3i] = [Vector3i.RIGHT, Vector3i.BACK, Vector3i.LEFT, Vector3i.FORWARD]
	var deltas: Array[float] = [0.25, 0.75, 1.5]
	for operation: int in range(120):
		var cell: Vector3i = Vector3i(random.randi_range(0, 7), 0, random.randi_range(0, 4))
		if world.get_block(cell) == VoxelWorldData.Block.BELT:
			if operation % 3 == 0:
				assert_bool(world.break_block(cell)).is_true()
			else:
				_rotate(logistics, reference, cell, directions[random.randi_range(0, 3)])
		else:
			_place(logistics, cell, VoxelWorldData.Block.BELT, Vector3i.RIGHT)
			assert_bool(reference.call("set_direction", cell, Vector3i.RIGHT)).is_true()
		_compare(logistics, reference)
		_advance_pair(logistics, reference, STEP * deltas[operation % 3])
	for tick: int in range(60):
		_advance_pair(logistics, reference, STEP)
	assert_int(logistics.work_stats()["transport_line_count"]).is_greater(0)
