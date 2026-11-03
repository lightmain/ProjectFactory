extends GdUnitTestSuite
## Work bounds count visits, not wall-clock duration or hash-table averages.

var _world: VoxelWorldData
var _logistics: LogisticsData
const STEP: float = 1.0 / 60.0


func before_test() -> void:
	_world = VoxelWorldData.new()
	_world.generate_flat()
	_logistics = LogisticsData.new()
	_logistics.bind_world(_world, 0.001, 1)


func _place(cell: Vector3i, block: int, direction: Vector3i = Vector3i.RIGHT) -> void:
	assert_bool(_world.place_block(cell, block)).is_true()
	assert_bool(_logistics.set_direction(cell, direction)).is_true()


func test_packed_upstream_first_chain_sampling_has_a_linear_visit_bound() -> void:
	_place(Vector3i(-16, 0, 0), VoxelWorldData.Block.MINER)
	for x: int in range(-15, 16):
		_place(Vector3i(x, 0, 0), VoxelWorldData.Block.BELT)
	_logistics.advance(20.0)
	for x: int in range(-15, 16):
		assert_int(_logistics.ore_count(Vector3i(x, 0, 0))).is_equal(2)
	_logistics.sample_belts(0.01)
	assert_int(_logistics.work_stats()["sample"]).is_less_equal(16 * 32)


func test_staggered_fast_miners_share_one_fixed_batch() -> void:
	for x: int in range(-15, 15):
		_place(Vector3i(x, 0, 0), VoxelWorldData.Block.MINER)
		_logistics.advance(0.00002)
	# All different production phases fit into one global batch.
	_logistics.advance(STEP - 0.0006)
	assert_int(_logistics.work_stats()["batches"]).is_equal(1)
	assert_int(_logistics.work_stats()["advance"]).is_less_equal(80 * 30)
	assert_int(_logistics.total_ore()).is_equal(30 * 16)


func test_production_is_quantized_without_resetting_grid_on_edits_or_queries() -> void:
	_logistics.configure_miners(0.001, 1)
	_place(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	_logistics.advance(0.002)
	assert_int(_logistics.ore_count(Vector3i.ZERO)).is_equal(0)
	_place(Vector3i(3, 0, 0), VoxelWorldData.Block.CHEST)
	_logistics.advance(0.0)
	_logistics.sample_belts(100.0)
	_logistics.advance(STEP - 0.002)
	assert_int(_logistics.ore_count(Vector3i.ZERO)).is_equal(16)


func test_busy_belt_direction_change_fails_without_moving_ore_backwards() -> void:
	_place(Vector3i.LEFT, VoxelWorldData.Block.MINER)
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	_logistics.advance(1.0)
	var before: LogisticsOre = _logistics.belt_ores(Vector3i.ZERO)[0]
	assert_bool(_logistics.set_direction(Vector3i.ZERO, Vector3i.BACK)).is_false()
	assert_bool(_logistics.set_direction(Vector3i.ZERO, Vector3i.RIGHT)).is_true()
	assert_vector(_logistics.direction_at(Vector3i.ZERO)).is_equal(Vector3i.RIGHT)
	assert_float(_logistics.belt_ores(Vector3i.ZERO)[0].progress).is_equal(before.progress)


func test_boundary_edit_flush_cannot_relay_new_chest_inventory_twice() -> void:
	_logistics.configure_miners(1.0, 1)
	_place(Vector3i.LEFT, VoxelWorldData.Block.MINER)
	_place(Vector3i.ZERO, VoxelWorldData.Block.CHEST)
	_logistics.advance(1.0)
	assert_int(_logistics.ore_count(Vector3i.ZERO)).is_equal(1)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.CHEST)
	_logistics.sample_belts()
	_logistics.advance(0.0)
	_logistics.advance(0.001)
	assert_int(_logistics.ore_count(Vector3i.RIGHT)).is_equal(0)
	_logistics.advance(STEP - 0.001)
	assert_int(_logistics.ore_count(Vector3i.RIGHT)).is_equal(1)


func test_all_cell_queries_reuse_one_sample_and_return_isolated_copies() -> void:
	_place(Vector3i.LEFT, VoxelWorldData.Block.MINER)
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.BELT)
	_logistics.advance(1.003)
	var before: int = _logistics.work_stats()["sample_solves"]
	var snapshot: Array[LogisticsOreQueue] = _logistics.sample_belts()
	for cell: Vector3i in _logistics.machine_cells():
		_logistics.belt_ores(cell)
	assert_int(_logistics.work_stats()["sample_solves"] - before).is_equal(1)
	for row: LogisticsOreQueue in snapshot:
		for ore: LogisticsOre in row.ores:
			ore.id = -1
			ore.progress = -1.0
	for cell: Vector3i in _logistics.machine_cells():
		for ore: LogisticsOre in _logistics.belt_ores(cell):
			assert_int(ore.id).is_greater(0)
			assert_float(ore.progress).is_greater_equal(0.0)


func test_partial_tick_edit_waits_for_boundary_and_keeps_actual_miner_phase() -> void:
	_logistics.configure_miners(0.01, 1)
	_place(Vector3i.LEFT, VoxelWorldData.Block.MINER)
	_logistics.advance(0.02)
	assert_int(_logistics.total_ore()).is_equal(1)
	_place(Vector3i.ZERO, VoxelWorldData.Block.CHEST)
	_place(Vector3i(4, 0, 0), VoxelWorldData.Block.MINER)
	_logistics.advance(0.01)
	assert_int(_logistics.ore_count(Vector3i.ZERO)).is_equal(0)
	assert_int(_logistics.ore_count(Vector3i(4, 0, 0))).is_equal(0)
	_logistics.advance(1.0 / 30.0 - 0.03)
	assert_int(_logistics.ore_count(Vector3i.ZERO)).is_equal(3)
	assert_int(_logistics.ore_count(Vector3i(4, 0, 0))).is_equal(1)


func test_second_edit_on_same_boundary_does_not_get_another_flush() -> void:
	_logistics.configure_miners(1.0, 1)
	_place(Vector3i.LEFT, VoxelWorldData.Block.MINER)
	_logistics.advance(1.0)
	_place(Vector3i.ZERO, VoxelWorldData.Block.CHEST)
	_logistics.advance(0.0000000001)
	assert_int(_logistics.ore_count(Vector3i.ZERO)).is_equal(1)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.CHEST)
	_logistics.advance(0.001)
	assert_int(_logistics.work_stats()["batches"]).is_equal(0)
	assert_int(_logistics.ore_count(Vector3i.RIGHT)).is_equal(0)
	_logistics.advance(STEP - 0.0010000001)
	assert_int(_logistics.ore_count(Vector3i.RIGHT)).is_equal(1)


func test_many_deleted_facilities_leave_only_compact_live_sampling_work() -> void:
	for x: int in range(-15, 15):
		for z: int in range(-15, 15):
			_place(Vector3i(x, 0, z), VoxelWorldData.Block.CHEST)
	_logistics.advance(STEP)
	# Populate the cache before deleting, so stale historical rows are observable.
	_logistics.sample_belts()
	for cell: Vector3i in _logistics.machine_cells():
		if cell != Vector3i.ZERO:
			_world.break_block(cell)
	assert_int(_logistics.machine_cells().size()).is_equal(1)
	assert_int(_logistics.work_stats()["cache_rows"]).is_equal(1)
	_logistics.sample_belts(0.001)
	assert_int(_logistics.work_stats()["sample"]).is_less_equal(16)
	_logistics.advance(STEP)
	assert_int(_logistics.work_stats()["advance"]).is_less_equal(80)
