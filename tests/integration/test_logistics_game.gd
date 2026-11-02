extends GdUnitTestSuite

var _game: FactoryGame


func before_test() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_game = auto_free(scene.instantiate()) as FactoryGame
	add_child(_game)
	_game.player.set_controls_captured(true)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_game.player.camera.look_at(Vector3(0.25, 0.0, 0.25), Vector3.UP)


func after_test() -> void:
	_game.player.set_controls_captured(false)


func _key(code: Key) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = code
	event.pressed = true
	_game.player.handle_input(event)


func _click(button: MouseButton) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button
	event.pressed = true
	_game.player.handle_input(event)


func test_hotbar_four_five_six_place_and_break_single_cell_machines() -> void:
	var keys: Array[Key] = [KEY_4, KEY_5, KEY_6]
	var blocks: Array[int] = [
		VoxelWorldData.Block.MINER, VoxelWorldData.Block.BELT, VoxelWorldData.Block.CHEST,
	]
	for index: int in range(keys.size()):
		_key(keys[index])
		assert_int(_game.selected_block).is_equal(blocks[index])
		_click(MOUSE_BUTTON_RIGHT)
		assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(blocks[index])
		assert_vector(_game.logistics_data.direction_at(Vector3i.ZERO)).is_equal(Vector3i.FORWARD)
		_click(MOUSE_BUTTON_LEFT)
		assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)
		assert_int(_game.logistics_data.machine_cells().size()).is_equal(0)


func test_r_rotates_placement_clockwise_and_selection_resets_rotation() -> void:
	_key(KEY_4)
	_key(KEY_R)
	_click(MOUSE_BUTTON_RIGHT)
	assert_vector(_game.logistics_data.direction_at(Vector3i.ZERO)).is_equal(Vector3i.RIGHT)
	_click(MOUSE_BUTTON_LEFT)
	_key(KEY_5)
	_click(MOUSE_BUTTON_RIGHT)
	assert_vector(_game.logistics_data.direction_at(Vector3i.ZERO)).is_equal(Vector3i.FORWARD)


func test_hidden_world_keeps_producing_and_custom_exports_reach_the_miner() -> void:
	_game.set_physics_process(false)
	_game.logistics_data.bind_world(_game.world_data, 0.2, 3)
	_game.world_data.place_block(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	_game.logistics_data.set_direction(Vector3i.ZERO, Vector3i.RIGHT)
	_game.world_data.place_block(Vector3i.RIGHT, VoxelWorldData.Block.CHEST)
	_game.logistics_data.set_direction(Vector3i.RIGHT, Vector3i.RIGHT)
	_game.world_view.hide()
	_game.world_view.set_process(false)
	_game.world_view.set_physics_process(false)
	_game.logistics_view.hide()
	_game.logistics_view.set_process(false)
	_game.logistics_data.advance(2.0)
	assert_int(_game.logistics_data.ore_count(Vector3i.RIGHT)).is_equal(30)
	_game.set_physics_process(true)
	var before: int = _game.logistics_data.total_ore()
	for frame: int in range(20):
		await get_tree().physics_frame
	assert_int(_game.logistics_data.total_ore()).is_greater(before)


func test_culled_and_deleted_logistics_view_do_not_stop_the_factory() -> void:
	_game.world_data.place_block(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	_game.logistics_view.render_distance = 0.1
	await get_tree().process_frame
	await get_tree().process_frame
	assert_int(_game.logistics_view.get_child_count()).is_equal(0)
	_game.logistics_view.render_distance = 20.0
	await get_tree().process_frame
	await get_tree().process_frame
	assert_int(_game.logistics_view.get_child_count()).is_equal(1)
	_game.logistics_view.free()
	for frame: int in range(65):
		await get_tree().physics_frame
	assert_int(_game.logistics_data.ore_count(Vector3i.ZERO)).is_greater_equal(1)


func test_inventory_blocks_machine_selection_rotation_and_placement() -> void:
	_key(KEY_4)
	_key(KEY_I)
	_key(KEY_6)
	_key(KEY_R)
	_click(MOUSE_BUTTON_RIGHT)
	assert_int(_game.selected_block).is_equal(VoxelWorldData.Block.MINER)
	assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)
	_key(KEY_I)
	_click(MOUSE_BUTTON_RIGHT)
	assert_vector(_game.logistics_data.direction_at(Vector3i.ZERO)).is_equal(Vector3i.FORWARD)


func test_machine_placement_respects_player_body_and_real_collision() -> void:
	_key(KEY_4)
	assert_bool(_game.world_data.place_block(
		Vector3i(0, 0, 6), VoxelWorldData.Block.MINER, _game.player.occupied_bounds()
	)).is_false()
	_click(MOUSE_BUTTON_RIGHT)
	_game.world_view.rebuild_pending()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		Vector3(0.25, 2, 0.25), Vector3(0.25, -2, 0.25), 1
	)
	var hit: Dictionary = _game.get_world_3d().direct_space_state.intersect_ray(query)
	assert_bool(hit.is_empty()).is_false()
	assert_float(Vector3(hit["position"]).y).is_equal_approx(0.5, 0.001)


func test_main_scene_exports_configure_new_miners() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	var configured: FactoryGame = auto_free(scene.instantiate()) as FactoryGame
	assert_float(configured.mining_interval).is_equal(1.0)
	assert_int(configured.mining_amount).is_equal(1)
	configured.mining_interval = 0.25
	configured.mining_amount = 5
	add_child(configured)
	configured.set_physics_process(false)
	configured.world_data.place_block(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	configured.logistics_data.advance(1.0)
	assert_int(configured.logistics_data.ore_count(Vector3i.ZERO)).is_equal(20)
	configured.player.set_controls_captured(false)


func test_changed_exports_only_affect_miners_placed_after_the_change() -> void:
	_game.set_physics_process(false)
	_key(KEY_4)
	_click(MOUSE_BUTTON_RIGHT)
	_game.logistics_data.advance(0.25)
	_game.mining_interval = 0.25
	_game.mining_amount = 5
	_game.player.camera.look_at(Vector3(0.75, 0.0, 0.25), Vector3.UP)
	_click(MOUSE_BUTTON_RIGHT)
	assert_int(_game.world_data.get_block(Vector3i(1, 0, 0))).is_equal(VoxelWorldData.Block.MINER)
	_game.logistics_data.advance(0.75)
	assert_int(_game.logistics_data.ore_count(Vector3i.ZERO)).is_equal(1)
	assert_int(_game.logistics_data.ore_count(Vector3i(1, 0, 0))).is_equal(15)


func test_belt_physics_and_target_outline_follow_the_thin_top() -> void:
	_key(KEY_5)
	_click(MOUSE_BUTTON_RIGHT)
	_game.world_view.rebuild_pending()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		Vector3(0.25, 1, 0.25), Vector3(0.25, -1, 0.25), 1
	)
	var hit: Dictionary = _game.get_world_3d().direct_space_state.intersect_ray(query)
	assert_float(Vector3(hit["position"]).y).is_equal_approx(0.08, 0.001)
	_game.player.camera.look_at(Vector3(0.25, 0.04, 0.25), Vector3.UP)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_float(_game.target_outline.position.y).is_equal_approx(0.04, 0.0001)
	assert_float(_game.target_outline.scale.y).is_equal_approx(0.16, 0.0001)


func test_partial_neighbors_do_not_hide_exposed_block_faces_or_belt_top() -> void:
	_game.world_data.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	_game.world_data.place_block(Vector3i.RIGHT, VoxelWorldData.Block.STONE)
	_game.world_data.place_block(Vector3i.UP, VoxelWorldData.Block.STONE)
	_game.world_view.rebuild_pending()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		Vector3(0.25, 0.25, 0.25), Vector3(1.25, 0.25, 0.25), 1
	)
	var hit: Dictionary = _game.get_world_3d().direct_space_state.intersect_ray(query)
	assert_bool(hit.is_empty()).is_false()
	if hit.is_empty():
		return
	assert_float(Vector3(hit["position"]).x).is_equal_approx(0.5, 0.001)
	query = PhysicsRayQueryParameters3D.create(
		Vector3(0.25, 0.4, 0.25), Vector3(0.25, -1, 0.25), 1
	)
	hit = _game.get_world_3d().direct_space_state.intersect_ray(query)
	assert_bool(hit.is_empty()).is_false()
	if hit.is_empty():
		return
	assert_float(Vector3(hit["position"]).y).is_equal_approx(0.08, 0.001)
