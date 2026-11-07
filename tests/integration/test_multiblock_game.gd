extends GdUnitTestSuite

var _game: FactoryGame


func before_test() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_game = auto_free(scene.instantiate()) as FactoryGame
	add_child(_game)
	_game.player.set_physics_process(false)
	_game.player.set_controls_captured(true)
	_game.player.camera.look_at(Vector3(0.25, 0.0, 0.25), Vector3.UP)
	await get_tree().physics_frame


func after_test() -> void:
	_game.player.set_controls_captured(false)


func _key(code: Key) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = true
	_game.player.handle_input(event)


func _click(button: MouseButton) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button
	event.position = _game.free_camera.cursor_position if _game.free_camera.active else Vector2.ZERO
	event.pressed = true
	_game.player.handle_input(event)


func test_key_seven_previews_places_and_breaks_whole_structure_with_real_collision() -> void:
	_key(KEY_7)
	assert_int(_game.selected_block).is_equal(8)
	_game._process(0.0)
	assert_bool(_game.build_preview.visible).is_true()
	assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)
	_key(KEY_R)
	_game._process(0.0)
	assert_vector(_game.build_direction()).is_equal(Vector3i.LEFT)
	_click(MOUSE_BUTTON_RIGHT)
	assert_int(_game.world_data.get_block(Vector3i(1, 2, 1))).is_equal(8)
	assert_int(_game.world_data.structure_at(Vector3i(1, 2, 1))["rotation"]).is_equal(1)
	_game.world_view.rebuild_pending()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		Vector3(0.75, 3, 0.75), Vector3(0.75, -2, 0.75), 1
	)
	var hit: Dictionary = _game.get_world_3d().direct_space_state.intersect_ray(query)
	assert_bool(hit.is_empty()).is_false()
	if not hit.is_empty():
		assert_float(Vector3(hit["position"]).y).is_equal_approx(1.5, 0.001)
	_game.player.camera.look_at(Vector3(0.75, 1.25, 0.75), Vector3.UP)
	_click(MOUSE_BUTTON_LEFT)
	assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)
	assert_int(_game.world_data.get_block(Vector3i(1, 2, 1))).is_equal(VoxelWorldData.Block.AIR)
	_game.world_view.rebuild_pending()
	await get_tree().physics_frame
	await get_tree().physics_frame
	hit = _game.get_world_3d().direct_space_state.intersect_ray(query)
	assert_float(Vector3(hit["position"]).y).is_equal_approx(0.0, 0.001)


func test_actual_hit_snap_updates_within_same_hit_cell_and_modal_hides_ghost() -> void:
	_key(KEY_7)
	var hit: VoxelHit = VoxelHit.new(Vector3i(0, -1, 0), Vector3i.UP, 1.0, Vector3(0.01, 0, 0.25))
	_game._update_preview(hit, true)
	assert_vector(_game._preview_anchor).is_equal(Vector3i.ZERO)
	# An exact grid-line hit has the same DDA cell but rounds across the half tie.
	hit.position.x = 0.0
	_game._update_preview(hit)
	assert_vector(_game._preview_anchor).is_equal(Vector3i(-1, 0, 0))
	_key(KEY_I)
	assert_bool(_game.build_preview.visible).is_false()
	_key(KEY_I)
	_key(KEY_3)
	_game._process(0.0)
	assert_bool(_game.build_preview.visible).is_false()
	_key(KEY_7)
	assert_vector(_game.build_direction()).is_equal(Vector3i.BACK)


func test_invalid_full_footprint_rejected_by_preview_and_click() -> void:
	_key(KEY_7)
	_game.world_data.place_block(Vector3i(1, 2, 1), VoxelWorldData.Block.STONE)
	_game._process(0.0)
	assert_bool(_game._preview_error.is_empty()).is_false()
	_click(MOUSE_BUTTON_RIGHT)
	assert_bool(_game.world_data.structure_rows().is_empty()).is_true()
	assert_int(_game.world_data.block_count()).is_equal(64 * 64 * 4 + 1)


func test_free_camera_overlap_rejects_entire_structure() -> void:
	_key(KEY_TAB)
	assert_bool(_game.free_camera.active).is_true()
	_key(KEY_7)
	_game.free_camera.global_position = Vector3(0.75, 0.8, 0.75)
	var target: Vector3 = Vector3(0.25, 0, 0.25)
	_game.free_camera.cursor_position = _game.free_camera.camera.unproject_position(target)
	_game._process(0.0)
	assert_vector(_game._preview_anchor).is_equal(Vector3i.ZERO)
	assert_bool(VoxelWorldData.structure_bounds(_game._preview_anchor).intersects(
		_game.free_camera.occupied_bounds()
	)).is_true()
	assert_bool(_game.build_preview.visible).is_true()
	assert_bool(_game._preview_error.is_empty()).is_false()
	_click(MOUSE_BUTTON_RIGHT)
	assert_bool(_game.world_data.structure_rows().is_empty()).is_true()
	assert_int(_game.world_data.block_count()).is_equal(64 * 64 * 4)
