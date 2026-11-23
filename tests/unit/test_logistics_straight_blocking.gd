extends GdUnitTestSuite

const Reference = preload("res://tests/support/logistics_t03_reference.gd")
const Replay = preload("res://tests/support/logistics_replay.gd")
const STEP: float = LogisticsData.LOGIC_STEP


func _blocked_line(count: int) -> LogisticsData:
	var world: VoxelWorldData = VoxelWorldData.new()
	assert_bool(world.generate_flat(Vector3i(-2, -4, -2), Vector3i(count + 3, 5, 3))).is_true()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world)
	for x: int in range(count):
		var cell: Vector3i = Vector3i(x, 0, 0)
		assert_bool(world.place_block(cell, VoxelWorldData.Block.BELT)).is_true()
		assert_bool(logistics.set_direction(cell, Vector3i.RIGHT)).is_true()
	assert_bool(logistics.prefill_belts()).is_true()
	return logistics


func _reference(logistics: LogisticsData) -> RefCounted:
	var reference: RefCounted = Reference.new()
	reference.call("bind_world", logistics._world)
	assert_bool(reference.call("restore_state", logistics.save_state())).is_true()
	return reference


func _advance_pair(logistics: LogisticsData, reference: RefCounted) -> void:
	logistics.advance(STEP)
	reference.call("advance", STEP)
	_compare(logistics, reference)


func _compare(logistics: LogisticsData, reference: RefCounted) -> void:
	var difference: Dictionary = Replay.first_difference(
		Replay.canonical_state(reference.call("save_state")),
		Replay.canonical_state(logistics.save_state())
	)
	assert_bool(difference.is_empty()).override_failure_message(var_to_str(difference)).is_true()


func _ore_ref_at(logistics: LogisticsData, cell: Vector3i) -> WeakRef:
	# Keep the temporary strong reference in a separate stack frame.
	var index: int = logistics._topology.index_at(cell)
	return weakref(logistics._topology.machines[index].belt_ores[0])


func test_fixed_point_ticks_skip_facilities_ores_and_fallback_work_at_both_lengths() -> void:
	for count: int in [8, 120]:
		var logistics: LogisticsData = _blocked_line(count)
		var reference: RefCounted = _reference(logistics)
		assert_bool(logistics.enable_straight_transport()).is_true()
		_advance_pair(logistics, reference)
		_advance_pair(logistics, reference)
		var before: Dictionary[String, int] = logistics.work_stats()
		for tick: int in range(80):
			_advance_pair(logistics, reference)
		var after: Dictionary[String, int] = logistics.work_stats()
		assert_int(after.get("straight_blocked_ticks", -1) - before.get("straight_blocked_ticks", -1)).is_equal(80)
		assert_int(after.get("straight_ore_visits", -1) - before.get("straight_ore_visits", -1)).is_equal(0)
		assert_int(after.get("straight_machine_visits", -1) - before.get("straight_machine_visits", -1)).is_equal(0)
		assert_int(after.get("straight_fallback_work", -1) - before.get("straight_fallback_work", -1)).is_equal(0)
		assert_int(logistics.total_ore()).is_equal(2 * count)


func test_opening_exit_resumes_the_tight_queue_on_the_first_batch() -> void:
	var logistics: LogisticsData = _blocked_line(10)
	var reference: RefCounted = _reference(logistics)
	assert_bool(logistics.enable_straight_transport()).is_true()
	for tick: int in range(5):
		_advance_pair(logistics, reference)
	var exit: Vector3i = Vector3i(10, 0, 0)
	assert_bool(logistics._world.place_block(exit, VoxelWorldData.Block.CHEST)).is_true()
	assert_bool(logistics.set_direction(exit, Vector3i.RIGHT)).is_true()
	assert_bool(reference.call("set_direction", exit, Vector3i.RIGHT)).is_true()
	_compare(logistics, reference)
	_advance_pair(logistics, reference)
	assert_int(logistics.ore_count(exit)).is_equal(1)
	var rows: Array = logistics.save_state()["machines"]
	for index: int in range(10):
		assert_int(rows[index]["ores"][0]["id"]).is_equal(2 * index + 2)
		# Boundary editing performs a supplemental transfer before the next
		# formal movement; the old tail has already moved for one tick here.
		assert_float(rows[index]["ores"][0]["progress"]).is_equal_approx(0.5 + 1.0 / 30.0, 0.000001)
	assert_bool(logistics.enable_straight_transport()).is_true()
	_advance_pair(logistics, reference)
	rows = logistics.save_state()["machines"]
	for index: int in range(10):
		assert_float(rows[index]["ores"][0]["progress"]).is_equal_approx(0.5 + 2.0 / 30.0, 0.000001)
	for tick: int in range(120):
		_advance_pair(logistics, reference)
	assert_int(logistics.total_ore()).is_equal(20)


func test_sparse_head_or_tail_settles_then_uses_fixed_point_without_losing_ids() -> void:
	for empty_head: bool in [true, false]:
		var logistics: LogisticsData = _blocked_line(8)
		var state: Dictionary = logistics.save_state()
		var rows: Array = state["machines"]
		for index: int in range(3):
			var row: Dictionary = rows[7 - index if empty_head else index]
			row["ores"] = []
			row["quantity"] = 0
			row["eligible"] = 0
		assert_bool(logistics.restore_state(state)).is_true()
		var reference: RefCounted = _reference(logistics)
		assert_bool(logistics.enable_straight_transport()).is_true()
		for tick: int in range(300):
			_advance_pair(logistics, reference)
		var before: Dictionary[String, int] = logistics.work_stats()
		for tick: int in range(30):
			_advance_pair(logistics, reference)
		assert_int(logistics.work_stats().get("straight_blocked_ticks", -1) - before.get("straight_blocked_ticks", -1)).is_equal(30)
		assert_int(logistics.total_ore()).is_equal(10)


func test_failed_restore_reads_and_loaded_belt_deletion_invalidate_only_on_success() -> void:
	var logistics: LogisticsData = _blocked_line(8)
	var reference: RefCounted = _reference(logistics)
	assert_bool(logistics.enable_straight_transport()).is_true()
	_advance_pair(logistics, reference)
	var before: Dictionary = logistics.save_state()
	var invalid: Dictionary = before.duplicate(true)
	invalid["next_id"] = -1
	assert_bool(logistics.restore_state(invalid)).is_false()
	assert_bool(logistics.save_state() == before).is_true()
	var work_before: Dictionary[String, int] = logistics.work_stats()
	logistics.sample_cells([Vector3i.ZERO], STEP * 0.5)
	logistics.save_packed_state()
	_advance_pair(logistics, reference)
	assert_int(logistics.work_stats().get("straight_blocked_ticks", -1) - work_before.get("straight_blocked_ticks", -1)).is_equal(1)
	var removed: WeakRef = _ore_ref_at(logistics, Vector3i(3, 0, 0))
	assert_bool(logistics._world.break_block(Vector3i(3, 0, 0))).is_true()
	assert_bool(removed.get_ref() == null).is_true()
	assert_int(logistics.work_stats().get("straight_line_active", -1)).is_equal(0)
	_compare(logistics, reference)
	for tick: int in range(40):
		_advance_pair(logistics, reference)
	assert_int(logistics.total_ore()).is_equal(14)
