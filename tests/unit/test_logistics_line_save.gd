extends GdUnitTestSuite

const Reference = preload("res://tests/support/logistics_t03_reference.gd")
const Replay = preload("res://tests/support/logistics_replay.gd")
const STEP: float = LogisticsData.LOGIC_STEP


func _compare(left: Dictionary, right: Dictionary) -> void:
	var difference: Dictionary = Replay.first_difference(
		Replay.canonical_state(left), Replay.canonical_state(right)
	)
	assert_bool(difference.is_empty()).override_failure_message(var_to_str(difference)).is_true()


func _factory() -> LogisticsData:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, 0.031, 2)
	for x: int in range(-1, 8):
		for z: int in [0, 3]:
			world.place_block(Vector3i(x, 0, z),
				VoxelWorldData.Block.MINER if x == -1 else VoxelWorldData.Block.BELT)
			logistics.set_direction(Vector3i(x, 0, z), Vector3i.RIGHT)
	var cells: Array[Vector3i] = [
		Vector3i(-4, 0, 0), Vector3i(-3, 0, 0), Vector3i(-3, 0, 1), Vector3i(-4, 0, 1),
	]
	for index: int in range(cells.size()):
		world.place_block(cells[index], VoxelWorldData.Block.BELT)
		logistics.set_direction(cells[index], cells[(index + 1) % cells.size()] - cells[index])
	logistics.prefill_belts()
	logistics.advance(STEP)
	assert_bool(logistics.enable_transport_lines()).is_true()
	logistics.advance(STEP * 3)
	return logistics


func _reference(logistics: LogisticsData) -> RefCounted:
	var reference: RefCounted = Reference.new()
	reference.call("bind_world", logistics._world)
	assert_bool(reference.call("restore_state", logistics.save_state())).is_true()
	return reference


func _continue(logistics: LogisticsData, restored: LogisticsData, reference: RefCounted) -> void:
	for delta: float in [STEP * 0.25, STEP * 0.75, STEP, STEP * 2.5, STEP * 0.5, 0.7]:
		logistics.advance(delta)
		restored.advance(delta)
		reference.call("advance", delta)
		_compare(logistics.save_state(), reference.call("save_state"))
		_compare(restored.save_state(), reference.call("save_state"))
	for tick: int in range(120):
		logistics.advance(STEP)
		restored.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics.save_state(), reference.call("save_state"))
		_compare(restored.save_state(), reference.call("save_state"))


func test_existing_opt_in_survives_successful_restore_of_both_expressions() -> void:
	for packed: bool in [false, true]:
		var logistics: LogisticsData = _factory()
		var reference: RefCounted = _reference(logistics)
		var before: Dictionary = logistics.save_state()
		assert_bool(logistics.restore_state(logistics.save_packed_state() if packed else before)).is_true()
		_compare(logistics.save_state(), before)
		assert_int(logistics.work_stats()["transport_ring_count"]).is_equal(1)
		assert_int(logistics.work_stats()["transport_line_count"]).is_greater(0)
		for tick: int in range(100):
			logistics.advance(STEP)
			reference.call("advance", STEP)
			_compare(logistics.save_state(), reference.call("save_state"))


func test_pending_rotation_and_nonlast_deletion_restore_without_early_settlement() -> void:
	for packed: bool in [false, true]:
		for partial: bool in [false, true]:
			var logistics: LogisticsData = _factory()
			var reference: RefCounted = _reference(logistics)
			if partial:
				logistics.advance(STEP * 0.4)
				reference.call("advance", STEP * 0.4)
			logistics.set_direction(Vector3i(3, 0, 0), Vector3i.BACK)
			reference.call("set_direction", Vector3i(3, 0, 0), Vector3i.BACK)
			logistics._world.break_block(Vector3i(-3, 0, 0))
			var before: Dictionary = logistics.save_state()
			var restored: LogisticsData = LogisticsData.new()
			restored.bind_world(logistics._world)
			assert_bool(restored.restore_state(logistics.save_packed_state() if packed else before)).is_true()
			assert_bool(restored.enable_transport_lines()).is_true()
			_compare(restored.save_state(), before)
			restored.sample_cells([Vector3i(3, 0, 0), Vector3i(-4, 0, 0)], STEP)
			restored.save_packed_state()
			_compare(restored.save_state(), before)
			assert_bool(logistics.restore_state(logistics.save_packed_state() if packed else before)).is_true()
			_compare(logistics.save_state(), before)
			_continue(logistics, restored, reference)


func test_failed_restore_preserves_cached_offset_ring_and_subsequent_evolution() -> void:
	var logistics: LogisticsData = _factory()
	var reference: RefCounted = _reference(logistics)
	var before: Dictionary = logistics.save_state()
	var invalid: Dictionary = before.duplicate(true)
	var rows: Array = invalid["machines"]
	rows[0]["cycles"] += 1
	var stats: Dictionary[String, int] = logistics.work_stats()
	assert_bool(logistics.restore_state(invalid)).is_false()
	_compare(logistics.save_state(), before)
	assert_bool(logistics.work_stats() == stats).is_true()
	for tick: int in range(80):
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics.save_state(), reference.call("save_state"))


func test_miner_deadline_rounding_remains_restorable_without_accepting_forged_cycles() -> void:
	var placed: float = 0.6000000010000001
	var miner: LogisticsMachine = LogisticsMachine.new(VoxelWorldData.Block.MINER, placed, 0.05, 2)
	for tick: int in range(37, 112):
		miner.produce_until(float(tick) * STEP)
	var row: Dictionary = miner.save_state()
	assert_int(row["cycles"]).is_equal(24)
	assert_bool(row["next"] > float(111) * STEP + LogisticsData.TIME_EPSILON).is_true()
	var decoded: LogisticsMachine = LogisticsMachine.decode(row, 1.8583333355333334, 111)
	assert_object(decoded).is_not_null()
	if decoded != null:
		for tick: int in range(112, 180):
			miner.produce_until(float(tick) * STEP)
			decoded.produce_until(float(tick) * STEP)
			assert_bool(decoded.save_state() == miner.save_state()).is_true()
	var forged: Dictionary = row.duplicate(true)
	forged["cycles"] = 23
	forged["next"] = placed + 24.0 * 0.05
	assert_object(LogisticsMachine.decode(forged, 1.8583333355333334, 111)).is_null()
	# A truly due deadline cannot be held back by one cycle.
	forged = row.duplicate(true)
	forged["placed"] = 0.6
	forged["next"] = 0.6 + 25.0 * 0.05
	assert_object(LogisticsMachine.decode(forged, 1.8583333355333334, 111)).is_null()


func test_restored_slope_chain_and_merge_resume_after_blockage_and_outlet_edit() -> void:
	for packed: bool in [false, true]:
		var world: VoxelWorldData = VoxelWorldData.new()
		world.generate_flat()
		var logistics: LogisticsData = LogisticsData.new()
		logistics.bind_world(world, 0.017, 2)
		var cells: Array[Vector3i] = [
			Vector3i.LEFT, Vector3i.ZERO, Vector3i.RIGHT, Vector3i(2, 1, 0),
			Vector3i(3, 0, 0), Vector3i(4, 0, 0),
			Vector3i(4, 0, 2), Vector3i(4, 0, 1),
		]
		var blocks: Array[int] = [
			VoxelWorldData.Block.MINER, VoxelWorldData.Block.BELT, VoxelWorldData.Block.BELT_UP_EAST,
			VoxelWorldData.Block.BELT, VoxelWorldData.Block.BELT_DOWN_EAST, VoxelWorldData.Block.BELT,
			VoxelWorldData.Block.MINER, VoxelWorldData.Block.BELT,
		]
		for index: int in range(cells.size()):
			world.place_block(cells[index], blocks[index])
			logistics.set_direction(cells[index], Vector3i.RIGHT if index < 6 else Vector3i.FORWARD)
		logistics.prefill_belts()
		logistics.advance(STEP * 40)
		assert_bool(logistics.enable_transport_lines()).is_true()
		for tick: int in range(60):
			logistics.advance(STEP)
		var reference: RefCounted = _reference(logistics)
		var restored: LogisticsData = LogisticsData.new()
		restored.bind_world(world)
		assert_bool(restored.restore_state(logistics.save_packed_state() if packed else logistics.save_state())).is_true()
		assert_bool(restored.enable_transport_lines()).is_true()
		_continue(logistics, restored, reference)
		world.place_block(Vector3i(5, 0, 0), VoxelWorldData.Block.CHEST)
		for data: LogisticsData in [logistics, restored]:
			data.set_direction(Vector3i(5, 0, 0), Vector3i.RIGHT)
		reference.call("set_direction", Vector3i(5, 0, 0), Vector3i.RIGHT)
		_continue(logistics, restored, reference)
		assert_int(restored.ore_count(Vector3i(5, 0, 0))).is_greater(0)


func test_empty_successful_restore_keeps_opt_in_for_later_building() -> void:
	var logistics: LogisticsData = _factory()
	for cell: Vector3i in logistics.machine_cells():
		logistics._world.break_block(cell)
	assert_bool(logistics.restore_state(logistics.save_packed_state())).is_true()
	logistics._world.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	logistics._world.place_block(Vector3i.FORWARD, VoxelWorldData.Block.BELT)
	logistics.advance(STEP)
	assert_int(logistics.work_stats()["transport_line_count"]).is_equal(1)


func test_slope_ring_pending_cut_restores_old_graph_and_continues() -> void:
	for packed: bool in [false, true]:
		var world: VoxelWorldData = VoxelWorldData.new()
		world.generate_flat()
		var logistics: LogisticsData = LogisticsData.new()
		logistics.bind_world(world, INF, 1)
		var cells: Array[Vector3i] = [
			Vector3i(-1, 0, 0), Vector3i.ZERO, Vector3i(1, 1, 0),
			Vector3i(1, 1, 1), Vector3i(0, 0, 1), Vector3i(-1, 0, 1),
		]
		var blocks: Array[int] = [
			VoxelWorldData.Block.BELT, VoxelWorldData.Block.BELT_UP_EAST, VoxelWorldData.Block.BELT,
			VoxelWorldData.Block.BELT, VoxelWorldData.Block.BELT_DOWN_WEST, VoxelWorldData.Block.BELT,
		]
		var directions: Array[Vector3i] = [
			Vector3i.RIGHT, Vector3i.RIGHT, Vector3i.BACK, Vector3i.LEFT, Vector3i.LEFT, Vector3i.FORWARD,
		]
		for index: int in range(cells.size()):
			world.place_block(cells[index], blocks[index])
			logistics.set_direction(cells[index], directions[index])
		logistics.prefill_belts()
		logistics.advance(STEP)
		logistics.enable_transport_lines()
		logistics.advance(STEP * 3.5)
		var reference: RefCounted = _reference(logistics)
		world.break_block(Vector3i.ZERO)
		var restored: LogisticsData = LogisticsData.new()
		restored.bind_world(world)
		assert_bool(restored.restore_state(logistics.save_packed_state() if packed else logistics.save_state())).is_true()
		assert_bool(restored.enable_transport_lines()).is_true()
		_continue(logistics, restored, reference)
		world.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT_UP_EAST)
		_continue(logistics, restored, reference)


func test_waiting_previous_deadline_can_catch_up_two_cycles_without_accepting_a_forgery() -> void:
	var placed: float = 0.21666666766666673
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, STEP, 2)
	logistics.advance(placed)
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	world.place_block(Vector3i.FORWARD, VoxelWorldData.Block.BELT)
	assert_bool(logistics.enable_transport_lines()).is_true()
	logistics.advance(float(37) * STEP - placed)
	var before: Dictionary = logistics.save_state()
	var rows: Array = before["machines"]
	assert_int(rows[0]["cycles"]).is_equal(24)
	var forged: Dictionary = before.duplicate(true)
	forged["machines"][0]["cycles"] = 23
	forged["machines"][0]["next"] = placed + 24.0 * STEP
	assert_bool(logistics.restore_state(forged)).is_false()
	assert_bool(logistics.save_state() == before).is_true()
	for packed: bool in [false, true]:
		var restored: LogisticsData = LogisticsData.new()
		restored.bind_world(world)
		assert_bool(restored.restore_state(logistics.save_packed_state() if packed else before)).is_true()
		_compare(restored.save_state(), before)
