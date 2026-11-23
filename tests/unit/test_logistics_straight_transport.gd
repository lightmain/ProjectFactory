extends GdUnitTestSuite

const Reference = preload("res://tests/support/logistics_t03_reference.gd")
const Replay = preload("res://tests/support/logistics_replay.gd")
const STEP: float = LogisticsData.LOGIC_STEP


func _line(count: int, direction: Vector3i, chest: bool, density: int) -> LogisticsData:
	var world: VoxelWorldData = VoxelWorldData.new()
	var low: Vector3i = Vector3i(-count - 2, -4, -count - 2)
	var high: Vector3i = Vector3i(count + 3, 3, count + 3)
	# Long tests use a thin world to keep cell lookup memory proportional to length.
	if direction == Vector3i.RIGHT:
		low = Vector3i(-2, -4, -2)
		high = Vector3i(count + 3, 3, 3)
	assert_bool(world.generate_flat(low, high)).is_true()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world)
	for index: int in range(count + (1 if chest else 0)):
		var cell: Vector3i = direction * index
		assert_bool(world.place_block(cell, VoxelWorldData.Block.BELT if index < count else VoxelWorldData.Block.CHEST)).is_true()
		assert_bool(logistics.set_direction(cell, direction)).is_true()
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


func _compare(actual: LogisticsData, expected: RefCounted) -> void:
	var difference: Dictionary = Replay.first_difference(
		Replay.canonical_state(expected.call("save_state")),
		Replay.canonical_state(actual.save_state())
	)
	assert_bool(difference.is_empty()).override_failure_message(var_to_str(difference)).is_true()


func _ore_ref_at(logistics: LogisticsData, cell: Vector3i) -> WeakRef:
	var index: int = logistics._topology.index_at(cell)
	return weakref(logistics._topology.machines[index].belt_ores[0])


func test_empty_sparse_and_full_straight_lines_match_frozen_reference_each_tick() -> void:
	for density: int in [0, 1, 2, 3]:
		for direction: Vector3i in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]:
			var logistics: LogisticsData = _line(8, direction, true, density)
			var reference: RefCounted = Reference.new()
			reference.call("bind_world", logistics._world)
			assert_bool(reference.call("restore_state", logistics.save_state())).is_true()
			var initial_total: int = logistics.total_ore()
			assert_bool(logistics.enable_straight_transport()).is_true()
			assert_int(logistics.work_stats().get("straight_line_active", -1)).is_equal(1)
			for tick: int in range(160):
				logistics.advance(STEP)
				reference.call("advance", STEP)
				_compare(logistics, reference)
			assert_int(logistics.total_ore()).is_equal(initial_total)


func test_non_exit_ticks_use_common_offset_without_visiting_long_line_ores() -> void:
	for count: int in [32, 120]:
		var logistics: LogisticsData = _line(count, Vector3i.RIGHT, true, 2)
		var reference: RefCounted = Reference.new()
		reference.call("bind_world", logistics._world)
		assert_bool(reference.call("restore_state", logistics.save_state())).is_true()
		assert_bool(logistics.enable_straight_transport()).is_true()
		assert_int(logistics.work_stats().get("straight_line_active", -1)).is_equal(1)
		# 0.8173 + 5/30 is below the exit: no cell may change ownership.
		var ore: LogisticsOre = logistics._topology.machines[0].belt_ores[0]
		var stored_progress: float = ore.progress
		var before: Dictionary[String, int] = logistics.work_stats()
		for tick: int in range(5):
			logistics.advance(STEP)
			reference.call("advance", STEP)
			_compare(logistics, reference)
		var after: Dictionary[String, int] = logistics.work_stats()
		assert_int(after.get("straight_common_ticks", -1) - before.get("straight_common_ticks", -1)).is_equal(5)
		assert_int(after.get("straight_ore_visits", -1) - before.get("straight_ore_visits", -1)).is_equal(0)
		assert_int(after.get("straight_machine_visits", -1) - before.get("straight_machine_visits", -1)).is_equal(0)
		assert_int(after.get("straight_exit_events", -1) - before.get("straight_exit_events", -1)).is_equal(0)
		assert_float(ore.progress).is_equal(stored_progress)
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)
		before = logistics.work_stats()
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)
		after = logistics.work_stats()
		# The first non-exit tick after a transfer must also stay constant work.
		assert_int(after["straight_exit_events"] - before["straight_exit_events"]).is_equal(0)
		assert_int(after["straight_machine_visits"] - before["straight_machine_visits"]).is_equal(0)
		assert_int(after["straight_ore_visits"] - before["straight_ore_visits"]).is_equal(0)
		assert_int(after["advance"]).is_equal(1)


func test_prediction_and_both_save_expressions_expand_without_changing_lazy_authority() -> void:
	var logistics: LogisticsData = _line(7, Vector3i.RIGHT, true, 2)
	var reference: RefCounted = Reference.new()
	reference.call("bind_world", logistics._world)
	assert_bool(reference.call("restore_state", logistics.save_state())).is_true()
	assert_bool(logistics.enable_straight_transport()).is_true()
	assert_int(logistics.work_stats().get("straight_line_active", -1)).is_equal(1)
	logistics.advance(STEP * 2.4)
	reference.call("advance", STEP * 2.4)
	var stored: float = logistics._topology.machines[0].belt_ores[0].progress
	var before: Dictionary = logistics.save_state()
	var predicted: Array[LogisticsOreQueue] = logistics.sample_cells([Vector3i.ZERO], STEP * 0.4)
	var expected: Array = reference.call("sample_state", STEP * 0.4)
	assert_float(predicted[0].ores[0].progress).is_equal_approx(expected[0]["ores"][0]["progress"], 0.000001)
	predicted[0].ores[0].id = -1
	predicted[0].ores[0].progress = -1
	var restored: LogisticsData = LogisticsData.new()
	restored.bind_world(logistics._world)
	assert_bool(restored.restore_state(logistics.save_packed_state())).is_true()
	assert_bool(Replay.first_difference(Replay.canonical_state(restored.save_state()), Replay.canonical_state(before)).is_empty()).is_true()
	assert_bool(logistics.save_state() == before).is_true()
	assert_float(logistics._topology.machines[0].belt_ores[0].progress).is_equal(stored)
	_compare(logistics, reference)


func test_exit_discards_remainder_and_arrival_cannot_move_through_two_cells_in_one_tick() -> void:
	var logistics: LogisticsData = _line(4, Vector3i.RIGHT, true, 0)
	var state: Dictionary = logistics.save_state()
	var rows: Array = state["machines"]
	rows[0]["ores"] = [{"id": 1, "incoming": Vector3i.RIGHT, "progress": 0.997}]
	rows[0]["quantity"] = 1
	rows[0]["eligible"] = 1
	assert_bool(logistics.restore_state(state)).is_true()
	assert_bool(logistics.enable_straight_transport()).is_true()
	assert_int(logistics.work_stats().get("straight_line_active", -1)).is_equal(1)
	logistics.advance(STEP)
	var actual: Array = logistics.save_state()["machines"]
	assert_int(actual[0]["quantity"]).is_equal(0)
	assert_int(actual[1]["quantity"]).is_equal(1)
	assert_int(actual[2]["quantity"]).is_equal(0)
	assert_float(actual[1]["ores"][0]["progress"]).is_equal(0.0)
	assert_int(actual[1]["eligible"]).is_equal(0)
	assert_int(actual[0]["last_output"]).is_equal(1)
	logistics.advance(STEP)
	actual = logistics.save_state()["machines"]
	assert_int(actual[1]["eligible"]).is_equal(1)
	assert_float(actual[1]["ores"][0]["progress"]).is_equal_approx(1.0 / 30.0, 0.000001)


func test_invalid_restore_preserves_offset_and_edit_exits_without_rewinding_ores() -> void:
	var logistics: LogisticsData = _line(8, Vector3i.RIGHT, true, 2)
	var reference: RefCounted = Reference.new()
	reference.call("bind_world", logistics._world)
	assert_bool(reference.call("restore_state", logistics.save_state())).is_true()
	assert_bool(logistics.enable_straight_transport()).is_true()
	assert_int(logistics.work_stats().get("straight_line_active", -1)).is_equal(1)
	logistics.advance(STEP * 2)
	reference.call("advance", STEP * 2)
	var before: Dictionary = logistics.save_state()
	var invalid: Dictionary = before.duplicate(true)
	invalid["tick"] = -1
	assert_bool(logistics.restore_state(invalid)).is_false()
	assert_bool(logistics.save_state() == before).is_true()
	assert_int(logistics.work_stats().get("straight_line_active", 0)).is_equal(1)
	assert_bool(logistics.set_direction(Vector3i(3, 0, 0), Vector3i.FORWARD)).is_true()
	assert_bool(reference.call("set_direction", Vector3i(3, 0, 0), Vector3i.FORWARD)).is_true()
	assert_int(logistics.work_stats().get("straight_line_active", -1)).is_equal(0)
	_compare(logistics, reference)
	for tick: int in range(40):
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)


func test_pending_edits_miners_side_inputs_and_disconnected_lines_are_rejected() -> void:
	var logistics: LogisticsData = _line(5, Vector3i.RIGHT, true, 2)
	assert_bool(logistics._world.place_block(Vector3i(2, 0, 1), VoxelWorldData.Block.MINER)).is_true()
	assert_bool(logistics.enable_straight_transport()).is_false()
	logistics.advance(STEP)
	assert_bool(logistics.enable_straight_transport()).is_false()
	assert_bool(logistics._world.break_block(Vector3i(2, 0, 1))).is_true()
	logistics.advance(STEP)
	assert_bool(logistics._world.break_block(Vector3i(2, 0, 0))).is_true()
	logistics.advance(STEP)
	assert_bool(logistics.enable_straight_transport()).is_false()


func test_arbitrary_legal_progress_gaps_incoming_and_eligibility_match_reference() -> void:
	for seed_value: int in [7, 42, 601, 20261109]:
		var logistics: LogisticsData = _line(12, Vector3i.RIGHT, true, 2)
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
		var reference: RefCounted = Reference.new()
		reference.call("bind_world", logistics._world)
		assert_bool(reference.call("restore_state", state)).is_true()
		assert_bool(logistics.enable_straight_transport()).is_true()
		assert_int(logistics.work_stats().get("straight_line_active", -1)).is_equal(1)
		for tick: int in range(120):
			for fraction: float in [0.3, 0.7]:
				logistics.advance(STEP * fraction)
				reference.call("advance", STEP * fraction)
				_compare(logistics, reference)


func test_initial_arrival_eligibility_becomes_current_without_a_non_exit_scan() -> void:
	for count: int in [32, 120]:
		var logistics: LogisticsData = _line(count, Vector3i.RIGHT, true, 2)
		var state: Dictionary = logistics.save_state()
		var rows: Array = state["machines"]
		rows[0]["eligible"] = 0
		assert_bool(logistics.restore_state(state)).is_true()
		var reference: RefCounted = Reference.new()
		reference.call("bind_world", logistics._world)
		assert_bool(reference.call("restore_state", state)).is_true()
		assert_bool(logistics.enable_straight_transport()).is_true()
		assert_int(logistics.work_stats().get("straight_line_active", -1)).is_equal(1)
		var before: Dictionary[String, int] = logistics.work_stats()
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)
		var after: Dictionary[String, int] = logistics.work_stats()
		assert_int(after["straight_machine_visits"] - before["straight_machine_visits"]).is_equal(0)
		assert_int(after["advance"]).is_equal(1)


func test_pure_belt_side_input_turn_slope_and_parallel_lines_are_rejected() -> void:
	for shape: String in ["side", "turn", "slope", "parallel"]:
		var logistics: LogisticsData = _line(5, Vector3i.RIGHT, true, 2)
		if shape == "side":
			assert_bool(logistics._world.place_block(Vector3i(2, 0, 1), VoxelWorldData.Block.BELT)).is_true()
			assert_bool(logistics.set_direction(Vector3i(2, 0, 1), Vector3i.FORWARD)).is_true()
		elif shape == "turn":
			assert_bool(logistics.set_direction(Vector3i(2, 0, 0), Vector3i.FORWARD)).is_true()
		elif shape == "slope":
			assert_bool(logistics._world.place_block(Vector3i(2, 0, 1), VoxelWorldData.Block.BELT_UP_EAST)).is_true()
		else:
			for x: int in range(5):
				assert_bool(logistics._world.place_block(Vector3i(x, 0, 1), VoxelWorldData.Block.BELT)).is_true()
				assert_bool(logistics.set_direction(Vector3i(x, 0, 1), Vector3i.RIGHT)).is_true()
		logistics.advance(STEP)
		if shape == "side":
			assert_int(logistics._topology.inputs[2 * 3 + 2]).is_greater_equal(0)
		assert_bool(logistics.enable_straight_transport()).is_false()


func test_both_restored_formats_continue_from_lazy_offset_and_boundary_prediction() -> void:
	for packed: bool in [false, true]:
		var logistics: LogisticsData = _line(6, Vector3i.RIGHT, true, 2)
		var reference: RefCounted = Reference.new()
		reference.call("bind_world", logistics._world)
		assert_bool(reference.call("restore_state", logistics.save_state())).is_true()
		assert_bool(logistics.enable_straight_transport()).is_true()
		logistics.advance(STEP * 2.3)
		reference.call("advance", STEP * 2.3)
		var expected: Array = reference.call("sample_state", STEP * 4.0)
		var predicted: Array[LogisticsOreQueue] = logistics.sample_cells([Vector3i.ZERO], STEP * 4.0)
		assert_float(predicted[0].ores[0].progress).is_equal_approx(expected[0]["ores"][0]["progress"], 0.000001)
		var restored: LogisticsData = LogisticsData.new()
		restored.bind_world(logistics._world)
		assert_bool(restored.restore_state(logistics.save_packed_state() if packed else logistics.save_state())).is_true()
		assert_bool(restored.enable_straight_transport()).is_true()
		for tick: int in range(150):
			logistics.advance(STEP)
			restored.advance(STEP)
			reference.call("advance", STEP)
			_compare(logistics, reference)
			_compare(restored, reference)


func test_deep_invalid_restore_preserves_offset_and_rebinding_releases_old_authority() -> void:
	var logistics: LogisticsData = _line(6, Vector3i.RIGHT, true, 2)
	assert_bool(logistics.enable_straight_transport()).is_true()
	logistics.advance(STEP * 2.0)
	var before: Dictionary = logistics.save_state()
	var invalid: Dictionary = before.duplicate(true)
	invalid["machines"][0]["ores"][0]["progress"] = -0.1
	assert_bool(logistics.restore_state(invalid)).is_false()
	assert_bool(logistics.save_state() == before).is_true()
	assert_int(logistics.work_stats()["straight_line_active"]).is_equal(1)
	var old: WeakRef = _ore_ref_at(logistics, Vector3i.ZERO)
	var replacement: LogisticsData = _line(3, Vector3i.RIGHT, false, 2)
	logistics.bind_world(replacement._world)
	assert_bool(old.get_ref() == null).is_true()
	assert_int(logistics.work_stats()["straight_line_active"]).is_equal(0)
	assert_int(logistics.total_ore()).is_equal(0)
	var reference: RefCounted = Reference.new()
	reference.call("bind_world", replacement._world)
	assert_bool(reference.call("restore_state", logistics.save_state())).is_true()
	logistics.advance(STEP)
	reference.call("advance", STEP)
	_compare(logistics, reference)
