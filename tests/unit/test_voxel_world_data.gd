extends GdUnitTestSuite


func test_cell_size_and_negative_coordinates() -> void:
	assert_float(VoxelWorldData.CELL_SIZE).is_equal(0.5)
	assert_vector(VoxelWorldData.world_to_cell(Vector3(-0.01, 0.49, -0.5))).is_equal(
		Vector3i(-1, 0, -1)
	)
	assert_vector(VoxelWorldData.cell_center(Vector3i(-1, 0, 1))).is_equal(
		Vector3(-0.25, 0.25, 0.75)
	)


func test_flat_world_has_four_layers_and_air_above() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	assert_int(world.block_count()).is_equal(64 * 64 * 4)
	assert_int(world.get_block(Vector3i(-16, -1, 15))).is_equal(VoxelWorldData.Block.GRASS)
	assert_int(world.get_block(Vector3i(0, -2, 0))).is_equal(VoxelWorldData.Block.DIRT)
	assert_int(world.get_block(Vector3i(0, -3, 0))).is_equal(VoxelWorldData.Block.STONE)
	assert_int(world.get_block(Vector3i(0, -4, 0))).is_equal(VoxelWorldData.Block.BEDROCK)
	assert_int(world.get_block(Vector3i(0, 0, 0))).is_equal(VoxelWorldData.Block.AIR)


func test_world_bounds_are_half_open() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	assert_bool(world.is_in_bounds(Vector3i(-32, -4, -32))).is_true()
	assert_bool(world.is_in_bounds(Vector3i(31, 59, 31))).is_true()
	assert_bool(world.is_in_bounds(Vector3i(32, 0, 0))).is_false()
	assert_bool(world.is_in_bounds(Vector3i(0, 60, 0))).is_false()
	assert_bool(world.is_in_bounds(Vector3i(0, -5, 0))).is_false()


func test_break_is_idempotent_and_preserves_bedrock() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	assert_bool(world.break_block(Vector3i(0, -1, 0))).is_true()
	assert_int(world.get_block(Vector3i(0, -1, 0))).is_equal(VoxelWorldData.Block.AIR)
	assert_bool(world.break_block(Vector3i(0, -1, 0))).is_false()
	assert_bool(world.break_block(Vector3i(0, -4, 0))).is_false()
	assert_bool(world.break_block(Vector3i(32, -1, 0))).is_false()


func test_place_rejects_occupied_outside_and_invalid_blocks() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	assert_bool(world.place_block(Vector3i(0, 0, 0), VoxelWorldData.Block.STONE)).is_true()
	assert_bool(world.place_block(Vector3i(0, 0, 0), VoxelWorldData.Block.DIRT)).is_false()
	assert_bool(world.place_block(Vector3i(32, 0, 0), VoxelWorldData.Block.STONE)).is_false()
	assert_bool(world.place_block(Vector3i(1, 0, 0), VoxelWorldData.Block.AIR)).is_false()
	assert_bool(world.place_block(Vector3i(1, 0, 0), 99)).is_false()
	assert_bool(world.place_block(Vector3i(1, 0, 0), VoxelWorldData.Block.BEDROCK)).is_false()


func test_placement_does_not_intersect_player_but_allows_touching_face() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	var player_bounds: AABB = AABB(Vector3(0, 0, 0), Vector3(0.5, 1.75, 0.5))
	assert_bool(world.place_block(Vector3i.ZERO, VoxelWorldData.Block.STONE, player_bounds)).is_false()
	assert_bool(world.place_block(Vector3i(1, 0, 0), VoxelWorldData.Block.STONE, player_bounds)).is_true()
	assert_int(world.block_count()).is_equal(1)


func test_regeneration_resets_player_edits() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	world.break_block(Vector3i.ZERO + Vector3i.DOWN)
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.STONE)
	world.generate_flat()
	assert_int(world.block_count()).is_equal(64 * 64 * 4)
	assert_int(world.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)


func test_spawn_clears_highest_voxel_under_the_whole_body() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	world.place_block(Vector3i(1, 5, 6), VoxelWorldData.Block.STONE)
	var spawn: Vector3 = world.spawn_above_world(Vector3(0.25, 0.1, 3.25), Vector3(0.56, 1.75, 0.56))
	assert_vector(spawn).is_equal_approx(Vector3(0.25, 3.01, 3.25), Vector3.ONE * 0.001)
