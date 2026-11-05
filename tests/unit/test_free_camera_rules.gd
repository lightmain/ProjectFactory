extends GdUnitTestSuite


func test_camera_motion_stays_inside_player_distance_limit() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	var anchor: Vector3 = Vector3(0, 2, 0)
	var result: Vector3 = FreeCameraRules.move(
		world, anchor + Vector3.UP * 4, Vector3(100, 0, 0), anchor, 12
	)
	assert_float(result.distance_to(anchor)).is_less_equal(12.001)


func test_large_motion_cannot_cross_a_wall_without_a_physics_collider() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.place_block(Vector3i(2, 4, 0), VoxelWorldData.Block.STONE)
	var start: Vector3 = Vector3(0.25, 2.25, 0.25)
	var result: Vector3 = FreeCameraRules.move(world, start, Vector3(3, 0, 0), start, 12)
	assert_float(result.x).is_between(0.87, 0.881)
	assert_float(result.y).is_equal(start.y)


func test_camera_slides_along_a_wall_and_cannot_cross_a_thin_belt() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.place_block(Vector3i(2, 4, 0), VoxelWorldData.Block.STONE)
	var start: Vector3 = Vector3(0.25, 2.25, 0.25)
	var result: Vector3 = FreeCameraRules.move(world, start, Vector3(2, 0, 1), start, 12)
	assert_float(result.x).is_less_equal(0.881)
	assert_float(result.z).is_equal_approx(1.25, 0.001)
	world.place_block(Vector3i(0, 0, 0), VoxelWorldData.Block.BELT)
	result = FreeCameraRules.move(
		world, Vector3(0.25, 1, 0.25), Vector3.DOWN * 3, Vector3(0.25, 1, 0.25), 12
	)
	assert_float(result.y).is_between(0.2, 0.202)


func test_initial_lift_stops_below_a_ceiling() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.place_block(Vector3i(0, 5, 0), VoxelWorldData.Block.STONE)
	var start: Vector3 = Vector3(0.25, 1.58, 0.25)
	var result: Vector3 = FreeCameraRules.move(world, start, Vector3.UP * 4.17, start, 12)
	assert_float(result.y).is_between(2.378, 2.381)


func test_zero_or_nonfinite_motion_does_not_change_camera_position() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	var start: Vector3 = Vector3(0, 2, 0)
	assert_vector(FreeCameraRules.move(world, start, Vector3.ZERO, start, 12)).is_equal(start)
	assert_vector(FreeCameraRules.move(world, start, Vector3(INF, 0, 0), start, 12)).is_equal(start)


func test_soft_boundary_progressively_damps_only_outward_motion() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	var anchor: Vector3 = Vector3(0, 2, 0)
	var previous_step: float = 0.11
	for distance: float in [9.0, 10.5, 11.0, 11.5, 11.9]:
		var start: Vector3 = anchor + Vector3.RIGHT * distance
		var result: Vector3 = FreeCameraRules.move(world, start, Vector3.RIGHT * 0.1, anchor, 12)
		var step: float = result.x - start.x
		assert_float(step).is_greater(0)
		assert_float(step).is_less(previous_step)
		previous_step = step
	var edge: Vector3 = anchor + Vector3.RIGHT * 12
	var tangent: Vector3 = FreeCameraRules.move(world, edge, Vector3.BACK * 0.5, anchor, 12)
	assert_float(tangent.z).is_greater(0.49)
	assert_float(tangent.distance_to(anchor)).is_less_equal(12.001)
	var inward: Vector3 = FreeCameraRules.move(world, edge, Vector3.LEFT * 0.5, anchor, 12)
	assert_float(inward.x).is_equal_approx(edge.x - 0.5, 0.001)


func test_boundary_slide_remains_safe_when_inward_correction_hits_a_voxel() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	var anchor: Vector3 = Vector3(-4.5, 2.25, 0.25)
	var edge: Vector3 = anchor + Vector3.RIGHT * 12
	var cell: Vector3i = Vector3i(13, 4, 0)
	assert_bool(world.place_block(cell, VoxelWorldData.Block.STONE)).is_true()
	var result: Vector3 = FreeCameraRules.move(world, edge, Vector3.BACK * 6, anchor, 12)
	assert_float(result.distance_to(anchor)).is_less_equal(12.001)
	assert_bool(AABB(result - Vector3.ONE * 0.12, Vector3.ONE * 0.24).intersects(
		VoxelWorldData.block_bounds(cell, VoxelWorldData.Block.STONE)
	)).is_false()
