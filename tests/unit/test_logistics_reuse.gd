extends GdUnitTestSuite
## Warmed hot paths must reuse internal objects without changing public reads.

const STEP: float = LogisticsData.LOGIC_STEP


func _place(world: VoxelWorldData, logistics: LogisticsData, cell: Vector3i, block: int) -> void:
	assert_bool(world.place_block(cell, block)).is_true()
	assert_bool(logistics.set_direction(cell, Vector3i.RIGHT)).is_true()


func _creation_counts(logistics: LogisticsData) -> Array[int]:
	var stats: Dictionary[String, int] = logistics.work_stats()
	return [
		stats.get("queue_creations", -1), stats.get("cache_ore_creations", -1),
		stats.get("solver_workspace_growths", -1), stats.get("batch_workspace_growths", -1),
	]


func test_warmed_full_line_reuses_internal_objects_across_ticks_and_prediction_times() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world)
	for x: int in range(12):
		_place(world, logistics, Vector3i(x, 0, 0), VoxelWorldData.Block.BELT)
	assert_bool(logistics.prefill_belts()).is_true()
	logistics.advance(STEP)
	logistics.sample_cells([Vector3i.ZERO], STEP * 0.4)
	var counts: Array[int] = _creation_counts(logistics)
	for count: int in counts:
		assert_int(count).is_greater(0)
	for tick: int in range(80):
		logistics.advance(STEP)
		var saved: Dictionary = logistics.save_state()
		var rows: Array[LogisticsOreQueue] = logistics.sample_cells([Vector3i.ZERO], STEP * 0.4)
		rows[0].ores[0].id = -1
		logistics.sample_cells([Vector3i.RIGHT], STEP * 0.8)
		assert_bool(logistics.save_state() == saved).is_true()
		assert_bool(_creation_counts(logistics) == counts).is_true()
	assert_int(logistics.work_stats().get("advance_queue_rows", -1)).is_equal(12)
	assert_int(logistics.work_stats().get("cache_ore_slots", -1)).is_equal(24)


func test_emptying_and_refilling_cache_slots_does_not_recreate_ores() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world)
	for x: int in range(4):
		_place(world, logistics, Vector3i(x, 0, 0), VoxelWorldData.Block.BELT)
	_place(world, logistics, Vector3i(4, 0, 0), VoxelWorldData.Block.CHEST)
	assert_bool(logistics.prefill_belts()).is_true()
	logistics.sample_belts()
	var loaded: Dictionary = logistics.save_state()
	logistics.advance(4.0)
	assert_int(logistics.ore_count(Vector3i.ZERO)).is_equal(0)
	logistics.sample_belts()
	var counts: Array[int] = _creation_counts(logistics)
	for tick: int in range(20):
		logistics.advance(STEP)
		logistics.sample_belts(STEP * 0.5)
	assert_bool(_creation_counts(logistics) == counts).is_true()
	assert_int(logistics.work_stats().get("cache_ore_slots", -1)).is_equal(8)
	assert_bool(logistics.restore_state(loaded)).is_true()
	logistics.sample_belts()
	assert_int(logistics.total_ore()).is_equal(8)
	assert_int(logistics.work_stats().get("cache_ore_slots", -1)).is_equal(8)


func test_nonlast_removal_failed_restore_and_reset_release_old_rows_and_capacity() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world)
	for x: int in range(8):
		_place(world, logistics, Vector3i(x, 0, 0), VoxelWorldData.Block.BELT)
	assert_bool(logistics.prefill_belts()).is_true()
	logistics.advance(STEP)
	logistics.sample_belts()
	assert_bool(world.break_block(Vector3i(2, 0, 0))).is_true()
	assert_int(logistics.work_stats().get("advance_queue_rows", -1)).is_equal(7)
	assert_int(logistics.work_stats().get("cache_ore_slots", -1)).is_equal(14)
	logistics.advance(STEP)
	logistics.sample_belts()
	assert_int(logistics.work_stats().get("solver_node_capacity", -1)).is_equal(14)
	assert_int(logistics.work_stats().get("batch_capacity", -1)).is_equal(7)
	var before: Dictionary = logistics.save_state()
	var invalid: Dictionary = before.duplicate(true)
	invalid["tick"] = -1
	assert_bool(logistics.restore_state(invalid)).is_false()
	assert_bool(logistics.save_state() == before).is_true()
	var counts: Array[int] = _creation_counts(logistics)
	logistics.sample_belts(STEP * 0.5)
	assert_bool(_creation_counts(logistics) == counts).is_true()
	world.generate_flat()
	assert_int(logistics.work_stats().get("advance_queue_rows", -1)).is_equal(0)
	assert_int(logistics.work_stats().get("cache_ore_slots", -1)).is_equal(0)
	assert_int(logistics.work_stats().get("solver_node_capacity", -1)).is_equal(0)
	assert_int(logistics.work_stats().get("batch_capacity", -1)).is_equal(0)
	_place(world, logistics, Vector3i.ZERO, VoxelWorldData.Block.BELT)
	logistics.advance(STEP)
	assert_int(logistics.sample_belts()[0].ores.size()).is_equal(0)


func test_one_solver_alternates_large_cycles_small_chains_and_empty_results() -> void:
	var solver: BeltPositionSolver = BeltPositionSolver.new()
	for count: int in [128, 3, 0, 32, 1, 128]:
		var desired: Array[float] = []
		var leaders: Array[int] = []
		var weights: Array[float] = []
		for index: int in range(count):
			desired.append(0.2 if index == count - 1 else 1.0)
			leaders.append((index + 1) % count if count % 2 == 0 else index - 1)
			weights.append(0.0)
		var actual: Array[float] = solver.solve(desired, leaders, weights)
		assert_int(actual.size()).is_equal(count)
		for index: int in range(count):
			assert_float(actual[index]).is_equal_approx(
				0.2 if count % 2 == 0 or index == count - 1 else 1.0, 0.000001
			)
		if not actual.is_empty():
			actual[0] = -100.0
		var second: Array[float] = solver.solve(desired, leaders, weights)
		if not second.is_empty():
			assert_float(second[0]).is_greater_equal(0.2 - 0.000001)


func test_sparse_moving_line_stops_internal_growth_after_maximum_occupancy_warmup() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, 0.1, 1)
	_place(world, logistics, Vector3i.LEFT, VoxelWorldData.Block.MINER)
	for x: int in range(6):
		_place(world, logistics, Vector3i(x, 0, 0), VoxelWorldData.Block.BELT)
	_place(world, logistics, Vector3i(6, 0, 0), VoxelWorldData.Block.CHEST)
	logistics.advance(8.0)
	logistics.sample_belts()
	var counts: Array[int] = _creation_counts(logistics)
	assert_int(counts[1]).is_equal(12)
	for tick: int in range(180):
		logistics.advance(STEP)
		logistics.sample_cells([Vector3i.ZERO, Vector3i(5, 0, 0)], STEP * 0.3)
	assert_bool(_creation_counts(logistics) == counts).is_true()
	assert_int(logistics.ore_count(Vector3i(6, 0, 0))).is_greater(0)


func test_removed_authority_and_cache_objects_are_not_retained_by_workspaces() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world)
	for x: int in range(3):
		_place(world, logistics, Vector3i(x, 0, 0), VoxelWorldData.Block.BELT)
	assert_bool(logistics.prefill_belts()).is_true()
	logistics.advance(STEP)
	logistics.sample_cells([Vector3i.ZERO], STEP * 0.5)
	var authority: WeakRef = weakref(logistics._topology.machines[0].belt_ores[0])
	var prediction: WeakRef = weakref(logistics._sample_queues[0].ores[0])
	var borrowed: WeakRef = weakref(logistics._advance_queues[0])
	assert_bool(world.break_block(Vector3i.ZERO)).is_true()
	assert_bool(authority.get_ref() == null).is_true()
	assert_bool(prediction.get_ref() == null).is_true()
	assert_bool(borrowed.get_ref() == null).is_true()
	logistics.advance(STEP)
	logistics.sample_belts()
	var remaining: WeakRef = weakref(logistics._topology.machines[0].belt_ores[0])
	world.generate_flat()
	assert_bool(remaining.get_ref() == null).is_true()


func test_one_factory_alternates_sizes_and_warms_each_new_set_only_once() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world)
	for count: int in [2, 20, 1, 0, 12]:
		world.generate_flat()
		for x: int in range(count):
			_place(world, logistics, Vector3i(x, 0, 0), VoxelWorldData.Block.BELT)
		assert_bool(logistics.prefill_belts()).is_true()
		logistics.advance(STEP)
		logistics.sample_belts(STEP * 0.5)
		var warmed: Array[int] = _creation_counts(logistics)
		for tick: int in range(5):
			logistics.advance(STEP)
			logistics.sample_belts(STEP * 0.5)
		assert_bool(_creation_counts(logistics) == warmed).is_true()
		assert_int(logistics.work_stats()["advance_queue_rows"]).is_equal(count)
		assert_int(logistics.work_stats()["cache_ore_slots"]).is_equal(2 * count)
		assert_int(logistics.work_stats()["solver_node_capacity"]).is_equal(2 * count)
		assert_int(logistics.work_stats()["batch_capacity"]).is_equal(count)


func test_chest_arrival_releases_consumed_ore_before_the_next_batch() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world)
	_place(world, logistics, Vector3i.ZERO, VoxelWorldData.Block.BELT)
	_place(world, logistics, Vector3i.RIGHT, VoxelWorldData.Block.CHEST)
	assert_bool(logistics.prefill_belts()).is_true()
	var consumed: WeakRef = weakref(logistics._topology.machines[0].belt_ores[0])
	# Prefill settled the graph; this executes exactly one formal batch.
	logistics.advance(STEP)
	assert_int(logistics.ore_count(Vector3i.RIGHT)).is_equal(1)
	assert_bool(consumed.get_ref() == null).is_true()
	assert_bool(world.break_block(Vector3i.ZERO)).is_true()
	assert_bool(consumed.get_ref() == null).is_true()


func test_failed_feasibility_check_retires_borrowed_ores_and_allows_next_solve() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	assert_bool(world.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT)).is_true()
	var topology: LogisticsTopology = LogisticsTopology.new()
	topology.clear(world)
	var machine: LogisticsMachine = LogisticsMachine.new(VoxelWorldData.Block.BELT, 0.0, 1.0, 1)
	topology.add(Vector3i.ZERO, machine)
	topology.rebuild()
	for progress: float in [0.2, 0.1]:
		var ore: LogisticsOre = LogisticsOre.new(machine.belt_ores.size() + 1, Vector3i.FORWARD)
		ore.progress = progress
		machine.belt_ores.append(ore)
	var queue: LogisticsOreQueue = LogisticsOreQueue.new()
	queue.ores = machine.belt_ores
	var old: WeakRef = weakref(machine.belt_ores[0])
	var solver: BeltPositionSolver = BeltPositionSolver.new()
	assert_bool(solver.is_feasible(topology, [queue])).is_false()
	assert_float(machine.belt_ores[0].progress).is_equal(0.2)
	machine.belt_ores.clear()
	assert_bool(old.get_ref() == null).is_true()
	var replacement: LogisticsOre = LogisticsOre.new(3, Vector3i.FORWARD)
	machine.belt_ores.append(replacement)
	solver.advance(topology, [queue], STEP)
	assert_float(replacement.progress).is_equal_approx(STEP / 0.5, 0.000001)
