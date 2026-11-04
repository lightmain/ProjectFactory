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


func _machine(cell: Vector3i) -> VoxelHit:
	return VoxelHit.new(cell, Vector3i.UP, 1.0)


func test_first_click_is_reversible_and_second_builds_the_visible_route() -> void:
	assert_bool(_build.begin(_ground(Vector3i.ZERO), Vector3i.RIGHT)).is_true()
	assert_bool(_build.active).is_true()
	assert_int(_world.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)
	_build.preview(_ground(Vector3i(3, 0, 0)), Vector3i.RIGHT)
	assert_array(_build.path).contains_exactly([
		Vector3i.ZERO, Vector3i.RIGHT, Vector3i(2, 0, 0), Vector3i(3, 0, 0),
	])
	assert_bool(_build.commit()).is_true()
	assert_bool(_build.active).is_false()
	for x: int in range(4):
		assert_int(_world.get_block(Vector3i(x, 0, 0))).is_equal(VoxelWorldData.Block.BELT)
		assert_vector(_logistics.direction_at(Vector3i(x, 0, 0))).is_equal(Vector3i.RIGHT)


func test_route_avoids_obstacles_and_locks_the_entire_prefix_more_than_once() -> void:
	_world.place_block(Vector3i.RIGHT, VoxelWorldData.Block.STONE)
	_build.begin(_ground(Vector3i.ZERO), Vector3i.RIGHT)
	_build.preview(_ground(Vector3i(3, 0, 0)), Vector3i.RIGHT)
	assert_str(_build.error).is_empty()
	assert_array(_build.path).has_size(6)
	assert_array(_build.path).not_contains(Vector3i.RIGHT)
	var prefix: Array[Vector3i] = _build.path.duplicate()
	assert_bool(_build.lock_preview()).is_true()
	_build.preview(_ground(Vector3i(4, 0, 2)), Vector3i.RIGHT)
	assert_array(_build.path.slice(0, prefix.size())).contains_exactly(prefix)
	assert_bool(_build.lock_preview()).is_true()
	var second: Array[Vector3i] = _build.locked_path.duplicate()
	_build.preview(_ground(Vector3i(6, 0, 2)), Vector3i.RIGHT)
	assert_array(_build.path.slice(0, second.size())).contains_exactly(second)
	_build.cancel()
	assert_bool(_build.active).is_false()
	assert_int(_logistics.machine_cells().size()).is_equal(0)


func test_belt_wall_shows_crossing_and_rejects_both_keys_without_losing_prefix() -> void:
	for z: int in range(VoxelWorldData.MIN_CELL.z, VoxelWorldData.MAX_CELL.z):
		_world.place_block(Vector3i(1, 0, z), VoxelWorldData.Block.BELT)
	_build.begin(_ground(Vector3i.ZERO), Vector3i.RIGHT)
	_build.preview(_ground(Vector3i(3, 0, 0)), Vector3i.RIGHT)
	assert_str(_build.error).is_equal("与现有传送带交叉")
	assert_array(_build.path).contains(Vector3i.RIGHT)
	var prefix: Array[Vector3i] = _build.locked_path.duplicate()
	assert_bool(_build.lock_preview()).is_false()
	assert_bool(_build.commit()).is_false()
	assert_bool(_build.active).is_true()
	assert_array(_build.locked_path).contains_exactly(prefix)
	assert_int(_world.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)


func test_height_mismatch_and_later_obstruction_never_partially_build() -> void:
	_build.begin(_ground(Vector3i.ZERO), Vector3i.RIGHT)
	_build.preview(_ground(Vector3i(3, 1, 0)), Vector3i.RIGHT)
	assert_str(_build.error).is_equal("暂不支持高低差传送带")
	assert_bool(_build.commit()).is_false()
	assert_bool(_build.active).is_true()
	_build.preview(_ground(Vector3i(3, 0, 0)), Vector3i.RIGHT)
	_world.place_block(Vector3i(2, 0, 0), VoxelWorldData.Block.STONE)
	assert_bool(_build.commit()).is_false()
	assert_int(_world.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)
	assert_int(_world.get_block(Vector3i.RIGHT)).is_equal(VoxelWorldData.Block.AIR)


func test_machine_endpoints_snap_to_fixed_output_and_input() -> void:
	_world.place_block(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	_logistics.set_direction(Vector3i.ZERO, Vector3i.RIGHT)
	_world.place_block(Vector3i(4, 0, 2), VoxelWorldData.Block.CHEST)
	_logistics.set_direction(Vector3i(4, 0, 2), Vector3i.BACK)
	_build.begin(_machine(Vector3i.ZERO), Vector3i.FORWARD)
	_build.preview(_machine(Vector3i(4, 0, 2)), Vector3i.FORWARD)
	assert_str(_build.error).is_empty()
	assert_vector(_build.path[1]).is_equal(Vector3i.RIGHT)
	assert_vector(_build.path[-2]).is_equal(Vector3i(4, 0, 1))
	assert_bool(_build.commit()).is_true()
	assert_vector(_logistics.direction_at(Vector3i.ZERO)).is_equal(Vector3i.RIGHT)
	assert_vector(_logistics.direction_at(Vector3i(4, 0, 2))).is_equal(Vector3i.BACK)
	assert_vector(_logistics.direction_at(Vector3i(4, 0, 1))).is_equal(Vector3i.BACK)


func test_belt_start_rotates_only_on_commit_and_terminal_keeps_its_direction() -> void:
	_world.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	_logistics.set_direction(Vector3i.ZERO, Vector3i.FORWARD)
	_world.place_block(Vector3i(3, 0, 0), VoxelWorldData.Block.BELT)
	_logistics.set_direction(Vector3i(3, 0, 0), Vector3i.BACK)
	_build.begin(_machine(Vector3i.ZERO), Vector3i.RIGHT)
	_build.preview(_machine(Vector3i(3, 0, 0)), Vector3i.RIGHT)
	assert_vector(_logistics.direction_at(Vector3i.ZERO)).is_equal(Vector3i.FORWARD)
	assert_bool(_build.lock_preview()).is_false()
	# C rejecting an existing belt endpoint must not invalidate the route.
	assert_bool(_build.commit()).is_true()
	assert_vector(_logistics.direction_at(Vector3i.ZERO)).is_equal(Vector3i.RIGHT)
	assert_vector(_logistics.direction_at(Vector3i(3, 0, 0))).is_equal(Vector3i.BACK)


func test_straight_route_and_no_target_preserves_session() -> void:
	_build.begin(_ground(Vector3i.ZERO), Vector3i.RIGHT)
	_build.preview(_ground(Vector3i(3, 0, 0)), Vector3i.RIGHT)
	assert_array(_build.path).contains_exactly([
		Vector3i.ZERO, Vector3i.RIGHT, Vector3i(2, 0, 0), Vector3i(3, 0, 0),
	])
	assert_str(_build.error).is_empty()
	_build.preview(null, Vector3i.RIGHT)
	assert_str(_build.error).is_equal("请瞄准有效位置")
	assert_bool(_build.lock_preview()).is_false()
	assert_bool(_build.active).is_true()


func test_locked_prefix_commits_with_its_suffix() -> void:
	assert_bool(_build.begin(_ground(Vector3i.ZERO), Vector3i.RIGHT)).is_true()
	_build.preview(_ground(Vector3i(2, 0, 0)), Vector3i.RIGHT)
	assert_str(_build.error).is_empty()
	assert_bool(_build.lock_preview()).is_true()
	_build.preview(_ground(Vector3i(3, 0, 0)), Vector3i.RIGHT)
	assert_bool(_build.commit()).is_true()
	for x: int in range(4):
		assert_int(_world.get_block(Vector3i(x, 0, 0))).is_equal(VoxelWorldData.Block.BELT)


func test_equal_length_routes_include_the_terminal_belts_fixed_turn() -> void:
	var end: Vector3i = Vector3i(2, 0, 1)
	_world.place_block(end, VoxelWorldData.Block.BELT)
	_logistics.set_direction(end, Vector3i.RIGHT)
	_build.begin(_ground(Vector3i.ZERO), Vector3i.RIGHT)
	_build.preview(_machine(end), Vector3i.RIGHT)
	assert_array(_build.path).contains_exactly([
		Vector3i.ZERO, Vector3i.BACK, Vector3i(1, 0, 1), end,
	])
	assert_vector(_build.directions[-1]).is_equal(Vector3i.RIGHT)
