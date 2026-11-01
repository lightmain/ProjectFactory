extends GdUnitTestSuite

var _game: FactoryGame


func before_test() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_game = auto_free(scene.instantiate()) as FactoryGame
	add_child(_game)
	_game.player.set_controls_captured(true)
	await get_tree().physics_frame
	await get_tree().physics_frame


func after_test() -> void:
	_game.player.set_controls_captured(false)


func test_player_lands_on_flat_world() -> void:
	for frame: int in range(60):
		await get_tree().physics_frame
	assert_bool(_game.player.is_on_floor()).is_true()
	assert_float(_game.player.position.y).is_between(-0.02, 0.05)


func test_mouse_buttons_edit_the_target_and_released_mouse_does_not_edit() -> void:
	_game.player.camera.look_at(Vector3(0.25, 0.0, 0.25), Vector3.UP)
	var right_click: InputEventMouseButton = InputEventMouseButton.new()
	right_click.button_index = MOUSE_BUTTON_RIGHT
	right_click.pressed = true
	_game.player.handle_input(right_click)
	assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.STONE)
	var left_click: InputEventMouseButton = InputEventMouseButton.new()
	left_click.button_index = MOUSE_BUTTON_LEFT
	left_click.pressed = true
	_game.player.handle_input(left_click)
	assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)
	_game.player.set_controls_captured(false)
	_game.player.handle_input(left_click)
	assert_bool(_game.player.controls_captured()).is_true()
	assert_int(_game.world_data.get_block(Vector3i(0, -1, 0))).is_equal(VoxelWorldData.Block.GRASS)


func test_edited_voxels_update_real_physics_collision() -> void:
	_game.world_data.place_block(Vector3i.ZERO, VoxelWorldData.Block.STONE)
	_game.world_view.rebuild_pending()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		Vector3(0.25, 2, 0.25), Vector3(0.25, -2, 0.25), 1
	)
	var hit: Dictionary = _game.get_world_3d().direct_space_state.intersect_ray(query)
	assert_bool(hit.is_empty()).is_false()
	assert_float(Vector3(hit["position"]).y).is_equal_approx(0.5, 0.001)
	_game.world_data.break_block(Vector3i.ZERO)
	_game.world_view.rebuild_pending()
	await get_tree().physics_frame
	await get_tree().physics_frame
	hit = _game.get_world_3d().direct_space_state.intersect_ray(query)
	assert_float(Vector3(hit["position"]).y).is_equal_approx(0.0, 0.001)


func test_player_respawns_after_falling_outside_world() -> void:
	_game.player.position = Vector3(20, -9, 20)
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_vector(_game.player.position).is_equal_approx(_game.player.spawn_position, Vector3.ONE * 0.1)


func test_respawn_is_clear_when_original_spawn_is_built_over() -> void:
	for x: int in range(-1, 2):
		for y: int in range(4):
			for z: int in range(5, 8):
				_game.world_data.place_block(Vector3i(x, y, z), VoxelWorldData.Block.STONE)
	_game.player.position = Vector3(20, -9, 20)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var intersections: int = 0
	for cell: Vector3i in _game.world_data.solid_cells():
		if VoxelWorldData.cell_bounds(cell).intersects(_game.player.occupied_bounds()):
			intersections += 1
	assert_int(intersections).is_equal(0)
	for frame: int in range(60):
		await get_tree().physics_frame
	assert_bool(_game.player.is_on_floor()).is_true()
	assert_float(_game.player.velocity.y).is_equal(0.0)


func test_automatic_collision_update_precedes_player_fall() -> void:
	_game.player.set_controls_captured(false)
	await get_tree().physics_frame
	_game.player.position = Vector3(0.25, 0.55, 0.25)
	_game.player.velocity = Vector3(0, -5, 0)
	_game.world_data.place_block(Vector3i.ZERO, VoxelWorldData.Block.STONE)
	await get_tree().physics_frame
	assert_float(_game.player.position.y).is_greater_equal(0.49)
