extends GdUnitTestSuite

const Reference = preload("res://tests/support/logistics_t03_reference.gd")
const Replay = preload("res://tests/support/logistics_replay.gd")
const STEP: float = LogisticsData.LOGIC_STEP


func _cell(index: int) -> Vector3i:
	var lane: int = index / 100
	return Vector3i(index % 100 if lane % 2 == 0 else 99 - index % 100, 0, lane)


func _line(count: int, progress: float, distant: int = 0) -> LogisticsData:
	var world: VoxelWorldData = VoxelWorldData.new()
	assert_bool(world.generate_flat(Vector3i(-2, -4, -2), Vector3i(104, 8, maxi(14, count / 100 + 2)))).is_true()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, INF, 1)
	for index: int in range(count):
		var cell: Vector3i = _cell(index)
		var direction: Vector3i = _cell(index + 1) - cell if index + 1 < count else (
			Vector3i.RIGHT if (index / 100) % 2 == 0 else Vector3i.LEFT)
		assert_bool(world.place_block(cell, VoxelWorldData.Block.BELT)).is_true()
		assert_bool(logistics.set_direction(cell, direction)).is_true()
	for index: int in range(distant):
		var cell: Vector3i = Vector3i(index % 80, 3, 4 + 3 * (index / 80))
		assert_bool(world.place_block(cell, VoxelWorldData.Block.BELT)).is_true()
		assert_bool(logistics.set_direction(cell, Vector3i.RIGHT)).is_true()
	logistics.advance(STEP)
	var state: Dictionary = logistics.save_state()
	var rows: Array = state["machines"]
	for index: int in range(rows.size()):
		rows[index]["ores"] = [{"id": index + 1, "incoming": rows[index]["settled"], "progress": progress}]
		rows[index]["quantity"] = 1
		rows[index]["eligible"] = 1
	state["next_id"] = rows.size() + 1
	assert_bool(logistics.restore_state(state)).is_true()
	assert_bool(logistics.enable_transport_lines()).is_true()
	return logistics


func _reference(logistics: LogisticsData) -> RefCounted:
	var reference: RefCounted = Reference.new()
	reference.call("bind_world", logistics._world)
	assert_bool(reference.call("restore_state", logistics.save_state())).is_true()
	return reference


func _check(logistics: LogisticsData, reference: RefCounted, cells: Array[Vector3i], extra: float) -> void:
	var before: Dictionary = logistics.save_state()
	var expected: Dictionary[Vector3i, Dictionary] = {}
	for row: Dictionary in reference.call("sample_state", extra):
		expected[row["cell"]] = row
	var actual: Array[LogisticsOreQueue] = logistics.sample_cells(cells, extra)
	var seen: Dictionary[Vector3i, bool] = {}
	var position: int = 0
	for cell: Vector3i in cells:
		if seen.has(cell) or not expected.has(cell):
			continue
		seen[cell] = true
		assert_int(actual.size()).is_greater(position)
		if actual.size() <= position:
			return
		var queue: LogisticsOreQueue = actual[position]
		var ores: Array[Dictionary] = []
		for ore: LogisticsOre in queue.ores:
			ores.append({"id": ore.id, "incoming": ore.incoming_direction, "progress": ore.progress})
		var difference: Dictionary = Replay.first_difference(expected[cell], {
			"cell": queue.cell, "direction": queue.direction, "block": queue.block, "ores": ores,
		})
		assert_bool(difference.is_empty()).override_failure_message(var_to_str(difference)).is_true()
		position += 1
	assert_int(actual.size()).is_equal(position)
	assert_dict(logistics.save_state()).is_equal(before)


func test_common_motion_reads_only_candidate_when_connected_line_grows() -> void:
	for count: int in [1000, 10000]:
		var logistics: LogisticsData = _line(count, 0.1)
		logistics.advance(STEP * 3.25)
		var reference: RefCounted = _reference(logistics)
		_check(logistics, reference, [Vector3i.ZERO, Vector3i.ZERO], STEP * 0.5)
		var stats: Dictionary[String, int] = logistics.work_stats()
		assert_int(stats.get("sample_direct_rows", -1)).is_equal(1)
		assert_int(stats.get("sample_dependency_rows", -1)).is_equal(0)
		assert_int(stats["sample"]).is_less_equal(8)
		assert_int(stats["sample_return_ores"]).is_equal(1)
		var solves: int = stats["sample_solves"]
		_check(logistics, reference, [Vector3i.ZERO], STEP * 0.5)
		assert_int(logistics.work_stats().get("sample_prediction_hits", -1)).is_equal(1)
		assert_int(logistics.work_stats()["sample_solves"]).is_equal(solves)


func test_exit_prediction_solves_only_related_region_and_reuses_it() -> void:
	var work: Array[int] = []
	for distant: int in [0, 240]:
		var logistics: LogisticsData = _line(80, 0.99, distant)
		var reference: RefCounted = _reference(logistics)
		_check(logistics, reference, [Vector3i.ZERO], STEP)
		var stats: Dictionary[String, int] = logistics.work_stats()
		assert_int(stats.get("sample_dependency_rows", -1)).is_equal(80)
		assert_int(stats.get("sample_direct_rows", -1)).is_equal(0)
		work.append(stats["sample"])
		var solves: int = stats["sample_solves"]
		_check(logistics, reference, [Vector3i.RIGHT], STEP)
		assert_int(logistics.work_stats()["sample_solves"]).is_equal(solves)
		assert_int(logistics.work_stats().get("sample_prediction_hits", -1)).is_equal(1)
	assert_int(work[0]).is_equal(work[1])


func test_blocked_prediction_reads_candidate_and_release_keeps_hidden_constraint() -> void:
	var logistics: LogisticsData = _line(1000, 0.5)
	var state: Dictionary = logistics.save_state()
	var rows: Array = state["machines"]
	for index: int in range(rows.size()):
		rows[index]["ores"] = [
			{"id": 2 * index + 1, "incoming": rows[index]["settled"], "progress": 1.0},
			{"id": 2 * index + 2, "incoming": rows[index]["settled"], "progress": 0.5},
		]
		rows[index]["quantity"] = 2
		rows[index]["eligible"] = 2
	state["next_id"] = 2 * rows.size() + 1
	assert_bool(logistics.restore_state(state)).is_true()
	logistics.advance(STEP * 2)
	var reference: RefCounted = _reference(logistics)
	_check(logistics, reference, [Vector3i.ZERO], STEP)
	assert_int(logistics.work_stats().get("sample_direct_rows", -1)).is_equal(1)
	assert_int(logistics.work_stats().get("sample_dependency_rows", -1)).is_equal(0)
	var outlet: Vector3i = Vector3i(-1, 0, 9)
	logistics._world.place_block(outlet, VoxelWorldData.Block.CHEST)
	logistics.set_direction(outlet, Vector3i.LEFT)
	reference.call("set_direction", outlet, Vector3i.LEFT)
	_check(logistics, reference, [outlet, Vector3i.ZERO], STEP)
	logistics.advance(STEP * 0.25)
	reference.call("advance", STEP * 0.25)
	_check(logistics, reference, [Vector3i.ZERO, outlet], STEP)


func test_pending_edits_restore_and_public_mutation_do_not_stale_predictions() -> void:
	var logistics: LogisticsData = _line(8, 0.99, 24)
	var reference: RefCounted = _reference(logistics)
	_check(logistics, reference, [Vector3i.ZERO], STEP)
	var changed: Array[LogisticsOreQueue] = logistics.sample_cells([Vector3i.ZERO], STEP)
	changed[0].ores[0].progress = -2.0
	changed[0].ores[0].id = -1
	changed[0].ores.clear()
	_check(logistics, reference, [Vector3i.ZERO], STEP)
	logistics.set_direction(Vector3i.RIGHT, Vector3i.BACK)
	reference.call("set_direction", Vector3i.RIGHT, Vector3i.BACK)
	_check(logistics, reference, [Vector3i.ZERO, Vector3i.RIGHT], STEP)
	logistics._world.break_block(Vector3i(3, 0, 0))
	_check(logistics, reference, [Vector3i(3, 0, 0), Vector3i(2, 0, 0), Vector3i.ZERO], STEP)
	var state: Dictionary = logistics.save_packed_state()
	assert_bool(logistics.restore_state(state)).is_true()
	_check(logistics, reference, [Vector3i.ZERO], STEP)
	var invalid: Dictionary = logistics.save_state()
	invalid["next_id"] = -1
	assert_bool(logistics.restore_state(invalid)).is_false()
	_check(logistics, reference, [Vector3i.ZERO], STEP)
	for extra: float in [NAN, INF, -1.0, 0.0, STEP * 0.4, 100.0]:
		_check(logistics, reference, [Vector3i.ZERO], extra)
		logistics.sample_belts(extra)
		var full_work: int = logistics.work_stats()["sample"]
		_check(logistics, reference, [Vector3i.ZERO], extra)
		logistics.sample_belts(extra)
		assert_int(logistics.work_stats()["sample"]).is_equal(full_work)


func test_uniform_ring_identity_and_clamped_prediction_avoid_full_ring_scan() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world)
	var cells: Array[Vector3i] = [Vector3i.ZERO, Vector3i.RIGHT, Vector3i(1, 0, 1), Vector3i.BACK]
	for index: int in range(4):
		world.place_block(cells[index], VoxelWorldData.Block.BELT)
		logistics.set_direction(cells[index], cells[(index + 1) % 4] - cells[index])
	assert_bool(logistics.prefill_belts()).is_true()
	assert_bool(logistics.enable_transport_lines()).is_true()
	var reference: RefCounted = _reference(logistics)
	for tick: int in range(65):
		for extra: float in [0.0, STEP * 0.5, 100.0]:
			_check(logistics, reference, [Vector3i.ZERO], extra)
			assert_int(logistics.work_stats().get("sample_direct_rows", -1)).is_equal(1)
			assert_int(logistics.work_stats().get("sample_dependency_rows", -1)).is_equal(0)
		logistics.advance(STEP)
		reference.call("advance", STEP)


func test_empty_candidates_and_new_unconnected_facility_do_not_prepare_region() -> void:
	var logistics: LogisticsData = _line(80, 0.99)
	logistics.sample_cells([Vector3i.ZERO], STEP)
	var solves: int = logistics.work_stats()["sample_solves"]
	var empty: Array[Vector3i] = []
	var missing: Array[Vector3i] = [Vector3i(1000, 0, 0)]
	for cells: Array[Vector3i] in [empty, missing]:
		assert_array(logistics.sample_cells(cells, STEP * 0.4)).is_empty()
		assert_int(logistics.work_stats()["sample"]).is_equal(0)
		assert_int(logistics.work_stats().get("sample_dependency_rows", -1)).is_equal(0)
		assert_int(logistics.work_stats()["sample_solves"]).is_equal(solves)
	var cell: Vector3i = Vector3i(40, 3, 8)
	assert_bool(logistics._world.place_block(cell, VoxelWorldData.Block.BELT)).is_true()
	var reference: RefCounted = _reference(logistics)
	_check(logistics, reference, [cell], STEP)
	assert_int(logistics.work_stats().get("sample_direct_rows", -1)).is_equal(1)
	assert_int(logistics.work_stats().get("sample_dependency_rows", -1)).is_equal(0)
	assert_int(logistics.work_stats()["sample_solves"]).is_equal(solves)


func test_slope_and_side_merge_predictions_match_reference_through_edits() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, 0.17, 2)
	var cells: Array[Vector3i] = [
		Vector3i.LEFT, Vector3i.ZERO, Vector3i.RIGHT, Vector3i(2, 0, 0),
		Vector3i(3, 0, 0), Vector3i(4, 0, 0), Vector3i(3, 0, 1),
	]
	var blocks: Array[int] = [
		VoxelWorldData.Block.MINER, VoxelWorldData.Block.BELT_UP_EAST,
		VoxelWorldData.Block.BELT_DOWN_EAST, VoxelWorldData.Block.BELT,
		VoxelWorldData.Block.BELT, VoxelWorldData.Block.CHEST, VoxelWorldData.Block.MINER,
	]
	for index: int in range(cells.size()):
		assert_bool(world.place_block(cells[index], blocks[index])).is_true()
		assert_bool(logistics.set_direction(cells[index],
			Vector3i.RIGHT if index < 6 else Vector3i.FORWARD)).is_true()
	assert_bool(logistics.prefill_belts()).is_true()
	logistics.advance(STEP)
	assert_bool(logistics.enable_transport_lines()).is_true()
	var reference: RefCounted = _reference(logistics)
	for tick: int in range(150):
		if tick == 40:
			assert_bool(logistics.set_direction(cells[3], Vector3i.BACK)).is_true()
			reference.call("set_direction", cells[3], Vector3i.BACK)
		if tick == 70:
			assert_bool(logistics.set_direction(cells[3], Vector3i.RIGHT)).is_true()
			reference.call("set_direction", cells[3], Vector3i.RIGHT)
		for extra: float in [0.0, STEP * 0.7, 100.0]:
			_check(logistics, reference, [cells[1], cells[3]], extra)
		logistics.advance(STEP)
		reference.call("advance", STEP)


func test_prediction_cache_reuses_internal_ores_and_releases_removed_region() -> void:
	var logistics: LogisticsData = _line(80, 0.99)
	var reference: RefCounted = _reference(logistics)
	_check(logistics, reference, [Vector3i.ZERO], STEP)
	var before: Dictionary[String, int] = logistics.work_stats()
	assert_int(before.get("sample_region_cache_rows", -1)).is_equal(80)
	assert_int(before.get("sample_region_cache_ore_slots", -1)).is_equal(80)
	for extra: float in [STEP * 0.25, STEP * 0.75, STEP, STEP * 0.25]:
		_check(logistics, reference, [Vector3i.ZERO], extra)
	var after: Dictionary[String, int] = logistics.work_stats()
	assert_int(after.get("sample_region_queue_creations", -1)).is_equal(
		before.get("sample_region_queue_creations", -2))
	assert_int(after.get("sample_region_ore_creations", -1)).is_equal(
		before.get("sample_region_ore_creations", -2))
	assert_bool(logistics._world.break_block(Vector3i(30, 0, 0))).is_true()
	assert_int(logistics.work_stats().get("sample_region_cache_rows", -1)).is_equal(0)
	_check(logistics, reference, [Vector3i.ZERO], STEP)
	assert_bool(logistics._world.generate_flat()).is_true()
	assert_int(logistics.work_stats().get("sample_region_cache_rows", -1)).is_equal(0)
	assert_int(logistics.work_stats().get("sample_region_cache_ore_slots", -1)).is_equal(0)
