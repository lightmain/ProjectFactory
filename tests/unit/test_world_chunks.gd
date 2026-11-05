extends GdUnitTestSuite


func test_world_extent_is_eight_data_chunks_and_four_ground_layers() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	assert_vector(VoxelWorldData.MAX_CELL - VoxelWorldData.MIN_CELL).is_equal(Vector3i(64, 64, 64))
	assert_int(world.block_count()).is_equal(64 * 64 * 4)
	assert_bool(world.is_in_bounds(Vector3i(-32, -4, -32))).is_true()
	assert_bool(world.is_in_bounds(Vector3i(31, 59, 31))).is_true()
	assert_bool(world.is_in_bounds(Vector3i(32, 0, 0))).is_false()


func test_untouched_flat_world_needs_no_chunk_records() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	assert_int(world.chunk_deltas().size()).is_equal(0)


func test_edits_in_all_eight_chunks_round_trip_including_air() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	for x: int in [-32, 0]:
		for y: int in [0, 32]:
			for z: int in [-32, 0]:
				assert_bool(world.place_block(Vector3i(x, y, z), VoxelWorldData.Block.STONE)).is_true()
	world.break_block(Vector3i(-32, -1, -32))
	var chunks: Dictionary[Vector3i, PackedByteArray] = world.chunk_deltas()
	assert_int(chunks.size()).is_equal(8)
	var restored: VoxelWorldData = VoxelWorldData.new()
	assert_bool(restored.restore_chunks(true, chunks)).is_true()
	assert_int(restored.get_block(Vector3i(-32, -1, -32))).is_equal(VoxelWorldData.Block.AIR)
	assert_int(restored.block_count()).is_equal(world.block_count())
	for cell: Vector3i in world.solid_cells():
		if restored.get_block(cell) != world.get_block(cell):
			assert_int(restored.get_block(cell)).is_equal(world.get_block(cell))
			return


func test_reverted_edits_remove_chunk_from_save() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.STONE)
	world.break_block(Vector3i.ZERO)
	world.break_block(Vector3i(0, -1, 0))
	world.place_block(Vector3i(0, -1, 0), VoxelWorldData.Block.GRASS)
	assert_int(world.chunk_deltas().size()).is_equal(0)
