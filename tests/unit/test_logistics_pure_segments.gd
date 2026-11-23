extends GdUnitTestSuite

const Reference = preload("res://tests/support/logistics_t03_reference.gd")
const Replay = preload("res://tests/support/logistics_replay.gd")
const STEP: float = LogisticsData.LOGIC_STEP


func _enable(logistics: LogisticsData) -> bool:
	var exists: bool = logistics.has_method("enable_pure_segments")
	assert_bool(exists).override_failure_message("Pure belt segments are not implemented.").is_true()
	if not exists:
		return false
	assert_bool(logistics.call("enable_pure_segments")).is_true()
	return true


func _place(logistics: LogisticsData, cell: Vector3i, block: int, direction: Vector3i) -> void:
	assert_bool(logistics._world.place_block(cell, block)).is_true()
	assert_bool(logistics.set_direction(cell, direction)).is_true()


func _line(count: int, density: int, chest: bool = true) -> LogisticsData:
	var world: VoxelWorldData = VoxelWorldData.new()
	assert_bool(world.generate_flat(Vector3i(-2, -4, -2), Vector3i(count + 3, 3, 3))).is_true()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world)
	for x: int in range(count):
		_place(logistics, Vector3i(x, 0, 0), VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	if chest:
		_place(logistics, Vector3i(count, 0, 0), VoxelWorldData.Block.CHEST, Vector3i.RIGHT)
	assert_bool(logistics.prefill_belts()).is_true()
	var state: Dictionary = logistics.save_state()
	var rows: Array = state["machines"]
	for index: int in range(count):
		var row: Dictionary = rows[index]
		var ores: Array = row["ores"]
		if density == 0 or (density == 1 and index % 3 != 0):
			ores.clear()
		elif density == 1:
			ores.resize(1)
			ores[0]["progress"] = 0.2317
		elif density == 2:
			ores[0]["progress"] = 0.8173
			ores[1]["progress"] = 0.3173
		row["quantity"] = ores.size()
		row["eligible"] = ores.size()
		row["cursor"] = index % 3
	assert_bool(logistics.restore_state(state)).is_true()
	return logistics


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
	var rows: Array = logistics.save_state()["machines"]
	for row: Dictionary in rows:
		assert_int(logistics.ore_count(row["cell"])).is_equal(row["quantity"])


func _prediction(logistics: LogisticsData, reference: RefCounted, cells: Array[Vector3i]) -> void:
	var before: Dictionary = logistics.save_state()
	var expected: Array = reference.call("sample_state", STEP * 0.8)
	var actual: Array[LogisticsOreQueue] = logistics.sample_cells(cells, STEP * 0.8)
	for queue: LogisticsOreQueue in actual:
		for row: Dictionary in expected:
			if row["cell"] != queue.cell:
				continue
			var ores: Array[Dictionary] = []
			for ore: LogisticsOre in queue.ores:
				ores.append({"id": ore.id, "incoming": ore.incoming_direction, "progress": ore.progress})
			var difference: Dictionary = Replay.first_difference(row["ores"], ores)
			assert_bool(difference.is_empty()).override_failure_message(var_to_str(difference)).is_true()
	assert_bool(logistics.save_state() == before).is_true()


func test_empty_sparse_dense_and_blocked_lines_match_reference_across_internal_transfers() -> void:
	for density: int in [0, 1, 2, 3]:
		for chest: bool in [false, true]:
			var logistics: LogisticsData = _line(12, density, chest)
			var reference: RefCounted = _reference(logistics)
			if not _enable(logistics):
				return
			for tick: int in range(180):
				logistics.advance(STEP)
				reference.call("advance", STEP)
				_compare(logistics, reference)
				if tick % 13 == 0:
					_prediction(logistics, reference, [Vector3i.ZERO, Vector3i(6, 0, 0), Vector3i(11, 0, 0)])


func test_synchronous_internal_crossings_do_not_expand_long_repeated_lines() -> void:
	for count: int in [32, 120]:
		var logistics: LogisticsData = _line(count, 2)
		var reference: RefCounted = _reference(logistics)
		if not _enable(logistics):
			return
		var before: Dictionary[String, int] = logistics.work_stats()
		var maximum_work: int = 0
		for tick: int in range(150):
			logistics.advance(STEP)
			maximum_work = maxi(maximum_work, logistics.work_stats()["advance"])
			reference.call("advance", STEP)
			_compare(logistics, reference)
		var after: Dictionary[String, int] = logistics.work_stats()
		assert_int(after.get("pure_segment_internal_transfers", 0)).is_greater(count)
		assert_int(after.get("pure_segment_materialized_cells", 0) - before.get("pure_segment_materialized_cells", 0)).is_equal(0)
		assert_int(after.get("pure_segment_fallback_ticks", 0) - before.get("pure_segment_fallback_ticks", 0)).is_equal(0)
		assert_int(maximum_work).is_less_equal(600)


func test_off_grid_progress_and_incoming_directions_settle_without_changing_rules() -> void:
	for seed_value: int in [7, 42, 601, 20261110]:
		var logistics: LogisticsData = _line(12, 2)
		var random: RandomNumberGenerator = RandomNumberGenerator.new()
		random.seed = seed_value
		var state: Dictionary = logistics.save_state()
		var rows: Array = state["machines"]
		for index: int in range(12):
			var row: Dictionary = rows[index]
			var ores: Array = row["ores"]
			var count: int = random.randi_range(0, 2)
			ores.resize(count)
			if count > 0:
				ores[0]["progress"] = random.randf_range(0.5 if count == 2 else 0.0, 1.0)
				ores[0]["incoming"] = Vector3i.FORWARD if index % 2 == 0 else Vector3i.RIGHT
			if count == 2:
				ores[1]["progress"] = random.randf_range(0.0, float(ores[0]["progress"]) - 0.5)
				ores[1]["incoming"] = Vector3i.LEFT if index % 2 == 0 else Vector3i.RIGHT
			row["quantity"] = count
			row["eligible"] = random.randi_range(0, count)
			row["last_output"] = 0 if index % 2 == 0 else -1
		assert_bool(logistics.restore_state(state)).is_true()
		var reference: RefCounted = _reference(logistics)
		if not _enable(logistics):
			return
		for tick: int in range(150):
			logistics.advance(STEP * 0.3)
			reference.call("advance", STEP * 0.3)
			_compare(logistics, reference)
			_prediction(logistics, reference, [Vector3i(5, 0, 0)])
			logistics.advance(STEP * 0.7)
			reference.call("advance", STEP * 0.7)
			_compare(logistics, reference)


func test_merged_lines_keep_remainder_discard_and_arrival_eligibility() -> void:
	var logistics: LogisticsData = _line(40, 0)
	var state: Dictionary = logistics.save_state()
	var rows: Array = state["machines"]
	rows[10]["ores"] = [{"id": 1, "incoming": Vector3i.RIGHT, "progress": 0.997}]
	rows[10]["quantity"] = 1
	rows[10]["eligible"] = 1
	assert_bool(logistics.restore_state(state)).is_true()
	if not _enable(logistics):
		return
	logistics.advance(STEP)
	rows = logistics.save_state()["machines"]
	assert_int(rows[10]["quantity"]).is_equal(0)
	assert_int(rows[11]["quantity"]).is_equal(1)
	assert_int(rows[12]["quantity"]).is_equal(0)
	assert_float(rows[11]["ores"][0]["progress"]).is_equal(0.0)
	assert_int(rows[11]["eligible"]).is_equal(0)
	assert_int(rows[10]["last_output"]).is_equal(1)
	logistics.advance(STEP)
	rows = logistics.save_state()["machines"]
	assert_int(rows[11]["eligible"]).is_equal(1)
	assert_float(rows[11]["ores"][0]["progress"]).is_equal_approx(1.0 / 30.0, 0.000001)


func test_edit_unblocks_line_and_both_save_formats_continue_from_virtual_state() -> void:
	for packed: bool in [false, true]:
		var logistics: LogisticsData = _line(16, 3, false)
		var reference: RefCounted = _reference(logistics)
		if not _enable(logistics):
			return
		for tick: int in range(35):
			logistics.advance(STEP)
			reference.call("advance", STEP)
			_compare(logistics, reference)
		_place(logistics, Vector3i(16, 0, 0), VoxelWorldData.Block.CHEST, Vector3i.RIGHT)
		reference.call("set_direction", Vector3i(16, 0, 0), Vector3i.RIGHT)
		for tick: int in range(40):
			logistics.advance(STEP)
			reference.call("advance", STEP)
			_compare(logistics, reference)
		logistics.advance(STEP * 0.4)
		reference.call("advance", STEP * 0.4)
		var before: Dictionary = logistics.save_state()
		var invalid: Dictionary = before.duplicate(true)
		invalid["machines"][0]["quantity"] = -1
		assert_bool(logistics.restore_state(invalid)).is_false()
		assert_bool(logistics.save_state() == before).is_true()
		var restored: LogisticsData = LogisticsData.new()
		restored.bind_world(logistics._world)
		if not _enable(restored):
			return
		assert_bool(restored.restore_state(logistics.save_packed_state() if packed else before)).is_true()
		for tick: int in range(80):
			logistics.advance(STEP)
			restored.advance(STEP)
			reference.call("advance", STEP)
			_compare(logistics, reference)
			_compare(restored, reference)
		assert_bool(logistics.set_direction(Vector3i(7, 0, 0), Vector3i.FORWARD)).is_true()
		assert_bool(reference.call("set_direction", Vector3i(7, 0, 0), Vector3i.FORWARD)).is_true()
		assert_bool(logistics._world.break_block(Vector3i(4, 0, 0))).is_true()
		for tick: int in range(40):
			logistics.advance(STEP)
			reference.call("advance", STEP)
			_compare(logistics, reference)


func test_pure_segments_stop_at_merges_and_preserve_turns_slopes_and_inventory_boundaries() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	assert_bool(world.generate_flat(Vector3i(-4, -4, -4), Vector3i(12, 4, 12))).is_true()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, 0.17, 3)
	_place(logistics, Vector3i.LEFT, VoxelWorldData.Block.MINER, Vector3i.RIGHT)
	for x: int in range(5):
		_place(logistics, Vector3i(x, 0, 0), VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	_place(logistics, Vector3i(5, 0, 0), VoxelWorldData.Block.BELT_UP_EAST, Vector3i.RIGHT)
	_place(logistics, Vector3i(6, 1, 0), VoxelWorldData.Block.BELT, Vector3i.BACK)
	for z: int in range(1, 5):
		_place(logistics, Vector3i(6, 1, z), VoxelWorldData.Block.BELT, Vector3i.BACK)
	_place(logistics, Vector3i(6, 1, 5), VoxelWorldData.Block.CHEST, Vector3i.BACK)
	_place(logistics, Vector3i(2, 0, 4), VoxelWorldData.Block.MINER, Vector3i.FORWARD)
	for z: int in range(1, 4):
		_place(logistics, Vector3i(2, 0, z), VoxelWorldData.Block.BELT, Vector3i.FORWARD)
	logistics.advance(STEP)
	var reference: RefCounted = _reference(logistics)
	if not _enable(logistics):
		return
	assert_int(logistics.work_stats().get("pure_segment_count", 0)).is_greater_equal(3)
	for tick: int in range(420):
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)
		if tick % 17 == 0:
			_prediction(logistics, reference, [Vector3i(2, 0, 0), Vector3i(6, 1, 0)])
	assert_int(logistics.ore_count(Vector3i(6, 1, 5))).is_greater(0)


func test_cyclic_region_uses_original_rules_while_disconnected_line_stays_merged() -> void:
	var logistics: LogisticsData = _line(12, 3)
	var ring: Array[Vector3i] = [Vector3i(2, 0, 1), Vector3i(3, 0, 1), Vector3i(3, 0, 2), Vector3i(2, 0, 2)]
	for index: int in range(ring.size()):
		_place(logistics, ring[index], VoxelWorldData.Block.BELT, ring[(index + 1) % ring.size()] - ring[index])
	var state: Dictionary = logistics.save_state()
	var next_id: int = state["next_id"]
	for row: Dictionary in state["machines"]:
		var index: int = ring.find(row["cell"])
		if index < 0:
			continue
		var incoming: Vector3i = ring[index] - ring[(index + 3) % ring.size()]
		row["quantity"] = 2
		row["eligible"] = 2
		row["ores"] = [{"id": next_id, "incoming": incoming, "progress": 1.0},
			{"id": next_id + 1, "incoming": incoming, "progress": 0.5}]
		next_id += 2
	state["next_id"] = next_id
	assert_bool(logistics.restore_state(state)).is_true()
	var reference: RefCounted = _reference(logistics)
	if not _enable(logistics):
		return
	for tick: int in range(120):
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)
	var stats: Dictionary[String, int] = logistics.work_stats()
	assert_int(stats.get("pure_segment_count", 0)).is_greater(0)
	assert_int(stats.get("pure_segment_fallback_ticks", 0)).is_greater(0)
	assert_int(stats.get("pure_segment_internal_transfers", 0)).is_greater(0)


func test_enabling_before_construction_and_world_reset_keeps_future_segments_active() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	assert_bool(world.generate_flat()).is_true()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, 0.05, 2)
	if not _enable(logistics):
		return
	for cycle: int in range(2):
		_place(logistics, Vector3i.LEFT, VoxelWorldData.Block.MINER, Vector3i.RIGHT)
		for x: int in range(8):
			_place(logistics, Vector3i(x, 0, 0), VoxelWorldData.Block.BELT, Vector3i.RIGHT)
		_place(logistics, Vector3i(8, 0, 0), VoxelWorldData.Block.CHEST, Vector3i.RIGHT)
		var reference: RefCounted = _reference(logistics)
		for tick: int in range(330):
			logistics.advance(STEP)
			reference.call("advance", STEP)
			_compare(logistics, reference)
		assert_int(logistics.work_stats().get("pure_segment_internal_transfers", 0)).is_greater(0)
		assert_int(logistics.ore_count(Vector3i(8, 0, 0))).is_greater(0)
		world.generate_flat()


func test_long_running_full_segment_keeps_identity_storage_bounded_without_queue_copy_ticks() -> void:
	var logistics: LogisticsData = _line(120, 3)
	var filled: Dictionary = logistics.save_state()
	logistics.configure_miners(0.05, 2)
	_place(logistics, Vector3i.LEFT, VoxelWorldData.Block.MINER, Vector3i.RIGHT)
	logistics.advance(STEP)
	# Start every belt in the same phase, with supply already waiting. An
	# empty newly placed miner introduces a travelling hole and many runs;
	# that is a different workload from a long repeated full segment.
	var settled: Dictionary = logistics.save_state()
	for row: Dictionary in settled["machines"]:
		if row["block"] == VoxelWorldData.Block.MINER:
			row["quantity"] = 100000
			row["eligible"] = 100000
		elif VoxelWorldData.is_belt(row["block"]):
			for original: Dictionary in filled["machines"]:
				if original["cell"] == row["cell"]:
					row["ores"] = original["ores"].duplicate(true)
					break
			row["quantity"] = 2
			row["eligible"] = 2
	assert_bool(logistics.restore_state(settled)).is_true()
	var reference: RefCounted = _reference(logistics)
	if not _enable(logistics):
		return
	var maximum_work: int = 0
	var maximum_runs: int = 0
	var maximum_tick: int = 0
	for tick: int in range(18000):
		logistics.advance(STEP)
		reference.call("advance", STEP)
		var current: Dictionary[String, int] = logistics.work_stats()
		if current["advance"] > maximum_work:
			maximum_work = current["advance"]
			maximum_runs = current["pure_segment_runs"]
			maximum_tick = tick
		if tick % 257 == 0:
			_compare(logistics, reference)
	_compare(logistics, reference)
	var stats: Dictionary[String, int] = logistics.work_stats()
	assert_int(logistics.ore_count(Vector3i(120, 0, 0))).is_greater(1024)
	assert_int(stats.get("pure_segment_identity_capacity", -1)).is_equal(240)
	print("LONG_SEGMENT_PEAK ", maximum_work, " runs=", maximum_runs, " tick=", maximum_tick)
	# A full 240-identity copy must exceed this budget even when R remains 1.
	assert_int(maximum_runs).is_equal(1)
	assert_int(maximum_work).is_less_equal(200)


func test_oscillating_candidate_and_full_queries_reuse_prediction_slots_and_release_removed_rows() -> void:
	var logistics: LogisticsData = _line(6, 0)
	logistics.configure_miners(0.6, 1)
	_place(logistics, Vector3i.LEFT, VoxelWorldData.Block.MINER, Vector3i.RIGHT)
	logistics.advance(STEP)
	if not _enable(logistics):
		return
	var candidates: Array[Vector3i] = [Vector3i(2, 0, 0)]
	for tick: int in range(1500):
		logistics.advance(STEP)
		logistics.sample_cells(candidates, STEP * 0.5)
		logistics.belt_ores(candidates[0], STEP * 0.5)
	var before: Dictionary[String, int] = logistics.work_stats()
	assert_int(before["sample_region_cache_ore_slots"]).is_less_equal(2)
	assert_int(before["sample_region_ore_creations"]).is_less_equal(2)
	assert_int(before["cache_ore_slots"]).is_less_equal(12)
	assert_int(before["cache_ore_creations"]).is_less_equal(12)
	assert_bool(logistics._world.break_block(candidates[0])).is_true()
	var removed: Dictionary[String, int] = logistics.work_stats()
	assert_int(removed["sample_region_cache_ore_slots"]).is_equal(0)
	assert_int(removed["cache_ore_slots"]).is_less(before["cache_ore_slots"])
	logistics.bind_world(logistics._world)
	assert_int(logistics.work_stats()["cache_ore_slots"]).is_equal(0)


func test_rotation_reports_synchronous_segment_materialization_work() -> void:
	var logistics: LogisticsData = _line(12, 3)
	if not _enable(logistics):
		return
	logistics.advance(STEP * 4.0)
	var before: Dictionary[String, int] = logistics.work_stats()
	assert_bool(logistics.set_direction(Vector3i(5, 0, 0), Vector3i.BACK)).is_true()
	var after: Dictionary[String, int] = logistics.work_stats()
	assert_int(after.get("edit", 0)).is_greater(12)
	assert_int(after.get("pure_segment_materialize_work", 0)).is_greater(
		before.get("pure_segment_materialize_work", 0))


func test_chest_edits_preserve_segments_at_boundary_and_partial_ticks() -> void:
	const COUNT: int = 24
	for density: int in [1, 3]:
		for fraction: float in [0.0, 0.4]:
			var logistics: LogisticsData = _line(COUNT, density)
			var reference: RefCounted = _reference(logistics)
			if not _enable(logistics):
				return
			logistics.advance(STEP * 35.0)
			reference.call("advance", STEP * 35.0)
			if fraction > 0.0:
				logistics.advance(STEP * fraction)
				reference.call("advance", STEP * fraction)
			_compare(logistics, reference)
			for direction: Vector3i in [Vector3i.FORWARD, Vector3i.RIGHT]:
				var before: Dictionary[String, int] = logistics.work_stats()
				assert_bool(logistics.set_direction(Vector3i(COUNT, 0, 0), direction)).is_true()
				assert_bool(reference.call("set_direction", Vector3i(COUNT, 0, 0), direction)).is_true()
				var edited: Dictionary[String, int] = logistics.work_stats()
				assert_int(edited["pure_segment_materialized_cells"] - before["pure_segment_materialized_cells"]).is_equal(0)
				_compare(logistics, reference)
				_prediction(logistics, reference, [Vector3i(COUNT - 1, 0, 0)])
				logistics.advance(STEP)
				reference.call("advance", STEP)
				_compare(logistics, reference)
				var after: Dictionary[String, int] = logistics.work_stats()
				assert_int(after["pure_segment_materialized_cells"] - before["pure_segment_materialized_cells"]).is_equal(0)
				assert_int(after["transport_rebuilt_machines"] - before["transport_rebuilt_machines"]).is_equal(0)
				for tick: int in range(45):
					logistics.advance(STEP)
					reference.call("advance", STEP)
					_compare(logistics, reference)


func test_repeated_pending_edits_keep_single_expansion_and_save_continuity() -> void:
	const COUNT: int = 32
	for fraction: float in [0.0, 0.4]:
		var logistics: LogisticsData = _line(COUNT, 3)
		logistics.configure_miners(0.05, 2)
		_place(logistics, Vector3i.LEFT, VoxelWorldData.Block.MINER, Vector3i.RIGHT)
		logistics.advance(STEP)
		var state: Dictionary = logistics.save_state()
		for row: Dictionary in state["machines"]:
			if row["block"] == VoxelWorldData.Block.MINER:
				row["quantity"] = 1000
				row["eligible"] = 1000
		assert_bool(logistics.restore_state(state)).is_true()
		var reference: RefCounted = _reference(logistics)
		if not _enable(logistics):
			return
		logistics.advance(STEP * 31.0)
		reference.call("advance", STEP * 31.0)
		if fraction > 0.0:
			logistics.advance(STEP * fraction)
			reference.call("advance", STEP * fraction)
		var before: Dictionary[String, int] = logistics.work_stats()
		for direction: Vector3i in [Vector3i.FORWARD, Vector3i.LEFT, Vector3i.RIGHT]:
			assert_bool(logistics.set_direction(Vector3i(16, 0, 0), direction)).is_true()
			assert_bool(reference.call("set_direction", Vector3i(16, 0, 0), direction)).is_true()
			_compare(logistics, reference)
		logistics.advance(STEP * 0.2)
		reference.call("advance", STEP * 0.2)
		_compare(logistics, reference)
		var restored_states: Array[LogisticsData] = []
		for packed: bool in [false, true]:
			var restored: LogisticsData = LogisticsData.new()
			restored.bind_world(logistics._world)
			if not _enable(restored):
				return
			assert_bool(restored.restore_state(logistics.save_packed_state() if packed else logistics.save_state())).is_true()
			_compare(restored, reference)
			restored_states.append(restored)
		logistics.advance(STEP * 0.8)
		reference.call("advance", STEP * 0.8)
		for restored: LogisticsData in restored_states:
			restored.advance(STEP * 0.8)
			_compare(restored, reference)
		_compare(logistics, reference)
		var after: Dictionary[String, int] = logistics.work_stats()
		assert_int(after["pure_segment_materialized_cells"] - before["pure_segment_materialized_cells"]).is_equal(COUNT)
		for tick: int in range(45):
			logistics.advance(STEP)
			reference.call("advance", STEP)
			_compare(logistics, reference)
			for restored: LogisticsData in restored_states:
				restored.advance(STEP)
				_compare(restored, reference)


func test_inventory_rotations_keep_production_merges_pending_saves_and_predictions() -> void:
	for fraction: float in [0.0, 0.4]:
		var logistics: LogisticsData = _line(16, 2)
		logistics.configure_miners(0.05, 2)
		_place(logistics, Vector3i.LEFT, VoxelWorldData.Block.MINER, Vector3i.RIGHT)
		_place(logistics, Vector3i(5, 0, 1), VoxelWorldData.Block.MINER, Vector3i.FORWARD)
		logistics.advance(STEP)
		var state: Dictionary = logistics.save_state()
		for row: Dictionary in state["machines"]:
			if row["block"] == VoxelWorldData.Block.MINER:
				row["quantity"] = 1000
				row["eligible"] = 1000
		assert_bool(logistics.restore_state(state)).is_true()
		var reference: RefCounted = _reference(logistics)
		if not _enable(logistics):
			return
		logistics.advance(STEP * (31.0 + fraction))
		reference.call("advance", STEP * (31.0 + fraction))
		var before: Dictionary[String, int] = logistics.work_stats()
		for cell: Vector3i in [Vector3i.LEFT, Vector3i(16, 0, 0)]:
			for direction: Vector3i in [Vector3i.BACK, Vector3i.LEFT, Vector3i.RIGHT]:
				assert_bool(logistics.set_direction(cell, direction)).is_true()
				assert_bool(reference.call("set_direction", cell, direction)).is_true()
				_compare(logistics, reference)
				_prediction(logistics, reference, [Vector3i.ZERO, Vector3i(5, 0, 0), Vector3i(15, 0, 0)])
		var copies: Array[LogisticsData] = []
		for packed: bool in [false, true]:
			var restored: LogisticsData = LogisticsData.new()
			restored.bind_world(logistics._world, 0.05, 2)
			assert_bool(restored.restore_state(logistics.save_packed_state() if packed else logistics.save_state())).is_true()
			if not _enable(restored):
				return
			copies.append(restored)
		for tick: int in range(65):
			if tick % 9 == 0:
				var direction: Vector3i = Vector3i.BACK if tick % 18 == 0 else Vector3i.RIGHT
				for cell: Vector3i in [Vector3i.LEFT, Vector3i(16, 0, 0)]:
					assert_bool(logistics.set_direction(cell, direction)).is_true()
					assert_bool(reference.call("set_direction", cell, direction)).is_true()
					for restored: LogisticsData in copies:
						assert_bool(restored.set_direction(cell, direction)).is_true()
			var delta: float = STEP * (0.2 if tick % 2 == 0 else 0.8)
			logistics.advance(delta)
			reference.call("advance", delta)
			_compare(logistics, reference)
			for restored: LogisticsData in copies:
				restored.advance(delta)
				_compare(restored, reference)
		var after: Dictionary[String, int] = logistics.work_stats()
		assert_int(after["pure_segment_materialized_cells"] - before["pure_segment_materialized_cells"]).is_equal(0)
		assert_int(after["transport_rebuilt_machines"] - before["transport_rebuilt_machines"]).is_equal(0)


func test_supplemental_inventory_edit_preserves_per_cell_output_and_eligibility() -> void:
	var logistics: LogisticsData = _line(12, 3)
	var state: Dictionary = logistics.save_state()
	for row: Dictionary in state["machines"]:
		if VoxelWorldData.is_belt(row["block"]):
			row["last_output"] = 0 if int(row["cell"].x) % 2 == 0 else -1
			row["eligible"] = 1
	assert_bool(logistics.restore_state(state)).is_true()
	var reference: RefCounted = _reference(logistics)
	if not _enable(logistics):
		return
	assert_bool(logistics.set_direction(Vector3i(12, 0, 0), Vector3i.FORWARD)).is_true()
	assert_bool(reference.call("set_direction", Vector3i(12, 0, 0), Vector3i.FORWARD)).is_true()
	assert_bool(logistics.set_direction(Vector3i(12, 0, 0), Vector3i.RIGHT)).is_true()
	assert_bool(reference.call("set_direction", Vector3i(12, 0, 0), Vector3i.RIGHT)).is_true()
	logistics.advance(STEP * 0.2)
	reference.call("advance", STEP * 0.2)
	_compare(logistics, reference)
	for direction: Vector3i in [Vector3i.FORWARD, Vector3i.RIGHT]:
		assert_bool(logistics.set_direction(Vector3i(12, 0, 0), direction)).is_true()
		assert_bool(reference.call("set_direction", Vector3i(12, 0, 0), direction)).is_true()
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)


func test_inventory_rotation_cycle_and_pending_removal_fall_back_with_old_graph_movement() -> void:
	for fraction: float in [0.0, 0.4]:
		var world: VoxelWorldData = VoxelWorldData.new()
		assert_bool(world.generate_flat(Vector3i(-3, -4, -3), Vector3i(6, 3, 5))).is_true()
		var logistics: LogisticsData = LogisticsData.new()
		logistics.bind_world(world)
		var path: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(1, 0, 1), Vector3i(0, 0, 1),
			Vector3i(-1, 0, 1), Vector3i(-1, 0, 0), Vector3i.ZERO]
		for index: int in range(path.size() - 1):
			_place(logistics, path[index], VoxelWorldData.Block.BELT, path[index + 1] - path[index])
		_place(logistics, Vector3i.ZERO, VoxelWorldData.Block.CHEST, Vector3i.BACK)
		assert_bool(logistics.prefill_belts()).is_true()
		var reference: RefCounted = _reference(logistics)
		if not _enable(logistics):
			return
		logistics.advance(STEP * (2.0 + fraction))
		reference.call("advance", STEP * (2.0 + fraction))
		var before: Dictionary[String, int] = logistics.work_stats()
		assert_bool(logistics.set_direction(Vector3i.ZERO, Vector3i.RIGHT)).is_true()
		assert_bool(reference.call("set_direction", Vector3i.ZERO, Vector3i.RIGHT)).is_true()
		for tick: int in range(40):
			logistics.advance(STEP)
			reference.call("advance", STEP)
			_compare(logistics, reference)
		assert_int(logistics.work_stats()["pure_segment_materialized_cells"]).is_greater(
			before["pure_segment_materialized_cells"])
		assert_int(logistics.work_stats()["pure_segment_fallback_ticks"]).is_greater(0)
		# Break the cycle, then invalidate a retained rotation before it settles.
		assert_bool(logistics.set_direction(Vector3i.ZERO, Vector3i.BACK)).is_true()
		assert_bool(reference.call("set_direction", Vector3i.ZERO, Vector3i.BACK)).is_true()
		logistics.advance(STEP)
		reference.call("advance", STEP)
		assert_bool(logistics.set_direction(Vector3i.ZERO, Vector3i.RIGHT)).is_true()
		assert_bool(reference.call("set_direction", Vector3i.ZERO, Vector3i.RIGHT)).is_true()
		assert_bool(world.break_block(path[0])).is_true()
		for tick: int in range(40):
			logistics.advance(STEP)
			reference.call("advance", STEP)
			_compare(logistics, reference)


func test_inventory_cross_region_join_and_placement_after_disconnection_cancel_retention() -> void:
	var logistics: LogisticsData = _line(12, 3)
	_place(logistics, Vector3i(12, 0, 1), VoxelWorldData.Block.BELT, Vector3i.BACK)
	_place(logistics, Vector3i(12, 0, 2), VoxelWorldData.Block.CHEST, Vector3i.BACK)
	var reference: RefCounted = _reference(logistics)
	if not _enable(logistics):
		return
	logistics.advance(STEP * 32.4)
	reference.call("advance", STEP * 32.4)
	assert_bool(logistics.set_direction(Vector3i(12, 0, 0), Vector3i.BACK)).is_true()
	assert_bool(reference.call("set_direction", Vector3i(12, 0, 0), Vector3i.BACK)).is_true()
	for tick: int in range(45):
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)
	assert_int(logistics.ore_count(Vector3i(12, 0, 2))).is_greater(0)
	assert_bool(logistics.set_direction(Vector3i(12, 0, 0), Vector3i.LEFT)).is_true()
	assert_bool(reference.call("set_direction", Vector3i(12, 0, 0), Vector3i.LEFT)).is_true()
	logistics.advance(STEP)
	reference.call("advance", STEP)
	# The old scheduler can now own multiple disconnected pieces.
	assert_bool(logistics.set_direction(Vector3i(12, 0, 0), Vector3i.RIGHT)).is_true()
	assert_bool(reference.call("set_direction", Vector3i(12, 0, 0), Vector3i.RIGHT)).is_true()
	_place(logistics, Vector3i(10, 0, 1), VoxelWorldData.Block.MINER, Vector3i.FORWARD)
	assert_bool(reference.call("set_direction", Vector3i(10, 0, 1), Vector3i.FORWARD)).is_true()
	for tick: int in range(45):
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)
		_prediction(logistics, reference, [Vector3i(10, 0, 0), Vector3i(12, 0, 1)])
