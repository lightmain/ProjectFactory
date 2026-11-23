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
		Replay.canonical_state(reference.call("save_state")), Replay.canonical_state(logistics.save_state()))
	assert_bool(difference.is_empty()).override_failure_message(var_to_str(difference)).is_true()


func _step(logistics: LogisticsData, reference: RefCounted, delta: float = STEP) -> void:
	logistics.advance(delta)
	reference.call("advance", delta)
	_compare(logistics, reference)


func _blocked(count: int) -> LogisticsData:
	var world: VoxelWorldData = VoxelWorldData.new()
	assert_bool(world.generate_flat(Vector3i(-2, -4, -1), Vector3i(104, 12, 76))).is_true()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world)
	for index: int in range(count):
		var lane: int = index / 100
		var cell: Vector3i = Vector3i(index % 100, (lane / 25) * 3, (lane % 25) * 3)
		assert_bool(world.place_block(cell, VoxelWorldData.Block.BELT)).is_true()
		logistics.set_direction(cell, Vector3i.RIGHT)
		assert_bool(world.place_block(cell + Vector3i.BACK, VoxelWorldData.Block.CHEST)).is_true()
		logistics.set_direction(cell + Vector3i.BACK, Vector3i.FORWARD)
	assert_bool(logistics.prefill_belts()).is_true()
	var state: Dictionary = logistics.save_state()
	for row: Dictionary in state["machines"]:
		if row["block"] == VoxelWorldData.Block.CHEST:
			row["quantity"] = 10
			row["eligible"] = 10
	assert_bool(logistics.restore_state(state)).is_true()
	return logistics


func test_fixed_inventory_and_saturated_ports_skip_scans_at_both_sizes() -> void:
	for count: int in [1000, 10000]:
		var logistics: LogisticsData = _blocked(count)
		var reference: RefCounted = _reference(logistics)
		assert_bool(logistics.enable_transport_lines()).is_true()
		_step(logistics, reference)
		_step(logistics, reference)
		var before: Dictionary[String, int] = logistics.work_stats()
		for tick: int in range(50):
			logistics.advance(STEP)
			reference.call("advance", STEP)
		_compare(logistics, reference)
		var after: Dictionary[String, int] = logistics.work_stats()
		for key: String in [
			"transport_inventory_checks", "transport_machine_visits",
			"transport_ore_visits", "transport_fallback_work",
		]:
			assert_int(after.get(key, -1) - before.get(key, -1)).is_equal(0)
		assert_int(after.get("transport_blocked_ticks", -1) - before.get("transport_blocked_ticks", -1)).is_greater(0)
		assert_int(after["transfer_calls"]).is_equal(0)
		assert_int(logistics.total_ore()).is_equal(12 * count)


func test_outlet_edit_wakes_fixed_region_on_supplemental_boundary() -> void:
	var logistics: LogisticsData = _blocked(8)
	var reference: RefCounted = _reference(logistics)
	assert_bool(logistics.enable_transport_lines()).is_true()
	for tick: int in range(4):
		_step(logistics, reference)
	var state: Dictionary = logistics.save_state()
	var invalid: Dictionary = state.duplicate(true)
	invalid["next_id"] = -1
	assert_bool(logistics.restore_state(invalid)).is_false()
	logistics.sample_cells([Vector3i.ZERO], STEP * 0.5)
	assert_dict(logistics.save_state()).is_equal(state)
	var before: Dictionary[String, int] = logistics.work_stats()
	_step(logistics, reference)
	assert_int(logistics.work_stats().get("transport_blocked_ticks", -1) - before.get("transport_blocked_ticks", -1)).is_greater(0)
	var outlet: Vector3i = Vector3i(8, 0, 0)
	assert_bool(logistics._world.place_block(outlet, VoxelWorldData.Block.CHEST)).is_true()
	assert_bool(logistics.set_direction(outlet, Vector3i.RIGHT)).is_true()
	assert_bool(reference.call("set_direction", outlet, Vector3i.RIGHT)).is_true()
	_step(logistics, reference, STEP * 0.25)
	assert_int(logistics.ore_count(outlet)).is_greater(0)
	assert_bool(logistics.restore_state(logistics.save_packed_state())).is_true()
	_compare(logistics, reference)
	for tick: int in range(150):
		_step(logistics, reference)
	assert_int(logistics.total_ore()).is_equal(96)


func test_production_wakes_stalled_supply_and_keeps_formal_eligibility() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, 0.05, 2)
	for x: int in range(6):
		var block: int = VoxelWorldData.Block.MINER if x == 0 else (
			VoxelWorldData.Block.CHEST if x in [1, 5] else VoxelWorldData.Block.BELT)
		world.place_block(Vector3i(x, 0, 0), block)
		logistics.set_direction(Vector3i(x, 0, 0), Vector3i.RIGHT)
	logistics.advance(STEP)
	var reference: RefCounted = _reference(logistics)
	assert_bool(logistics.enable_transport_lines()).is_true()
	for operation: int in range(240):
		if operation == 80:
			logistics.set_direction(Vector3i(1, 0, 0), Vector3i.BACK)
			reference.call("set_direction", Vector3i(1, 0, 0), Vector3i.BACK)
		elif operation == 100:
			logistics.set_direction(Vector3i(1, 0, 0), Vector3i.RIGHT)
			reference.call("set_direction", Vector3i(1, 0, 0), Vector3i.RIGHT)
		elif operation == 150:
			assert_bool(logistics.restore_state(logistics.save_state())).is_true()
		_compare(logistics, reference)
		_step(logistics, reference, STEP * ([0.25, 0.75, 1.0][operation % 3]))
	assert_int(logistics.ore_count(Vector3i(5, 0, 0))).is_greater(0)
