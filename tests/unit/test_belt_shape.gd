extends GdUnitTestSuite


func test_belt_uses_only_the_bottom_of_its_reserved_cell_for_player_overlap() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	var body_above: AABB = AABB(Vector3(0.1, 0.1, 0.1), Vector3(0.2, 1.75, 0.2))
	assert_bool(world.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT, body_above)).is_true()
	assert_bool(world.place_block(Vector3i.ZERO, VoxelWorldData.Block.STONE)).is_false()
	var intersecting: AABB = AABB(Vector3(0.6, 0.04, 0.1), Vector3(0.2, 1.75, 0.2))
	assert_bool(world.place_block(Vector3i.RIGHT, VoxelWorldData.Block.BELT, intersecting)).is_false()


func test_downward_and_inside_empty_upper_cell_rays_hit_the_thin_top() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	var hit: VoxelHit = VoxelRaycast.cast(world, Vector3(0.25, 1, 0.25), Vector3.DOWN, 2.0)
	assert_object(hit).is_not_null()
	assert_float(hit.distance).is_equal_approx(0.92, 0.00001)
	assert_vector(hit.normal).is_equal(Vector3i.UP)
	assert_object(VoxelRaycast.cast(world, Vector3(0.25, 1, 0.25), Vector3.DOWN, 0.91)).is_null()
	hit = VoxelRaycast.cast(world, Vector3(0.25, 0.4, 0.25), Vector3.DOWN, 1.0)
	assert_float(hit.distance).is_equal_approx(0.32, 0.00001)
	assert_vector(hit.normal).is_equal(Vector3i.UP)


func test_horizontal_ray_passes_over_belt_and_hits_a_block_behind_it() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	world.place_block(Vector3i.RIGHT, VoxelWorldData.Block.STONE)
	var hit: VoxelHit = VoxelRaycast.cast(world, Vector3(-0.25, 0.25, 0.25), Vector3.RIGHT, 2.0)
	assert_vector(hit.cell).is_equal(Vector3i.RIGHT)
	assert_float(hit.distance).is_equal_approx(0.75, 0.00001)
	assert_vector(hit.normal).is_equal(Vector3i.LEFT)


func test_ray_started_on_belt_surface_keeps_its_entry_normal() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	var side: VoxelHit = VoxelRaycast.cast(world, Vector3(0.5, 0.04, 0.25), Vector3.LEFT, 1.0)
	assert_object(side).is_not_null()
	assert_float(side.distance).is_equal(0.0)
	assert_vector(side.normal).is_equal(Vector3i.RIGHT)
	var top: VoxelHit = VoxelRaycast.cast(
		world, Vector3(0.25, VoxelWorldData.BELT_HEIGHT, 0.25), Vector3.DOWN, 1.0
	)
	assert_object(top).is_not_null()
	assert_float(top.distance).is_equal(0.0)
	assert_vector(top.normal).is_equal(Vector3i.UP)


func test_ray_started_strictly_inside_belt_has_no_entry_face() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	var hit: VoxelHit = VoxelRaycast.cast(world, Vector3(0.25, 0.04, 0.25), Vector3.RIGHT, 1.0)
	assert_object(hit).is_not_null()
	assert_float(hit.distance).is_equal(0.0)
	assert_vector(hit.normal).is_equal(Vector3i.ZERO)


func test_respawn_uses_the_belt_surface_instead_of_the_full_reserved_cell() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	world.place_block(Vector3i(0, 4, 0), VoxelWorldData.Block.BELT)
	var spawn: Vector3 = world.spawn_above_world(Vector3(0.25, 0, 0.25), Vector3(0.56, 1.75, 0.56))
	assert_float(spawn.y).is_equal_approx(2.09, 0.00001)
