extends GdUnitTestSuite


func test_downward_ray_hits_ground_with_upward_placement_face() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var hit: VoxelHit = VoxelRaycast.cast(world, Vector3(0.25, 2, 0.25), Vector3.DOWN, 5.0)
	assert_object(hit).is_not_null()
	assert_vector(hit.cell).is_equal(Vector3i(0, -1, 0))
	assert_vector(hit.normal).is_equal(Vector3i.UP)
	assert_float(hit.distance).is_equal(2.0)
	assert_vector(hit.adjacent_cell()).is_equal(Vector3i.ZERO)


func test_ray_respects_distance_and_zero_direction() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	assert_object(VoxelRaycast.cast(world, Vector3(0.25, 2, 0.25), Vector3.DOWN, 1.9)).is_null()
	assert_object(VoxelRaycast.cast(world, Vector3.ZERO, Vector3.ZERO, 5.0)).is_null()
	assert_object(VoxelRaycast.cast(world, Vector3.ZERO, Vector3.DOWN, -1.0)).is_null()
	assert_object(VoxelRaycast.cast(world, Vector3(0, 1, 0), Vector3.UP, 5.0)).is_null()


func test_negative_axis_boundary_and_non_unit_direction() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.place_block(Vector3i(-2, 0, 0), VoxelWorldData.Block.STONE)
	var hit: VoxelHit = VoxelRaycast.cast(world, Vector3(0, 0.25, 0.25), Vector3(-4, 0, 0), 5.0)
	assert_object(hit).is_not_null()
	assert_vector(hit.cell).is_equal(Vector3i(-2, 0, 0))
	assert_vector(hit.normal).is_equal(Vector3i.RIGHT)
	assert_float(hit.distance).is_equal(0.5)


func test_ray_sees_edits_without_waiting_for_physics_mesh() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	world.break_block(Vector3i(0, -1, 0))
	var hit: VoxelHit = VoxelRaycast.cast(world, Vector3(0.25, 1, 0.25), Vector3.DOWN, 5.0)
	assert_vector(hit.cell).is_equal(Vector3i(0, -2, 0))
	world.place_block(Vector3i(0, 0, 0), VoxelWorldData.Block.STONE)
	hit = VoxelRaycast.cast(world, Vector3(0.25, 1, 0.25), Vector3.DOWN, 5.0)
	assert_vector(hit.cell).is_equal(Vector3i.ZERO)
