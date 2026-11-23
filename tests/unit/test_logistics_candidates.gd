extends GdUnitTestSuite
## Spatial queries are conservative data reads, independent of settlement.

var _world: VoxelWorldData
var _logistics: LogisticsData


func before_test() -> void:
	_world = VoxelWorldData.new()
	assert_bool(_world.generate_flat(Vector3i(-32, -2, -32), Vector3i(32, 16, 32), 2)).is_true()
	_logistics = LogisticsData.new()
	_logistics.bind_world(_world)


func _place(cell: Vector3i, block: int = VoxelWorldData.Block.BELT) -> void:
	assert_bool(_world.place_block(cell, block)).is_true()


func _assert_cells(actual: Array[Vector3i], expected: Array[Vector3i]) -> void:
	assert_int(actual.size()).is_equal(expected.size())
	for cell: Vector3i in expected:
		assert_bool(actual.has(cell)).is_true()
	var distinct: Dictionary[Vector3i, bool] = {}
	for cell: Vector3i in actual:
		distinct[cell] = true
	assert_int(distinct.size()).is_equal(actual.size())


func test_range_includes_both_ends_and_all_facility_types_in_three_dimensions() -> void:
	var low: Vector3i = Vector3i(-8, 0, -8)
	var high: Vector3i = Vector3i(0, 8, 0)
	var expected: Array[Vector3i] = [low, high, Vector3i(-1, 3, -1)]
	_place(low, VoxelWorldData.Block.MINER)
	_place(high, VoxelWorldData.Block.CHEST)
	_place(expected[2], VoxelWorldData.Block.BELT_UP_NORTH)
	for cell: Vector3i in [Vector3i(-9, 0, -8), Vector3i(0, 9, 0), Vector3i(0, 0, 1)]:
		_place(cell)
	_place(Vector3i(-4, 0, -4), VoxelWorldData.Block.STONE)
	_assert_cells(_logistics.candidate_cells(low, high), expected)
	_assert_cells(_logistics.candidate_cells(high, high), [high])


func test_inverted_disjoint_and_empty_queries_do_no_sample_or_index_work() -> void:
	_place(Vector3i.ZERO)
	for axis: Vector3i in [Vector3i.RIGHT, Vector3i.UP, Vector3i.BACK]:
		_assert_cells(_logistics.candidate_cells(axis, Vector3i.ZERO), [])
		assert_int(_logistics.work_stats().get("candidate_partitions", -1)).is_equal(0)
	_assert_cells(_logistics.candidate_cells(Vector3i(32, 0, 0), Vector3i(1000000, 1000000, 1000000)), [])
	var stats: Dictionary[String, int] = _logistics.work_stats()
	assert_int(stats.get("candidate_partitions", -1)).is_equal(0)
	assert_int(stats.get("candidate_checks", -1)).is_equal(0)
	assert_int(stats.get("candidate_copies", -1)).is_equal(0)
	assert_int(stats["sample_solves"]).is_equal(0)


func test_world_intersection_uses_exclusive_world_maximum_and_clamps_extreme_input() -> void:
	var last: Vector3i = _world.maximum - Vector3i.ONE
	_place(_world.minimum + Vector3i.UP * 2)
	_place(last)
	var expected: Array[Vector3i] = [_world.minimum + Vector3i.UP * 2, last]
	_assert_cells(_logistics.candidate_cells(Vector3i.ONE * -2000000000, Vector3i.ONE * 2000000000), expected)
	assert_int(_logistics.work_stats().get("candidate_partitions", -1)).is_equal(192)
	_assert_cells(_logistics.candidate_cells(_world.maximum, _world.maximum), [])


func test_negative_partition_boundary_and_returned_container_are_independent() -> void:
	_place(Vector3i.LEFT)
	_place(Vector3i.ZERO)
	var cells: Array[Vector3i] = _logistics.candidate_cells(Vector3i.LEFT, Vector3i.ZERO)
	_assert_cells(cells, [Vector3i.LEFT, Vector3i.ZERO])
	assert_int(_logistics.work_stats().get("candidate_partitions", -1)).is_equal(2)
	assert_int(_logistics.work_stats().get("candidate_partition_count", -1)).is_equal(2)
	cells.clear()
	_assert_cells(_logistics.candidate_cells(Vector3i.LEFT, Vector3i.ZERO), [Vector3i.LEFT, Vector3i.ZERO])


func test_non_last_removal_replacement_and_rotation_keep_index_current() -> void:
	for cell: Vector3i in [Vector3i.LEFT, Vector3i.ZERO, Vector3i(16, 0, 16)]:
		_place(cell)
	assert_bool(_world.break_block(Vector3i.ZERO)).is_true()
	_assert_cells(_logistics.candidate_cells(Vector3i.ZERO, Vector3i.ZERO), [])
	_assert_cells(_logistics.candidate_cells(Vector3i(16, 0, 16), Vector3i(16, 0, 16)), [Vector3i(16, 0, 16)])
	_place(Vector3i.ZERO, VoxelWorldData.Block.CHEST)
	assert_bool(_logistics.set_direction(Vector3i.ZERO, Vector3i.BACK)).is_true()
	_assert_cells(_logistics.candidate_cells(Vector3i.LEFT, Vector3i.ZERO), [Vector3i.LEFT, Vector3i.ZERO])
	for cell: Vector3i in [Vector3i.LEFT, Vector3i.ZERO, Vector3i(16, 0, 16)]:
		assert_bool(_world.break_block(cell)).is_true()
	_assert_cells(_logistics.candidate_cells(_world.minimum, _world.maximum), [])
	assert_int(_logistics.work_stats().get("candidate_partition_count", -1)).is_equal(0)


func test_reset_rebind_and_both_snapshot_encodings_rebuild_index() -> void:
	_place(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	_logistics.advance(1.0)
	var ordinary: Dictionary = _logistics.save_state()
	var packed: Dictionary = _logistics.save_packed_state()
	for saved: Dictionary in [ordinary, packed]:
		_logistics.advance(0.125)
		assert_bool(_logistics.restore_state(saved)).is_true()
		_assert_cells(_logistics.candidate_cells(Vector3i.ZERO, Vector3i.ZERO), [Vector3i.ZERO])
	assert_bool(_world.generate_flat(Vector3i(-16, -2, -16), Vector3i(16, 8, 16), 2)).is_true()
	_assert_cells(_logistics.candidate_cells(Vector3i.ZERO, Vector3i.ZERO), [])
	assert_int(_logistics.work_stats().get("candidate_partition_count", -1)).is_equal(0)
	var replacement: VoxelWorldData = VoxelWorldData.new()
	assert_bool(replacement.generate_flat(Vector3i(64, -2, 64), Vector3i(80, 8, 80), 2)).is_true()
	assert_bool(replacement.place_block(Vector3i(64, 0, 64), VoxelWorldData.Block.BELT)).is_true()
	_logistics.bind_world(replacement)
	_place(Vector3i.ZERO)
	_assert_cells(_logistics.candidate_cells(Vector3i(-100, -100, -100), Vector3i(100, 100, 100)), [Vector3i(64, 0, 64)])


func test_query_preserves_pending_edits_production_and_predictive_cache() -> void:
	_place(Vector3i.LEFT, VoxelWorldData.Block.MINER)
	_place(Vector3i.ZERO)
	assert_bool(_logistics.set_direction(Vector3i.LEFT, Vector3i.RIGHT)).is_true()
	_logistics.advance(1.125)
	_logistics.sample_cells([Vector3i.ZERO], 0.002)
	assert_bool(_logistics.set_direction(Vector3i.ZERO, Vector3i.BACK)).is_true()
	_place(Vector3i(2, 0, 0), VoxelWorldData.Block.MINER)
	var before: Dictionary = _logistics.save_state()
	var stats: Dictionary[String, int] = _logistics.work_stats()
	_assert_cells(_logistics.candidate_cells(Vector3i.LEFT, Vector3i(2, 0, 0)), [
		Vector3i.LEFT, Vector3i.ZERO, Vector3i(2, 0, 0),
	])
	assert_bool(_logistics.save_state() == before).is_true()
	assert_int(_logistics.work_stats()["sample_solves"]).is_equal(stats["sample_solves"])
	assert_int(_logistics.ore_count(Vector3i(2, 0, 0))).is_equal(0)


func test_rejected_restore_leaves_active_index_state_and_counters_unchanged() -> void:
	_place(Vector3i.ZERO)
	_place(Vector3i(16, 0, 16), VoxelWorldData.Block.CHEST)
	var ordinary: Dictionary = _logistics.save_state()
	var packed: Dictionary = _logistics.save_packed_state()
	var bad_rows: Array = ordinary["machines"]
	var bad_row: Dictionary = bad_rows[-1]
	bad_row["cell"] = Vector3i(7, 1, 7)
	var bad_outgoing: PackedInt32Array = packed["outgoing"]
	bad_outgoing[-1] = 999999
	packed["outgoing"] = bad_outgoing
	var before: Dictionary = _logistics.save_state()
	var expected: Array[Vector3i] = [Vector3i.ZERO, Vector3i(16, 0, 16)]
	_assert_cells(_logistics.candidate_cells(Vector3i.ZERO, Vector3i(16, 0, 16)), expected)
	var stats: Dictionary[String, int] = _logistics.work_stats()
	for invalid: Dictionary in [ordinary, packed]:
		assert_bool(_logistics.restore_state(invalid)).is_false()
		assert_bool(_logistics.save_state() == before).is_true()
		assert_bool(_logistics.work_stats() == stats).is_true()
		_assert_cells(_logistics.candidate_cells(Vector3i.ZERO, Vector3i(16, 0, 16)), expected)
		assert_bool(_logistics.work_stats() == stats).is_true()


func test_fixed_query_work_does_not_grow_with_distant_facilities() -> void:
	_place(Vector3i.ZERO)
	_place(Vector3i(7, 0, 7))
	_assert_cells(_logistics.candidate_cells(Vector3i.ZERO, Vector3i.ZERO), [Vector3i.ZERO])
	var before: Dictionary[String, int] = _logistics.work_stats()
	assert_int(before.get("candidate_partitions", -1)).is_equal(1)
	assert_int(before.get("candidate_checks", -1)).is_equal(2)
	assert_int(before.get("candidate_copies", -1)).is_equal(1)
	for x: int in range(16, 32):
		for z: int in range(-32, 0):
			_place(Vector3i(x, 0, z))
	_assert_cells(_logistics.candidate_cells(Vector3i.ZERO, Vector3i.ZERO), [Vector3i.ZERO])
	var after: Dictionary[String, int] = _logistics.work_stats()
	for key: String in ["candidate_partitions", "candidate_checks", "candidate_copies"]:
		assert_int(after.get(key, -1)).is_equal(before.get(key, -2))
	assert_int(after.get("candidate_partition_count", -1)).is_greater(before.get("candidate_partition_count", -1))
