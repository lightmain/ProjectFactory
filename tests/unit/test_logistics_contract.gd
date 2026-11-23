extends GdUnitTestSuite
## Public read contracts; queries must never advance authoritative rules.

const STEP: float = LogisticsData.LOGIC_STEP

var _world: VoxelWorldData
var _logistics: LogisticsData


func before_test() -> void:
	_world = VoxelWorldData.new()
	_world.generate_flat()
	_logistics = LogisticsData.new()
	_logistics.bind_world(_world)


func _place(cell: Vector3i, block: int, direction: Vector3i = Vector3i.RIGHT) -> void:
	assert_bool(_world.place_block(cell, block)).is_true()
	assert_bool(_logistics.set_direction(cell, direction)).is_true()


func _running_line() -> void:
	_place(Vector3i.LEFT, VoxelWorldData.Block.MINER)
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	_logistics.advance(1.125)


func _assert_samples(actual: Array[LogisticsOreQueue], expected: Array[LogisticsOreQueue]) -> void:
	assert_int(actual.size()).is_equal(expected.size())
	for index: int in range(mini(actual.size(), expected.size())):
		var row: LogisticsOreQueue = actual[index]
		var reference: LogisticsOreQueue = expected[index]
		assert_vector(row.cell).is_equal(reference.cell)
		assert_vector(row.direction).is_equal(reference.direction)
		assert_int(row.block).is_equal(reference.block)
		assert_int(row.ores.size()).is_equal(reference.ores.size())
		for ore_index: int in range(mini(row.ores.size(), reference.ores.size())):
			assert_int(row.ores[ore_index].id).is_equal(reference.ores[ore_index].id)
			assert_vector(row.ores[ore_index].incoming_direction).is_equal(reference.ores[ore_index].incoming_direction)
			assert_float(row.ores[ore_index].progress).is_equal_approx(reference.ores[ore_index].progress, 0.000001)


func test_candidates_keep_first_occurrence_order_and_skip_non_facilities() -> void:
	_place(Vector3i.LEFT, VoxelWorldData.Block.MINER)
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.CHEST)
	assert_bool(_world.place_block(Vector3i(3, 0, 0), VoxelWorldData.Block.STONE)).is_true()
	var rows: Array[LogisticsOreQueue] = _logistics.sample_cells([
		Vector3i.RIGHT, Vector3i.ZERO, Vector3i.RIGHT, Vector3i.LEFT, Vector3i.ZERO,
		Vector3i(3, 0, 0), Vector3i(4, 0, 0), Vector3i(1000000, 0, 0),
	])
	assert_int(rows.size()).is_equal(3)
	if rows.size() != 3:
		return
	var cells: Array[Vector3i] = [Vector3i.RIGHT, Vector3i.ZERO, Vector3i.LEFT]
	var blocks: Array[int] = [VoxelWorldData.Block.CHEST, VoxelWorldData.Block.BELT, VoxelWorldData.Block.MINER]
	for index: int in range(3):
		assert_vector(rows[index].cell).is_equal(cells[index])
		assert_int(rows[index].block).is_equal(blocks[index])
		# Requested directions have not reached a settlement boundary yet.
		assert_vector(rows[index].direction).is_equal(Vector3i.FORWARD)
		assert_int(rows[index].ores.size()).is_equal(0)


func test_empty_or_invalid_candidates_do_not_prepare_a_sample() -> void:
	_running_line()
	var before: Dictionary[String, int] = _logistics.work_stats()
	assert_int(_logistics.sample_cells([]).size()).is_equal(0)
	assert_int(_logistics.sample_cells([
		Vector3i(4, 0, 0), Vector3i(0, -1, 0), Vector3i(1000000, 0, 0),
	], 100.0).size()).is_equal(0)
	assert_bool(_logistics.work_stats() == before).is_true()
	assert_int(before["sample_solves"]).is_equal(0)


func test_rows_ores_and_containers_are_independent_of_cache_and_authority() -> void:
	_running_line()
	var before: Dictionary = _logistics.save_state()
	var expected: Array[LogisticsOreQueue] = _logistics.sample_cells([Vector3i.ZERO])
	assert_int(expected.size()).is_equal(1)
	if expected.is_empty():
		return
	assert_int(expected[0].ores.size()).is_equal(1)
	var changed: Array[LogisticsOreQueue] = _logistics.sample_cells([Vector3i.ZERO])
	assert_int(changed.size()).is_equal(1)
	if changed.is_empty():
		return
	assert_int(changed[0].ores.size()).is_equal(1)
	assert_bool(is_same(changed[0], expected[0])).is_false()
	if changed[0].ores.is_empty() or expected[0].ores.is_empty():
		return
	assert_bool(is_same(changed[0].ores[0], expected[0].ores[0])).is_false()
	changed[0].cell = Vector3i.LEFT
	changed[0].direction = Vector3i.BACK
	changed[0].block = VoxelWorldData.Block.CHEST
	changed[0].ores[0].id = -1
	changed[0].ores[0].incoming_direction = Vector3i.BACK
	changed[0].ores[0].progress = -1.0
	changed[0].ores.clear()
	changed.clear()
	_assert_samples(_logistics.sample_cells([Vector3i.ZERO]), expected)
	var full: Array[LogisticsOreQueue] = _logistics.sample_belts()
	for row: LogisticsOreQueue in full:
		if row.cell == Vector3i.ZERO:
			_assert_samples([row], expected)
	_assert_samples([_row_from_single_cell()], expected)
	assert_bool(_logistics.save_state() == before).is_true()


func _row_from_single_cell() -> LogisticsOreQueue:
	var row: LogisticsOreQueue = LogisticsOreQueue.new()
	row.cell = Vector3i.ZERO
	row.direction = Vector3i.RIGHT
	row.ores = _logistics.belt_ores(Vector3i.ZERO)
	return row


func test_queries_preserve_pending_rotation_production_and_edit_settlement() -> void:
	_running_line()
	assert_bool(_logistics.set_direction(Vector3i.ZERO, Vector3i.BACK)).is_true()
	_place(Vector3i(4, 0, 0), VoxelWorldData.Block.MINER)
	var before: Dictionary = _logistics.save_state()
	var rows: Array[LogisticsOreQueue] = _logistics.sample_cells([Vector3i.ZERO], 100.0)
	assert_int(rows.size()).is_equal(1)
	if rows.size() != 1:
		return
	assert_vector(rows[0].direction).is_equal(Vector3i.RIGHT)
	assert_vector(_logistics.direction_at(Vector3i.ZERO)).is_equal(Vector3i.BACK)
	_logistics.sample_cells([Vector3i(4, 0, 0)], NAN)
	_logistics.sample_belts(100.0)
	_logistics.belt_ores(Vector3i.ZERO, 100.0)
	assert_bool(_logistics.save_state() == before).is_true()
	assert_int(_logistics.ore_count(Vector3i(4, 0, 0))).is_equal(0)
	_logistics.advance(STEP)
	rows = _logistics.sample_cells([Vector3i.ZERO])
	assert_vector(rows[0].direction).is_equal(Vector3i.BACK)


func test_prediction_time_is_finite_bounded_and_shared_across_query_shapes() -> void:
	_running_line()
	var current: Array[LogisticsOreQueue] = _logistics.sample_cells([Vector3i.ZERO])
	assert_int(current.size()).is_equal(1)
	if current.is_empty():
		return
	assert_int(current[0].ores.size()).is_equal(1)
	if current[0].ores.is_empty():
		return
	var solves: int = _logistics.work_stats()["sample_solves"]
	for extra: float in [-1.0, NAN, INF, -INF, 0.0]:
		_assert_samples(_logistics.sample_cells([Vector3i.ZERO], extra), current)
	_logistics.sample_belts()
	_logistics.belt_ores(Vector3i.ZERO)
	assert_int(_logistics.work_stats()["sample_solves"]).is_equal(solves)
	assert_float(current[0].ores[0].progress).is_equal_approx(0.25, 0.000001)
	var predicted: Array[LogisticsOreQueue] = _logistics.sample_cells([Vector3i.ZERO], 100.0)
	assert_float(predicted[0].ores[0].progress).is_equal_approx(16.0 / 60.0, 0.000001)
	_assert_samples(_logistics.sample_cells([Vector3i.ZERO], STEP), predicted)
	_assert_samples(_logistics.sample_cells([Vector3i.ZERO]), current)


func test_unsampled_downstream_still_constrains_prediction_and_release() -> void:
	_logistics.configure_miners(0.1, 8)
	_place(Vector3i.LEFT, VoxelWorldData.Block.MINER)
	for x: int in range(3):
		_place(Vector3i(x, 0, 0), VoxelWorldData.Block.BELT)
	_logistics.advance(5.0)
	var blocked: Array[LogisticsOreQueue] = _logistics.sample_cells([Vector3i.ZERO], 100.0)
	assert_int(blocked.size()).is_equal(1)
	if blocked.is_empty():
		return
	assert_int(blocked[0].ores.size()).is_equal(2)
	if blocked[0].ores.size() != 2:
		return
	assert_float(blocked[0].ores[0].progress).is_equal_approx(1.0, 0.000001)
	assert_float(blocked[0].ores[1].progress).is_equal_approx(0.5, 0.000001)
	var before: Dictionary = _logistics.save_state()
	_assert_samples(_logistics.sample_cells([Vector3i.ZERO], 100.0), blocked)
	assert_bool(_logistics.save_state() == before).is_true()
	_place(Vector3i(3, 0, 0), VoxelWorldData.Block.CHEST)
	_logistics.advance(0.125)
	var released: Array[LogisticsOreQueue] = _logistics.sample_cells([Vector3i.ZERO])
	assert_int(released.size()).is_equal(1)
	if released.size() != 1:
		return
	assert_int(released[0].ores.size()).is_equal(2)
	if released[0].ores.size() != 2:
		return
	assert_int(released[0].ores[0].id).is_equal(blocked[0].ores[1].id)
	assert_float(released[0].ores[0].progress).is_equal_approx(0.75, 0.000001)


func test_removal_replacement_and_reset_retire_sampled_rows_immediately() -> void:
	_running_line()
	_place(Vector3i(4, 0, 0), VoxelWorldData.Block.CHEST)
	_logistics.sample_cells([Vector3i.ZERO, Vector3i(4, 0, 0)])
	assert_bool(_world.break_block(Vector3i.ZERO)).is_true()
	var rows: Array[LogisticsOreQueue] = _logistics.sample_cells([Vector3i.ZERO, Vector3i(4, 0, 0)])
	assert_int(rows.size()).is_equal(1)
	if rows.size() != 1:
		return
	assert_vector(rows[0].cell).is_equal(Vector3i(4, 0, 0))
	_place(Vector3i.ZERO, VoxelWorldData.Block.CHEST)
	rows = _logistics.sample_cells([Vector3i.ZERO])
	assert_int(rows.size()).is_equal(1)
	assert_int(rows[0].block).is_equal(VoxelWorldData.Block.CHEST)
	assert_int(rows[0].ores.size()).is_equal(0)
	_world.generate_flat()
	assert_int(_logistics.sample_cells([Vector3i.ZERO, Vector3i(4, 0, 0)]).size()).is_equal(0)
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	rows = _logistics.sample_cells([Vector3i.ZERO])
	assert_int(rows.size()).is_equal(1)
	assert_int(rows[0].block).is_equal(VoxelWorldData.Block.BELT)
	assert_int(rows[0].ores.size()).is_equal(0)


func test_restore_replaces_cached_predictions_and_keeps_pending_edits() -> void:
	_running_line()
	assert_bool(_logistics.set_direction(Vector3i.ZERO, Vector3i.BACK)).is_true()
	var saved: Dictionary = _logistics.save_state()
	var expected: Array[LogisticsOreQueue] = _logistics.sample_cells([Vector3i.ZERO], 0.002)
	assert_int(expected.size()).is_equal(1)
	_logistics.advance(0.1)
	_logistics.sample_cells([Vector3i.ZERO], 0.002)
	assert_bool(_logistics.restore_state(saved)).is_true()
	_assert_samples(_logistics.sample_cells([Vector3i.ZERO], 0.002), expected)
	assert_bool(_logistics.save_state() == saved).is_true()


func test_return_copy_counts_include_cache_hits_empty_queries_and_keep_single_cell_separate() -> void:
	_running_line()
	var before: Dictionary = _logistics.save_state()
	_logistics.sample_cells([Vector3i.ZERO, Vector3i.ZERO])
	assert_int(_logistics.work_stats()["sample_return_rows"]).is_equal(1)
	assert_int(_logistics.work_stats()["sample_return_ores"]).is_equal(1)
	var solves: int = _logistics.work_stats()["sample_solves"]
	_logistics.sample_cells([Vector3i.ZERO])
	assert_int(_logistics.work_stats()["sample_solves"]).is_equal(solves)
	assert_int(_logistics.work_stats()["sample_return_rows"]).is_equal(1)
	assert_int(_logistics.work_stats()["sample_return_ores"]).is_equal(1)
	_logistics.sample_belts()
	assert_int(_logistics.work_stats()["sample_return_rows"]).is_equal(2)
	assert_int(_logistics.work_stats()["sample_return_ores"]).is_equal(1)
	_logistics.belt_ores(Vector3i.ZERO)
	assert_int(_logistics.work_stats()["sample_return_rows"]).is_equal(2)
	assert_int(_logistics.work_stats()["sample_return_ores"]).is_equal(1)
	_logistics.sample_cells([])
	assert_int(_logistics.work_stats()["sample_return_rows"]).is_equal(0)
	assert_int(_logistics.work_stats()["sample_return_ores"]).is_equal(0)
	_logistics.sample_cells([Vector3i(1000000, 0, 0)])
	assert_int(_logistics.work_stats()["sample_return_rows"]).is_equal(0)
	assert_int(_logistics.work_stats()["sample_return_ores"]).is_equal(0)
	assert_int(_logistics.work_stats()["sample_solves"]).is_equal(solves)
	assert_bool(_logistics.save_state() == before).is_true()
