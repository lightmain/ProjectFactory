extends GdUnitTestSuite

var _world: VoxelWorldData
var _logistics: LogisticsData
var _build: BeltPlacement


func before_test() -> void:
	_world = VoxelWorldData.new()
	_world.generate_flat()
	_logistics = LogisticsData.new()
	_logistics.bind_world(_world)
	_build = BeltPlacement.new()
	_build.bind_world(_world, _logistics)


func _ground(cell: Vector3i) -> VoxelHit:
	return VoxelHit.new(cell + Vector3i.DOWN, Vector3i.UP, 1.0)


func test_straight_empty_terminal_counts_as_a_downhill_cell_in_all_directions() -> void:
	for facing: Vector3i in VoxelWorldData.SLOPE_DIRECTIONS:
		_build.cancel()
		assert_bool(_build.begin(_ground(Vector3i(0, 4, 0)), facing)).is_true()
		_build.preview(_ground(facing * 3), facing)
		assert_str(_build.error).is_empty()
		if not _build.error.is_empty():
			continue
		var down: int = VoxelWorldData.Block.BELT_DOWN + VoxelWorldData.SLOPE_DIRECTIONS.find(facing)
		assert_array(_build.blocks).contains_exactly([down, down, down, down])
		assert_array(_build.path).contains_exactly([
			Vector3i(0, 3, 0), facing + Vector3i(0, 2, 0),
			facing * 2 + Vector3i.UP, facing * 3,
		])
		assert_vector(_build.directions[-1]).is_equal(facing)
		_build.begin(_ground(Vector3i(0, 5, 0)), facing)
		_build.preview(_ground(facing * 3), facing)
		assert_str(_build.error).is_equal("直线坡道不足，无法连接高度")
		assert_bool(_build.commit()).is_false()


func test_c_preserves_terminal_downhill_and_starts_at_its_forward_exit_cell() -> void:
	_build.begin(_ground(Vector3i(0, 4, 0)), Vector3i.RIGHT)
	_build.preview(_ground(Vector3i(3, 0, 0)), Vector3i.RIGHT)
	assert_str(_build.error).is_empty()
	if not _build.error.is_empty():
		return
	assert_bool(_build.lock_preview()).is_true()
	var prefix: Array[Vector3i] = _build.path.duplicate()
	var kinds: Array[int] = _build.blocks.duplicate()
	var facing: Array[Vector3i] = _build.directions.duplicate()
	# Refreshing the target immediately after C must not create a return leg.
	_build.preview(_ground(Vector3i(3, 0, 0)), Vector3i.LEFT)
	assert_str(_build.error).is_empty()
	assert_array(_build.path).contains_exactly(prefix)
	assert_array(_build.blocks).contains_exactly(kinds)
	assert_bool(_build.lock_preview()).is_true()
	_build.preview(_ground(Vector3i(5, 0, 0)), Vector3i.LEFT)
	assert_str(_build.error).is_empty()
	assert_array(_build.path.slice(0, prefix.size())).contains_exactly(prefix)
	assert_array(_build.blocks.slice(0, prefix.size())).contains_exactly(kinds)
	assert_array(_build.directions.slice(0, prefix.size())).contains_exactly(facing)
	assert_vector(_build.path[prefix.size()]).is_equal(Vector3i(4, 0, 0))
	assert_bool(_build.commit()).is_true()
	assert_int(_world.get_block(Vector3i(3, 0, 0))).is_equal(16)
	assert_int(_world.get_block(Vector3i(4, 0, 0))).is_equal(6)


func test_c_downhill_can_turn_only_in_the_new_cell_and_r_keeps_the_slope() -> void:
	_build.begin(_ground(Vector3i(0, 4, 0)), Vector3i.RIGHT)
	_build.preview(_ground(Vector3i(3, 0, 0)), Vector3i.RIGHT)
	assert_str(_build.error).is_empty()
	if not _build.error.is_empty():
		return
	_build.lock_preview()
	var prefix: Array[Vector3i] = _build.path.duplicate()
	for north_first: bool in [true, false]:
		if _build.north_south_first != north_first:
			_build.toggle_route_order()
		_build.preview(_ground(Vector3i(6, 0, 2)), Vector3i.LEFT)
		assert_str(_build.error).is_empty()
		assert_array(_build.path.slice(0, prefix.size())).contains_exactly(prefix)
		assert_int(_build.blocks[prefix.size() - 1]).is_equal(16)
		assert_vector(_build.directions[prefix.size() - 1]).is_equal(Vector3i.RIGHT)
		assert_vector(_build.path[prefix.size()]).is_equal(Vector3i(4, 0, 0))
		assert_int(_build.blocks[prefix.size()]).is_equal(6)
	assert_bool(_build.commit()).is_true()


func test_repeated_c_can_continue_descending_and_deliver_directly_to_chest() -> void:
	_world.place_block(Vector3i(-1, 5, 0), VoxelWorldData.Block.MINER)
	_logistics.set_direction(Vector3i(-1, 5, 0), Vector3i.RIGHT)
	_build.begin(_ground(Vector3i(0, 5, 0)), Vector3i.RIGHT)
	for end: Vector3i in [Vector3i(1, 3, 0), Vector3i(3, 1, 0), Vector3i(4, 0, 0)]:
		_build.preview(_ground(end), Vector3i.RIGHT)
		assert_str(_build.error).is_empty()
		if not _build.error.is_empty():
			return
		assert_int(_build.blocks[-1]).is_equal(16)
		assert_bool(_build.lock_preview()).is_true()
	# An existing chest directly ahead is reached from the immutable slope.
	_world.place_block(Vector3i(5, 0, 0), VoxelWorldData.Block.CHEST)
	_logistics.set_direction(Vector3i(5, 0, 0), Vector3i.RIGHT)
	_build.preview(VoxelHit.new(Vector3i(5, 0, 0), Vector3i.UP, 1.0), Vector3i.RIGHT)
	assert_str(_build.error).is_empty()
	assert_int(_build.blocks[-2]).is_equal(16)
	assert_bool(_build.commit()).is_true()
	_logistics.advance(15.0)
	assert_int(_logistics.ore_count(Vector3i(5, 0, 0))).is_greater(0)


func test_turn_after_locked_downhill_does_not_add_slope_capacity_to_the_corner() -> void:
	_build.begin(_ground(Vector3i(0, 5, 0)), Vector3i.RIGHT)
	_build.preview(_ground(Vector3i(1, 3, 0)), Vector3i.RIGHT)
	assert_str(_build.error).is_empty()
	if not _build.error.is_empty():
		return
	_build.lock_preview()
	var prefix: Array[Vector3i] = _build.locked_path.duplicate()
	_build.preview(_ground(Vector3i(2, 1, 1)), Vector3i.RIGHT)
	assert_str(_build.error).is_equal("直线坡道不足，无法连接高度")
	assert_bool(_build.commit()).is_false()
	_build.preview(_ground(Vector3i(2, 1, 2)), Vector3i.RIGHT)
	assert_str(_build.error).is_empty()
	if not _build.error.is_empty():
		return
	assert_array(_build.path.slice(0, prefix.size())).contains_exactly(prefix)
	assert_vector(_build.path[prefix.size()]).is_equal(Vector3i(2, 3, 0))
	assert_int(_build.blocks[prefix.size()]).is_equal(6)
	assert_array(_build.blocks.slice(prefix.size() + 1)).contains_exactly([13, 13])
	assert_bool(_build.commit()).is_true()


func test_blocked_forward_exit_rejects_extension_without_partial_commit() -> void:
	_build.begin(_ground(Vector3i(0, 4, 0)), Vector3i.RIGHT)
	_build.preview(_ground(Vector3i(3, 0, 0)), Vector3i.RIGHT)
	assert_str(_build.error).is_empty()
	if not _build.error.is_empty():
		return
	_build.lock_preview()
	var prefix: Array[Vector3i] = _build.locked_path.duplicate()
	_world.place_block(Vector3i(4, 0, 0), VoxelWorldData.Block.STONE)
	var count: int = _world.block_count()
	_build.preview(_ground(Vector3i(6, 0, 0)), Vector3i.RIGHT)
	assert_str(_build.error).is_not_empty()
	assert_bool(_build.lock_preview()).is_false()
	assert_bool(_build.commit()).is_false()
	assert_array(_build.locked_path).contains_exactly(prefix)
	assert_int(_world.block_count()).is_equal(count)
	assert_int(_world.get_block(Vector3i(3, 0, 0))).is_equal(0)
	_world.break_block(Vector3i(4, 0, 0))
	_build.preview(_ground(Vector3i(6, 0, 0)), Vector3i.RIGHT)
	assert_str(_build.error).is_empty()
	_world.place_block(Vector3i(4, 0, 0), VoxelWorldData.Block.STONE)
	assert_bool(_build.commit()).is_false()
	assert_array(_build.locked_path).contains_exactly(prefix)
	assert_int(_world.block_count()).is_equal(count)


func test_single_c_flat_start_still_cannot_slope_but_terminal_can_descend() -> void:
	_build.begin(_ground(Vector3i(0, 3, 0)), Vector3i.RIGHT)
	_build.preview(_ground(Vector3i(0, 3, 0)), Vector3i.RIGHT)
	_build.lock_preview()
	_build.preview(_ground(Vector3i(2, 0, 0)), Vector3i.RIGHT)
	assert_str(_build.error).is_equal("直线坡道不足，无法连接高度")
	_build.preview(_ground(Vector3i(3, 0, 0)), Vector3i.RIGHT)
	assert_str(_build.error).is_empty()
	if not _build.error.is_empty():
		return
	assert_array(_build.blocks).contains_exactly([6, 16, 16, 16])
	assert_vector(_build.path[0]).is_equal(Vector3i(0, 3, 0))
	assert_bool(_build.commit()).is_true()
