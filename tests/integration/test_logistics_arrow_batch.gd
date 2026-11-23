extends GdUnitTestSuite
## Arrow coordinates are carried by the existing facility top face.


func _face(cell: Vector3i, block: int, direction: Vector3i) -> Array:
	var surface: SurfaceTool = SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
	VoxelWorldView._add_face(
		surface, cell, Vector3i.UP, block, VoxelWorldData.block_bounds(cell, block), direction
	)
	return surface.commit().surface_get_arrays(0)


func _assert_top(cell: Vector3i, block: int, direction: Vector3i) -> void:
	var arrays: Array = _face(cell, block, direction)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var marks: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	assert_int(vertices.size()).is_equal(6)
	var front: Vector3 = Vector3(direction)
	var left: Vector3 = Vector3.UP.cross(front)
	var centre: Vector3 = VoxelWorldData.block_bounds(cell, block).get_center()
	# Recover the world surface from pattern coordinates in metres.
	for index: int in range(vertices.size()):
		var expected: Vector3 = centre + left * uv[index].x - front * uv[index].y
		expected.y = float(cell.y) * 0.5 + (
			0.08 + VoxelWorldData.slope_elevation(cell, block, expected)
			if VoxelWorldData.is_slope(block) else VoxelWorldData.block_bounds(cell, block).size.y
		)
		assert_vector(vertices[index]).is_equal_approx(expected, Vector3.ONE * 0.000001)
		assert_float(marks[index * 4 + 3]).is_equal(1.0)
		assert_vector(Vector3(marks[index * 4], marks[index * 4 + 1], marks[index * 4 + 2])).is_equal(
			VoxelWorldData.cell_center(cell)
		)


func test_cardinal_arrows_use_metres_in_original_top_face() -> void:
	for direction: Vector3i in [Vector3i.FORWARD, Vector3i.LEFT, Vector3i.BACK, Vector3i.RIGHT]:
		_assert_top(Vector3i(-9, 0, 8), VoxelWorldData.Block.BELT, direction)


func test_all_slopes_follow_high_and_low_top_surface() -> void:
	for block: int in range(9, 17):
		_assert_top(Vector3i(-8, 2, 8), block, VoxelWorldData.slope_direction(block))


func test_miner_and_chest_arrows_use_their_own_top_height() -> void:
	for block: int in [VoxelWorldData.Block.MINER, VoxelWorldData.Block.CHEST]:
		_assert_top(Vector3i(8, 4, -8), block, Vector3i.RIGHT)


func test_direction_changes_uv_without_changing_geometry() -> void:
	var north: Array = _face(Vector3i.ZERO, VoxelWorldData.Block.BELT, Vector3i.FORWARD)
	var east: Array = _face(Vector3i.ZERO, VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	assert_bool(north[Mesh.ARRAY_VERTEX] == east[Mesh.ARRAY_VERTEX]).is_true()
	assert_bool(north[Mesh.ARRAY_NORMAL] == east[Mesh.ARRAY_NORMAL]).is_true()
	assert_bool(north[Mesh.ARRAY_TEX_UV] != east[Mesh.ARRAY_TEX_UV]).is_true()


func test_ordinary_voxels_have_no_arrow_pattern() -> void:
	var arrays: Array = _face(Vector3i.ZERO, VoxelWorldData.Block.STONE, Vector3i.ZERO)
	var marks: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	for index: int in range(6):
		assert_float(marks[index * 4 + 3]).is_equal(0.0)
