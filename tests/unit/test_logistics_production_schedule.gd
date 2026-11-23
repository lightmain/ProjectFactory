extends GdUnitTestSuite

const Reference = preload("res://tests/support/logistics_t03_reference.gd")
const Replay = preload("res://tests/support/logistics_replay.gd")
const STEP: float = LogisticsData.LOGIC_STEP
const DELTAS: Array[float] = [0.25, 0.75, 1.5]


func _compare(logistics: LogisticsData, reference: RefCounted) -> void:
	var difference: Dictionary = Replay.first_difference(
		Replay.canonical_state(reference.call("save_state")), Replay.canonical_state(logistics.save_state()))
	assert_bool(difference.is_empty()).override_failure_message(var_to_str(difference)).is_true()


func _reference(logistics: LogisticsData) -> RefCounted:
	var reference: RefCounted = Reference.new()
	reference.call("bind_world", logistics._world)
	assert_bool(reference.call("restore_state", logistics.save_state())).is_true()
	return reference


func test_nondue_miner_checks_do_not_grow_with_factory_size() -> void:
	var checks: Array[int] = []
	for count: int in [1000, 10000]:
		var world: VoxelWorldData = VoxelWorldData.new()
		assert_bool(world.generate_flat(Vector3i(-1, -4, -1), Vector3i(104, 12, 76))).is_true()
		var logistics: LogisticsData = LogisticsData.new()
		logistics.bind_world(world, 1000.0, 1)
		for index: int in range(count):
			var lane: int = index / 100
			var cell: Vector3i = Vector3i(index % 100, (lane / 25) * 3, (lane % 25) * 3)
			assert_bool(world.place_block(cell, VoxelWorldData.Block.BELT)).is_true()
			logistics.set_direction(cell, Vector3i.RIGHT)
			assert_bool(world.place_block(cell + Vector3i.BACK, VoxelWorldData.Block.MINER)).is_true()
			logistics.set_direction(cell + Vector3i.BACK, Vector3i.FORWARD)
		logistics.advance(STEP)
		var reference: RefCounted = _reference(logistics)
		assert_bool(logistics.enable_transport_lines()).is_true()
		var before: Dictionary[String, int] = logistics.work_stats()
		for tick: int in range(50):
			logistics.advance(STEP)
			reference.call("advance", STEP)
		_compare(logistics, reference)
		var after: Dictionary[String, int] = logistics.work_stats()
		assert_int(after["transport_machine_visits"] - before["transport_machine_visits"]).is_equal(0)
		var deadline_checks: int = after.get("production_deadline_checks", -1) - before.get("production_deadline_checks", -1)
		assert_int(deadline_checks).is_equal(50)
		assert_int(after.get("production_due_visits", -1)).is_equal(0)
		checks.append(deadline_checks)
	assert_int(checks[0]).is_equal(checks[1])


func test_staggered_fast_miners_keep_phase_through_edits_and_packed_restore() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, 0.017, 2)
	for z: int in [0, 3, 6]:
		for x: int in range(-1, 5):
			world.place_block(Vector3i(x, 0, z), VoxelWorldData.Block.MINER if x == -1 else (
				VoxelWorldData.Block.CHEST if x == 4 else VoxelWorldData.Block.BELT))
			logistics.set_direction(Vector3i(x, 0, z), Vector3i.RIGHT)
		logistics.advance(STEP * 0.25)
	logistics.advance(STEP * 0.25)
	var reference: RefCounted = _reference(logistics)
	assert_bool(logistics.enable_transport_lines()).is_true()
	for operation: int in range(360):
		if operation == 80:
			world.break_block(Vector3i(-1, 0, 0))
		elif operation == 81:
			logistics.configure_miners(0.001, 3)
			reference.call("configure_miners", 0.001, 3)
			world.place_block(Vector3i(-1, 0, 0), VoxelWorldData.Block.MINER)
			logistics.set_direction(Vector3i(-1, 0, 0), Vector3i.RIGHT)
			reference.call("set_direction", Vector3i(-1, 0, 0), Vector3i.RIGHT)
		elif operation == 120:
			assert_bool(logistics.restore_state(logistics.save_packed_state())).is_true()
		_compare(logistics, reference)
		var delta: float = STEP * DELTAS[operation % 3]
		if operation % 100 == 99:
			delta = 0.13
		logistics.advance(delta)
		reference.call("advance", delta)
		_compare(logistics, reference)
	assert_int(logistics.work_stats().get("production_due_visits", -1)).is_greater(0)
