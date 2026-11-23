extends GdUnitTestSuite
## Port rectangles share the side faces, including high and low slope ends.


func _face(cell: Vector3i, normal: Vector3i, block: int, direction: Vector3i) -> Array:
	var surface: SurfaceTool = SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
	VoxelWorldView._add_face(
		surface, cell, normal, block, VoxelWorldData.block_bounds(cell, block), direction
	)
	return surface.commit().surface_get_arrays(0)


func _assert_port(cell: Vector3i, normal: Vector3i, block: int, direction: Vector3i, kind: int) -> void:
	var arrays: Array = _face(cell, normal, block, direction)
	var marks: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	for index: int in range(6):
		assert_float(marks[index * 4 + 3]).is_equal(float(kind))
	if kind == 0:
		return
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var bounds: AABB = VoxelWorldData.block_bounds(cell, VoxelWorldData.Block.BELT if VoxelWorldData.is_slope(block) else block)
	var centre: Vector3 = bounds.get_center() + Vector3(normal) * 0.25
	if VoxelWorldData.is_slope(block):
		centre.y += VoxelWorldData.slope_elevation(cell, block, centre)
	var width_axis: Vector3 = Vector3(normal).cross(Vector3.UP)
	var height: float = minf(0.12, bounds.size.y * 0.6)
	# UV +/-0.5 defines the original 0.16 m wide, 0.048/0.12 m high port.
	for index: int in range(vertices.size()):
		assert_vector(vertices[index]).is_equal_approx(
			centre + width_axis * uv[index].x * 0.16 + Vector3.UP * uv[index].y * height,
			Vector3.ONE * 0.000001
		)


func test_flat_belts_keep_one_output_and_three_inputs_in_each_direction() -> void:
	for direction: Vector3i in [Vector3i.FORWARD, Vector3i.LEFT, Vector3i.BACK, Vector3i.RIGHT]:
		for normal: Vector3i in [Vector3i.FORWARD, Vector3i.LEFT, Vector3i.BACK, Vector3i.RIGHT]:
			_assert_port(Vector3i(-9, 0, 8), normal, VoxelWorldData.Block.BELT, direction, 2 if normal == direction else 3)


func test_all_slopes_keep_two_vertical_high_low_ports_without_side_ports() -> void:
	for block: int in range(9, 17):
		var direction: Vector3i = VoxelWorldData.slope_direction(block)
		for normal: Vector3i in [Vector3i.FORWARD, Vector3i.LEFT, Vector3i.BACK, Vector3i.RIGHT]:
			var kind: int = 2 if normal == direction else (3 if normal == -direction else 0)
			_assert_port(Vector3i(-8, 2, 8), normal, block, direction, kind)


func test_miner_only_has_output_and_chest_has_opposite_input() -> void:
	for block: int in [VoxelWorldData.Block.MINER, VoxelWorldData.Block.CHEST]:
		for direction: Vector3i in [Vector3i.FORWARD, Vector3i.LEFT, Vector3i.BACK, Vector3i.RIGHT]:
			for normal: Vector3i in [Vector3i.FORWARD, Vector3i.LEFT, Vector3i.BACK, Vector3i.RIGHT]:
				var kind: int = 2 if normal == direction else (
					3 if normal == -direction and block == VoxelWorldData.Block.CHEST else 0
				)
				_assert_port(Vector3i(8, 4, -8), normal, block, direction, kind)


func test_rotating_ports_changes_kind_without_changing_collision_vertices() -> void:
	var north: Array = _face(Vector3i.ZERO, Vector3i.FORWARD, VoxelWorldData.Block.BELT, Vector3i.FORWARD)
	var east: Array = _face(Vector3i.ZERO, Vector3i.FORWARD, VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	assert_bool(north[Mesh.ARRAY_VERTEX] == east[Mesh.ARRAY_VERTEX]).is_true()
	assert_bool(north[Mesh.ARRAY_NORMAL] == east[Mesh.ARRAY_NORMAL]).is_true()
	assert_bool(north[Mesh.ARRAY_CUSTOM0] != east[Mesh.ARRAY_CUSTOM0]).is_true()
