extends GdUnitTestSuite
## Facility marks belong to the real chunk surface, without extra draw batches.

var _game: FactoryGame


func before_test() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_game = auto_free(scene.instantiate()) as FactoryGame
	add_child(_game)
	_game.set_physics_process(false)
	_game.logistics_view.set_process(false)
	_game.logistics_view.render_distance = 100.0


func _place(cell: Vector3i, block: int, direction: Vector3i) -> void:
	assert_bool(_game.world_data.place_block(cell, block)).is_true()
	if not VoxelWorldData.is_slope(block):
		assert_bool(_game.logistics_data.set_direction(cell, direction)).is_true()
	_game.world_view.rebuild_pending()
	_game.logistics_view.refresh_from_data()


func _mesh(cell: Vector3i = Vector3i.ZERO) -> MeshInstance3D:
	var chunk: Vector3i = Vector3i((Vector3(cell) / 8.0).floor())
	return _game.world_view.get_node_or_null("Chunk_%d_%d_%d/Mesh" % [chunk.x, chunk.y, chunk.z]) as MeshInstance3D


func _mark_count(cell: Vector3i, kind: int) -> int:
	var mesh_node: MeshInstance3D = _mesh(cell)
	if mesh_node == null:
		return 0
	var arrays: Array = mesh_node.mesh.surface_get_arrays(0)
	var marks: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	var count: int = 0
	for index: int in range(0, marks.size(), 4):
		if Vector3(marks[index], marks[index + 1], marks[index + 2]) == VoxelWorldData.cell_center(cell):
			if is_equal_approx(marks[index + 3], float(kind)):
				count += 1
	return count


func test_marks_share_chunk_material_without_separate_arrow_or_port_batches() -> void:
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	assert_int(_game.logistics_view.find_children("ArrowRenderPool", "", true, false).size()).is_equal(0)
	assert_int(_game.logistics_view.find_children("PortRenderPool", "", true, false).size()).is_equal(0)
	var mesh_node: MeshInstance3D = _game.world_view.get_node("Chunk_0_0_0/Mesh") as MeshInstance3D
	var arrays: Array = mesh_node.mesh.surface_get_arrays(0)
	assert_bool(arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array).is_true()
	assert_bool(arrays[Mesh.ARRAY_CUSTOM0] is PackedFloat32Array).is_true()
	var material: ShaderMaterial = mesh_node.material_override as ShaderMaterial
	assert_bool(material.get_shader_parameter("decorations_enabled") == true).is_true()


func test_rotation_updates_chunk_surface_without_advancing_logistics() -> void:
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT, Vector3i.FORWARD)
	var mesh_node: MeshInstance3D = _game.world_view.get_node("Chunk_0_0_0/Mesh") as MeshInstance3D
	var before_arrays: Array = mesh_node.mesh.surface_get_arrays(0)
	var before_uv: Variant = before_arrays[Mesh.ARRAY_TEX_UV]
	var tick: int = _game.logistics_data.logic_tick()
	assert_bool(_game.logistics_data.set_direction(Vector3i.ZERO, Vector3i.RIGHT)).is_true()
	var snapshot: Dictionary = _game.logistics_data.save_state()
	_game.world_view.rebuild_pending()
	_game.logistics_view.refresh_from_data()
	mesh_node = _game.world_view.get_node("Chunk_0_0_0/Mesh") as MeshInstance3D
	var after_arrays: Array = mesh_node.mesh.surface_get_arrays(0)
	assert_bool(after_arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array).is_true()
	assert_bool(after_arrays[Mesh.ARRAY_TEX_UV] != before_uv).is_true()
	assert_int(_game.logistics_data.logic_tick()).is_equal(tick)
	assert_bool(_game.logistics_data.save_state() == snapshot).is_true()


func test_surface_ports_keep_counts_colours_and_ignore_ore_height_limit() -> void:
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	_place(Vector3i(2, 0, 0), VoxelWorldData.Block.MINER, Vector3i.LEFT)
	_place(Vector3i(4, 0, 0), VoxelWorldData.Block.CHEST, Vector3i.BACK)
	_place(Vector3i(6, 0, 0), VoxelWorldData.Block.BELT_UP_EAST, Vector3i.RIGHT)
	for cell: Vector3i in [Vector3i.ZERO, Vector3i(2, 0, 0), Vector3i(4, 0, 0), Vector3i(6, 0, 0)]:
		assert_int(_mark_count(cell, 1)).is_equal(6)
		assert_int(_mark_count(cell, 2)).is_equal(6)
	assert_int(_mark_count(Vector3i.ZERO, 3)).is_equal(18)
	assert_int(_mark_count(Vector3i(2, 0, 0), 3)).is_equal(0)
	assert_int(_mark_count(Vector3i(4, 0, 0), 3)).is_equal(6)
	assert_int(_mark_count(Vector3i(6, 0, 0), 3)).is_equal(6)
	_game.logistics_view.ore_render_max_height_above_camera = 0.0
	_game.logistics_view.refresh_from_data()
	var material: ShaderMaterial = _mesh().material_override as ShaderMaterial
	assert_bool(material.get_shader_parameter("decorations_enabled") == true).is_true()
	var output: Color = material.get_shader_parameter("output_color")
	var input: Color = material.get_shader_parameter("input_color")
	assert_bool(output.is_equal_approx(Color("#c9f0a1"))).is_true()
	assert_bool(input.is_equal_approx(Color("#81cbdc"))).is_true()
	assert_object(_mesh(Vector3i(6, 0, 0)).material_override).is_same(material)


func test_current_camera_distance_disabled_values_and_hidden_view_update_shared_material() -> void:
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT, Vector3i.FORWARD)
	var material: ShaderMaterial = _mesh().material_override as ShaderMaterial
	var camera: Camera3D = _game.player.camera
	camera.global_position = VoxelWorldData.cell_center(Vector3i.ZERO) + Vector3.RIGHT * 2.0
	_game.logistics_view.render_distance = 2.0
	_game.logistics_view.refresh_from_data()
	assert_vector(material.get_shader_parameter("decoration_camera")).is_equal(camera.global_position)
	assert_float(material.get_shader_parameter("decoration_distance")).is_equal(2.0)
	assert_bool(material.get_shader_parameter("decorations_enabled") == true).is_true()
	# Exactly on the radius remains a candidate; the surface shader uses the same centre.
	assert_bool(_game.logistics_view._nearby_cells().has(Vector3i.ZERO)).is_true()
	camera.global_position.x += 0.0001
	_game.logistics_view.refresh_from_data()
	assert_bool(_game.logistics_view._nearby_cells().has(Vector3i.ZERO)).is_false()
	assert_vector(material.get_shader_parameter("decoration_camera")).is_equal(camera.global_position)
	for distance: float in [0.0, -1.0, INF, NAN]:
		_game.logistics_view.render_distance = distance
		_game.logistics_view.refresh_from_data()
		assert_bool(material.get_shader_parameter("decorations_enabled") == false).is_true()
	_game.logistics_view.render_distance = 100.0
	_game.logistics_view.refresh_from_data()
	_game.logistics_view.hide()
	assert_bool(material.get_shader_parameter("decorations_enabled") == false).is_true()
	_game.logistics_view.show()
	assert_bool(material.get_shader_parameter("decorations_enabled") == true).is_true()
	_game.logistics_view.set_camera(null)
	assert_bool(material.get_shader_parameter("decorations_enabled") == false).is_true()


func test_removal_reset_and_rebind_release_old_surface_directions() -> void:
	var cell: Vector3i = Vector3i(-9, 0, -9)
	_place(cell, VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	assert_int(_mark_count(cell, 1)).is_equal(6)
	assert_bool(_game.world_data.break_block(cell)).is_true()
	_game.world_view.rebuild_pending()
	assert_int(_mark_count(cell, 1)).is_equal(0)
	_place(cell, VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	_game.world_data.generate_flat()
	assert_int(_mark_count(cell, 1)).is_equal(0)
	var fresh_world: VoxelWorldData = VoxelWorldData.new()
	fresh_world.generate_flat()
	var fresh_data: LogisticsData = LogisticsData.new()
	fresh_data.bind_world(fresh_world)
	assert_bool(fresh_world.place_block(cell, VoxelWorldData.Block.CHEST)).is_true()
	assert_bool(fresh_data.set_direction(cell, Vector3i.LEFT)).is_true()
	_game.world_view.bind_logistics(fresh_data)
	_game.world_view.bind_world(fresh_world)
	_game.logistics_view.bind_logistics(fresh_data, fresh_world, _game.player.camera)
	_game.logistics_view.refresh_from_data()
	assert_int(_mark_count(cell, 1)).is_equal(6)
	assert_int(_mark_count(cell, 3)).is_equal(6)
	# Signals from the detached data must no longer alter the current chunk.
	var mesh: Mesh = _mesh(cell).mesh
	assert_bool(_game.world_data.place_block(cell, VoxelWorldData.Block.MINER)).is_true()
	_game.world_view.rebuild_pending()
	assert_object(_mesh(cell).mesh).is_same(mesh)


func test_covered_adjacent_faces_do_not_add_port_geometry() -> void:
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	assert_int(_mark_count(Vector3i.ZERO, 2)).is_equal(0)
	assert_int(_mark_count(Vector3i.RIGHT, 3)).is_equal(12)
	assert_int(_game.logistics_view.find_children("PortRenderPool", "", true, false).size()).is_equal(0)


func test_same_world_logistics_restore_refreshes_surface_direction() -> void:
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	var saved: Dictionary = _game.logistics_data.save_state()
	var east_arrays: Array = _mesh().mesh.surface_get_arrays(0)
	assert_bool(_game.logistics_data.set_direction(Vector3i.ZERO, Vector3i.FORWARD)).is_true()
	_game.world_view.rebuild_pending()
	assert_bool(_game.logistics_data.restore_state(saved)).is_true()
	assert_vector(_game.logistics_data.direction_at(Vector3i.ZERO)).is_equal(Vector3i.RIGHT)
	_game.world_view.rebuild_pending()
	var restored: Array = _mesh().mesh.surface_get_arrays(0)
	assert_bool(restored[Mesh.ARRAY_TEX_UV] == east_arrays[Mesh.ARRAY_TEX_UV]).is_true()
	assert_bool(restored[Mesh.ARRAY_CUSTOM0] == east_arrays[Mesh.ARRAY_CUSTOM0]).is_true()


func test_surface_detach_replacement_and_tree_exit_disable_previous_material() -> void:
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	var old_material: ShaderMaterial = _mesh().material_override as ShaderMaterial
	_game.logistics_view.bind_surface_view(null)
	assert_bool(old_material.get_shader_parameter("decorations_enabled") == false).is_true()
	_game.logistics_view.bind_surface_view(_game.world_view)
	assert_bool(old_material.get_shader_parameter("decorations_enabled") == true).is_true()
	var replacement: VoxelWorldView = auto_free(VoxelWorldView.new()) as VoxelWorldView
	add_child(replacement)
	replacement.set_physics_process(false)
	replacement.bind_logistics(_game.logistics_data)
	replacement.bind_world(_game.world_data)
	var replacement_mesh: MeshInstance3D = replacement.get_node("Chunk_0_0_0/Mesh") as MeshInstance3D
	var new_material: ShaderMaterial = replacement_mesh.material_override as ShaderMaterial
	_game.logistics_view.bind_surface_view(replacement)
	assert_bool(old_material.get_shader_parameter("decorations_enabled") == false).is_true()
	assert_bool(new_material.get_shader_parameter("decorations_enabled") == true).is_true()
	_game.logistics_view.hide()
	assert_bool(new_material.get_shader_parameter("decorations_enabled") == false).is_true()
	_game.logistics_view.show()
	assert_bool(new_material.get_shader_parameter("decorations_enabled") == true).is_true()
	_game.remove_child(_game.logistics_view)
	assert_bool(new_material.get_shader_parameter("decorations_enabled") == false).is_true()
	_game.add_child(_game.logistics_view)
