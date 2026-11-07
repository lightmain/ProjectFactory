extends GdUnitTestSuite

const TEST_BLOCK: int = 8


func test_structure_reserves_27_cells_and_any_part_breaks_the_whole() -> void:
	for part: Vector3i in VoxelWorldData.structure_footprint(Vector3i.ZERO):
		var world: VoxelWorldData = VoxelWorldData.new()
		world.generate_flat()
		assert_bool(world.place_block(Vector3i.ZERO, TEST_BLOCK)).is_true()
		for x: int in range(-1, 2):
			for y: int in range(3):
				for z: int in range(-1, 2):
					assert_int(world.get_block(Vector3i(x, y, z))).is_equal(TEST_BLOCK)
		assert_int(world.block_count()).is_equal(64 * 64 * 4 + 27)
		assert_bool(world.break_block(part)).is_true()
		assert_int(world.block_count()).is_equal(64 * 64 * 4)
		assert_int(world.get_block(Vector3i(0, -1, 0))).is_equal(VoxelWorldData.Block.GRASS)
		assert_int(world.chunk_deltas().size()).is_equal(0)


func test_center_snap_negative_coordinates_and_whole_body_rejection() -> void:
	assert_vector(VoxelWorldData.structure_anchor(Vector3(-0.24, 0.0, -0.76))).is_equal(Vector3i(-1, 0, -2))
	assert_vector(VoxelWorldData.structure_anchor(Vector3(0.25, 0.25, 0.25))).is_equal(Vector3i(0, 1, 0))
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	assert_bool(world.place_structure(Vector3i.ZERO, 0, AABB(
		Vector3(0.8, 1.2, 0.8), Vector3.ONE * 0.1
	))).is_false()
	assert_int(world.block_count()).is_equal(64 * 64 * 4)


func test_notifications_observe_complete_structure_and_complete_removal() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var counts: Array[int] = []
	var observer: Callable = func(_cell: Vector3i) -> void:
		counts.append(world.block_count() - 64 * 64 * 4)
	world.cell_changed.connect(observer)
	world.place_structure(Vector3i.ZERO, 3)
	assert_int(counts.size()).is_equal(27)
	for count: int in counts:
		assert_int(count).is_equal(27)
	var identity: Dictionary = world.structure_at(Vector3i(1, 2, 1))
	assert_int(identity["rotation"]).is_equal(3)
	identity["anchor"] = Vector3i(20, 20, 20)
	counts.clear()
	world.break_block(Vector3i(1, 2, 1))
	for count: int in counts:
		assert_int(count).is_equal(0)
	assert_bool(world.structure_rows().is_empty()).is_true()
	world.cell_changed.disconnect(observer)


func test_invalid_restore_is_atomic_and_duplicate_instance_id_is_rejected() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	world.place_structure(Vector3i.ZERO, 2)
	var rows: Array[Dictionary] = world.structure_rows()
	rows.append(rows[0].duplicate())
	assert_bool(world.restore_chunks(true, world.chunk_deltas(), rows)).is_false()
	assert_int(world.structure_at(Vector3i.ZERO)["rotation"]).is_equal(2)
	assert_int(world.get_block(Vector3i(1, 2, 1))).is_equal(TEST_BLOCK)
	assert_bool(world.break_block(Vector3i(1, 2, 1))).is_true()


func test_maximum_restored_identity_can_place_and_save_another_structure() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	world.place_structure(Vector3i.ZERO)
	var rows: Array[Dictionary] = world.structure_rows()
	rows[0]["id"] = 2147483646
	assert_bool(world.restore_chunks(true, world.chunk_deltas(), rows)).is_true()
	assert_bool(world.place_structure(Vector3i(3, 0, 0))).is_true()
	var restored: VoxelWorldData = VoxelWorldData.new()
	assert_bool(restored.restore_chunks(true, world.chunk_deltas(), world.structure_rows())).is_true()
	assert_int(world.structure_at(Vector3i.ZERO)["id"]).is_equal(2147483646)
	assert_bool(world.structure_at(Vector3i(3, 0, 0))["id"] != 2147483646).is_true()


func test_obstructed_or_out_of_bounds_structure_leaves_no_partial_cells() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	world.place_block(Vector3i(1, 2, 1), VoxelWorldData.Block.STONE)
	assert_bool(world.place_block(Vector3i.ZERO, TEST_BLOCK)).is_false()
	assert_int(world.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)
	assert_int(world.block_count()).is_equal(64 * 64 * 4 + 1)
	assert_bool(world.place_block(Vector3i(31, 0, 0), TEST_BLOCK)).is_false()
	assert_bool(world.place_block(Vector3i(0, 58, 0), TEST_BLOCK)).is_false()


func test_structures_cross_chunks_and_adjacent_structures_are_independent() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	assert_bool(world.place_block(Vector3i(0, 27, 0), TEST_BLOCK)).is_true()
	assert_int(world.chunk_deltas().size()).is_equal(8)
	assert_bool(world.place_block(Vector3i(3, 27, 0), TEST_BLOCK)).is_true()
	assert_bool(world.break_block(Vector3i(-1, 27, -1))).is_true()
	assert_int(world.get_block(Vector3i(3, 27, 0))).is_equal(TEST_BLOCK)
	assert_int(world.get_block(Vector3i(0, 29, 0))).is_equal(VoxelWorldData.Block.AIR)
