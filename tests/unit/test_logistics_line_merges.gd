extends GdUnitTestSuite

const Reference = preload("res://tests/support/logistics_t03_reference.gd")
const Replay = preload("res://tests/support/logistics_replay.gd")
const STEP: float = LogisticsData.LOGIC_STEP


func _place(logistics: LogisticsData, cell: Vector3i, block: int, direction: Vector3i) -> void:
	assert_bool(logistics._world.place_block(cell, block)).is_true()
	assert_bool(logistics.set_direction(cell, direction)).is_true()


func _enable(logistics: LogisticsData) -> void:
	# A missing development entry fails explicitly; the state checks below
	# still run, rather than silently skipping when aggregation is inactive.
	assert_bool(logistics.has_method("enable_transport_lines")).is_true()
	if logistics.has_method("enable_transport_lines"):
		assert_bool(logistics.call("enable_transport_lines")).is_true()
	assert_int(logistics.work_stats().get("transport_line_count", -1)).is_greater(0)


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


func _compare_prediction(logistics: LogisticsData, reference: RefCounted, cell: Vector3i) -> void:
	var before: Dictionary = logistics.save_state()
	var expected: Array[Dictionary] = []
	var all_expected: Array = reference.call("sample_state", STEP * 0.7)
	for row: Dictionary in all_expected:
		if row["cell"] == cell:
			expected.append(row)
	var actual: Array[Dictionary] = []
	for queue: LogisticsOreQueue in logistics.sample_cells([cell], STEP * 0.7):
		var ores: Array[Dictionary] = []
		for ore: LogisticsOre in queue.ores:
			ores.append({"id": ore.id, "incoming": ore.incoming_direction, "progress": ore.progress})
		actual.append({"cell": queue.cell, "direction": queue.direction, "block": queue.block, "ores": ores})
	var difference: Dictionary = Replay.first_difference(expected, actual)
	assert_bool(difference.is_empty()).override_failure_message(var_to_str(difference)).is_true()
	assert_bool(logistics.save_state() == before).is_true()


func _merges(interval: float) -> LogisticsData:
	var world: VoxelWorldData = VoxelWorldData.new()
	assert_bool(world.generate_flat(Vector3i(-8, -4, -8), Vector3i(12, 12, 12))).is_true()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, interval, 1)
	_place(logistics, Vector3i.LEFT, VoxelWorldData.Block.MINER, Vector3i.RIGHT)
	for x: int in range(8):
		_place(logistics, Vector3i(x, 0, 0), VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	_place(logistics, Vector3i(8, 0, 0), VoxelWorldData.Block.CHEST, Vector3i.RIGHT)
	logistics.advance(STEP * 0.25)
	_place(logistics, Vector3i(2, 0, 4), VoxelWorldData.Block.MINER, Vector3i.FORWARD)
	for z: int in range(1, 4):
		_place(logistics, Vector3i(2, 0, z), VoxelWorldData.Block.BELT, Vector3i.FORWARD)
	logistics.advance(STEP * 0.25)
	_place(logistics, Vector3i(5, 0, -4), VoxelWorldData.Block.MINER, Vector3i.BACK)
	for z: int in range(-3, 0):
		_place(logistics, Vector3i(5, 0, z), VoxelWorldData.Block.BELT, Vector3i.BACK)
	logistics.advance(STEP * 0.5)
	var state: Dictionary = logistics.save_state()
	var rows: Array = state["machines"]
	var next_id: int = state["next_id"]
	for row: Dictionary in rows:
		if row["block"] == VoxelWorldData.Block.BELT:
			row["ores"] = [
				{"id": next_id, "incoming": row["settled"], "progress": 1.0},
				{"id": next_id + 1, "incoming": row["settled"], "progress": 0.5},
			]
			next_id += 2
			row["quantity"] = 2
			row["eligible"] = 2
		elif row["block"] == VoxelWorldData.Block.MINER:
			row["quantity"] += 4
			row["eligible"] = row["quantity"]
	state["next_id"] = next_id
	assert_bool(logistics.restore_state(state)).is_true()
	return logistics


func test_staggered_miners_and_two_merge_boundaries_match_every_tick() -> void:
	for interval: float in [0.001, 0.17, 0.503]:
		var logistics: LogisticsData = _merges(interval)
		var reference: RefCounted = _reference(logistics)
		_enable(logistics)
		var expected_total: int = logistics.total_ore()
		for tick: int in range(180):
			var before: Dictionary = logistics.save_state()
			logistics.advance(STEP)
			reference.call("advance", STEP)
			_compare(logistics, reference)
			expected_total += Replay.production_between(before, logistics.logic_tick())
			assert_int(logistics.total_ore()).is_equal(expected_total)
			if tick % 15 == 0:
				_compare_prediction(logistics, reference, Vector3i(2, 0, 0))
		assert_int(logistics.ore_count(Vector3i(8, 0, 0))).is_greater(0)
		assert_int(logistics.work_stats().get("transport_boundary_events", -1)).is_greater(0)
		assert_int(logistics.work_stats().get("transport_fallback_work", -1)).is_greater(0)


func test_inventory_input_wakes_at_tail_halfway_before_any_ore_reaches_exit() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, INF, 1)
	_place(logistics, Vector3i.LEFT, VoxelWorldData.Block.MINER, Vector3i.RIGHT)
	for x: int in range(2):
		_place(logistics, Vector3i(x, 0, 0), VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	_place(logistics, Vector3i(2, 0, 0), VoxelWorldData.Block.CHEST, Vector3i.RIGHT)
	logistics.advance(STEP)
	var state: Dictionary = logistics.save_state()
	var rows: Array = state["machines"]
	rows[0]["quantity"] = 3
	rows[0]["eligible"] = 3
	rows[1]["ores"] = [{"id": 1, "incoming": Vector3i.RIGHT, "progress": 0.2}]
	rows[1]["quantity"] = 1
	rows[1]["eligible"] = 1
	state["next_id"] = 2
	assert_bool(logistics.restore_state(state)).is_true()
	var reference: RefCounted = _reference(logistics)
	_enable(logistics)
	var before: Dictionary[String, int] = logistics.work_stats()
	for tick: int in range(8):
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)
	assert_int(logistics.ore_count(Vector3i.ZERO)).is_equal(1)
	assert_int(logistics.ore_count(Vector3i.LEFT)).is_equal(3)
	var waiting: Dictionary[String, int] = logistics.work_stats()
	assert_int(waiting.get("transport_common_ticks", -1) - before.get("transport_common_ticks", -1)).is_equal(8)
	assert_int(waiting.get("transport_ore_visits", -1) - before.get("transport_ore_visits", -1)).is_equal(0)
	logistics.advance(STEP)
	reference.call("advance", STEP)
	_compare(logistics, reference)
	assert_int(logistics.ore_count(Vector3i.ZERO)).is_equal(2)
	assert_int(logistics.ore_count(Vector3i.LEFT)).is_equal(2)
	rows = logistics.save_state()["machines"]
	var arriving_ores: Array = rows[1]["ores"]
	assert_int(arriving_ores.size()).is_equal(2)
	if arriving_ores.size() != 2:
		return
	assert_float(rows[1]["ores"][0]["progress"]).is_equal_approx(0.5, 0.000001)
	assert_float(rows[1]["ores"][1]["progress"]).is_equal(0.0)
	assert_int(rows[1]["eligible"]).is_equal(1)
	assert_int(logistics.work_stats().get("transport_boundary_events", -1)).is_greater(0)


func test_three_inputs_remain_fair_in_all_four_directions() -> void:
	for facing: Vector3i in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]:
		var world: VoxelWorldData = VoxelWorldData.new()
		world.generate_flat()
		var logistics: LogisticsData = LogisticsData.new()
		logistics.bind_world(world, 0.5, 4)
		var side: Vector3i = Vector3i(-facing.z, 0, facing.x)
		var sources: Array[Vector3i] = [-facing, -side, side]
		for direction: Vector3i in [facing, side, -side]:
			_place(logistics, -direction, VoxelWorldData.Block.MINER, direction)
		_place(logistics, Vector3i.ZERO, VoxelWorldData.Block.BELT, facing)
		_place(logistics, facing, VoxelWorldData.Block.BELT, facing)
		_place(logistics, facing * 2, VoxelWorldData.Block.CHEST, facing)
		logistics.advance(STEP)
		var reference: RefCounted = _reference(logistics)
		_enable(logistics)
		for tick: int in range(600):
			logistics.advance(STEP)
			reference.call("advance", STEP)
			_compare(logistics, reference)
		assert_int(logistics.ore_count(facing * 2)).is_greater(0)
		for first: Vector3i in sources:
			for second: Vector3i in sources:
				assert_int(absi(logistics.ore_count(first) - logistics.ore_count(second))).is_less_equal(1)


func test_mixed_flat_and_slopes_transfer_both_ways_without_double_settlement() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, 0.17, 2)
	var cells: Array[Vector3i] = [
		Vector3i.LEFT, Vector3i.ZERO, Vector3i.RIGHT, Vector3i(2, 1, 0),
		Vector3i(3, 0, 0), Vector3i(4, 0, 0), Vector3i(5, 0, 0),
	]
	var blocks: Array[int] = [
		VoxelWorldData.Block.MINER, VoxelWorldData.Block.BELT,
		VoxelWorldData.Block.BELT_UP_EAST, VoxelWorldData.Block.BELT,
		VoxelWorldData.Block.BELT_DOWN_EAST, VoxelWorldData.Block.BELT, VoxelWorldData.Block.CHEST,
	]
	for index: int in range(cells.size()):
		_place(logistics, cells[index], blocks[index], Vector3i.RIGHT)
	logistics.advance(STEP)
	var reference: RefCounted = _reference(logistics)
	_enable(logistics)
	assert_int(logistics.work_stats().get("transport_legacy_belts", -1)).is_equal(0)
	assert_int(logistics.work_stats().get("transport_slope_belts", -1)).is_equal(2)
	for tick: int in range(360):
		var before: Dictionary = logistics.save_state()
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)
		assert_int(logistics.total_ore()).is_equal(
			_total_saved(before) + Replay.production_between(before, logistics.logic_tick())
		)
		if tick % 19 == 0:
			_compare_prediction(logistics, reference, Vector3i.ZERO)
	assert_int(logistics.ore_count(cells[-1])).is_greater(0)


func test_merge_blockage_and_added_outlet_resume_against_reference() -> void:
	var logistics: LogisticsData = _merges(0.17)
	assert_bool(logistics._world.break_block(Vector3i(8, 0, 0))).is_true()
	logistics.advance(STEP)
	var reference: RefCounted = _reference(logistics)
	_enable(logistics)
	for tick: int in range(80):
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)
	_place(logistics, Vector3i(8, 0, 0), VoxelWorldData.Block.CHEST, Vector3i.RIGHT)
	assert_bool(reference.call("set_direction", Vector3i(8, 0, 0), Vector3i.RIGHT)).is_true()
	logistics.advance(STEP * 0.1)
	reference.call("advance", STEP * 0.1)
	_compare(logistics, reference)
	_enable(logistics)
	for tick: int in range(120):
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)
	assert_int(logistics.ore_count(Vector3i(8, 0, 0))).is_greater(0)


func test_long_merge_network_common_ticks_do_not_visit_existing_ores() -> void:
	for count: int in [1000, 10000]:
		var length: int = 100
		var lanes: int = count / length
		var world: VoxelWorldData = VoxelWorldData.new()
		assert_bool(world.generate_flat(Vector3i(-4, -4, -4), Vector3i(104, 8, 100))).is_true()
		var logistics: LogisticsData = LogisticsData.new()
		logistics.bind_world(world, INF, 1)
		for lane: int in range(lanes):
			for x: int in range(length):
				var cell: Vector3i = Vector3i(x, (lane / 32) * 2, (lane % 32) * 3)
				_place(logistics, cell, VoxelWorldData.Block.BELT, Vector3i.RIGHT)
		var midpoint: int = length / 2
		_place(logistics, Vector3i(midpoint, 0, 1), VoxelWorldData.Block.MINER, Vector3i.FORWARD)
		logistics.advance(STEP)
		var state: Dictionary = logistics.save_state()
		var rows: Array = state["machines"]
		assert_int(rows.size()).is_equal(count + 1)
		if rows.size() != count + 1:
			return
		for index: int in range(count):
			rows[index]["ores"] = [{"id": index + 1, "incoming": Vector3i.RIGHT, "progress": 0.1}]
			rows[index]["quantity"] = 1
			rows[index]["eligible"] = 0
		state["next_id"] = count + 1
		assert_bool(logistics.restore_state(state)).is_true()
		_enable(logistics)
		assert_int(logistics.work_stats().get("transport_line_count", -1)).is_equal(lanes + 1)
		var before: Dictionary[String, int] = logistics.work_stats()
		logistics.advance(STEP * 8)
		var after: Dictionary[String, int] = logistics.work_stats()
		assert_int(after["transport_common_ticks"] - before["transport_common_ticks"]).is_equal(8)
		assert_int(after["transport_ore_visits"] - before["transport_ore_visits"]).is_equal(0)
		assert_int(after["transport_machine_visits"] - before["transport_machine_visits"]).is_equal(0)
		assert_int(after["production_schedule_count"]).is_equal(0)
		assert_int(after["production_deadline_checks"] - before["production_deadline_checks"]).is_equal(0)
		assert_int(after["transport_fallback_work"] - before["transport_fallback_work"]).is_equal(0)
		assert_int(after["transfer_calls"]).is_equal(0)
		assert_int(logistics.total_ore()).is_equal(count)
		assert_float(logistics.belt_ores(Vector3i(midpoint, 0, 0))[0].progress).is_equal_approx(
			0.1 + 8.0 / 30.0, 0.000001
		)


func _total_saved(state: Dictionary) -> int:
	var total: int = 0
	var rows: Array = state["machines"]
	for row: Dictionary in rows:
		total += row["quantity"]
	return total
