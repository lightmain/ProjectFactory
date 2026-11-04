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
		if blocks[index] == VoxelWorldData.Block.BELT:
			assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)
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


func test_belt_two_clicks_and_c_keep_the_entire_preview_prefix() -> void:
	_key(KEY_5)
	_click(MOUSE_BUTTON_RIGHT)
	assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)
	_game.player.camera.look_at(Vector3(1.25, 0, 0.25), Vector3.UP)
	_key(KEY_C)
	_game.player.camera.look_at(Vector3(1.25, 0, 1.25), Vector3.UP)
	_key(KEY_C)
	_game.player.camera.look_at(Vector3(0.25, 0, 1.25), Vector3.UP)
	_click(MOUSE_BUTTON_RIGHT)
	for cell: Vector3i in [
		Vector3i.ZERO, Vector3i.RIGHT, Vector3i(2, 0, 0), Vector3i(2, 0, 1),
		Vector3i(2, 0, 2), Vector3i(1, 0, 2), Vector3i(0, 0, 2),
	]:
		assert_int(_game.world_data.get_block(cell)).is_equal(VoxelWorldData.Block.BELT)


func test_failed_height_and_crossing_keys_preserve_start_and_show_bottom_notice() -> void:
	for z: int in range(VoxelWorldData.MIN_CELL.z, VoxelWorldData.MAX_CELL.z):
		_game.world_data.place_block(Vector3i(1, 0, z), VoxelWorldData.Block.BELT)
	_key(KEY_5)
	_click(MOUSE_BUTTON_RIGHT)
	_game.player.camera.look_at(Vector3(1.75, 0, 0.25), Vector3.UP)
	_key(KEY_C)
	_click(MOUSE_BUTTON_RIGHT)
	assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)
	var notice: Label = _game.hud.get_node_or_null("BuildNotice") as Label
	assert_object(notice).is_not_null()
	if notice != null:
		assert_str(notice.text).is_equal("与现有传送带交叉")
		assert_bool(notice.visible).is_true()
	_game.world_data.place_block(Vector3i(-2, 0, 0), VoxelWorldData.Block.STONE)
	_game.player.camera.look_at(Vector3(-0.75, 0.5, 0.25), Vector3.UP)
	_click(MOUSE_BUTTON_RIGHT)
	assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)
	_game.player.camera.look_at(Vector3(0.25, 0, 1.25), Vector3.UP)
	_click(MOUSE_BUTTON_RIGHT)
	for z: int in range(3):
		assert_int(_game.world_data.get_block(Vector3i(0, 0, z))).is_equal(VoxelWorldData.Block.BELT)


func test_lmb_cancels_belt_without_breaking_and_inventory_resumes_pending_route() -> void:
	_key(KEY_5)
	_click(MOUSE_BUTTON_RIGHT)
	_click(MOUSE_BUTTON_LEFT)
	assert_int(_game.world_data.get_block(Vector3i(0, -1, 0))).is_equal(VoxelWorldData.Block.GRASS)
	_click(MOUSE_BUTTON_RIGHT)
	_key(KEY_I)
	_game.player.camera.look_at(Vector3(1.25, 0, 0.25), Vector3.UP)
	_key(KEY_C)
	_click(MOUSE_BUTTON_RIGHT)
	assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)
	_key(KEY_I)
	_click(MOUSE_BUTTON_RIGHT)
	for x: int in range(3):
		assert_int(_game.world_data.get_block(Vector3i(x, 0, 0))).is_equal(VoxelWorldData.Block.BELT)


func test_machine_ghost_follows_aim_without_collision_and_hides_in_inventory() -> void:
	_key(KEY_4)
	await get_tree().process_frame
	await get_tree().process_frame
	var preview: Node3D = _game.get_node_or_null("BuildPreview") as Node3D
	assert_object(preview).is_not_null()
	if preview == null:
		return
	assert_bool(preview.visible).is_true()
	assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)
	_key(KEY_I)
	assert_bool(preview.visible).is_false()
	_key(KEY_I)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_bool(preview.visible).is_true()


func test_already_invalid_preview_flashes_more_brightly_when_c_is_rejected() -> void:
	for z: int in range(VoxelWorldData.MIN_CELL.z, VoxelWorldData.MAX_CELL.z):
		_game.world_data.place_block(Vector3i(1, 0, z), VoxelWorldData.Block.BELT)
	_key(KEY_5)
	_click(MOUSE_BUTTON_RIGHT)
	_game.player.camera.look_at(Vector3(1.75, 0, 0.25), Vector3.UP)
	await get_tree().process_frame
	await get_tree().process_frame
	var bodies: MultiMeshInstance3D = _game.get_node("BuildPreview/Bodies") as MultiMeshInstance3D
	var material: StandardMaterial3D = bodies.material_override as StandardMaterial3D
	var before: Color = material.albedo_color
	_key(KEY_C)
	assert_bool(material.albedo_color.is_equal_approx(before)).is_false()
	_game._process(0.4)
	assert_bool(material.albedo_color.is_equal_approx(before)).is_true()
	assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)


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


func test_c_marks_each_locked_waypoint_and_keeps_yellow_markers_on_failure() -> void:
	_key(KEY_5)
	_click(MOUSE_BUTTON_RIGHT)
	_game.player.camera.look_at(Vector3(1.25, 0, 0.25), Vector3.UP)
	_key(KEY_C)
	_game._process(0.0)
	var rings: MultiMeshInstance3D = _game.get_node_or_null("BuildPreview/LockRings") as MultiMeshInstance3D
	assert_object(rings).is_not_null()
	if rings == null:
		return
	assert_int(rings.multimesh.instance_count).is_equal(1)
	# The headless dummy renderer does not retain MultiMesh transforms.
	# Verify waypoint cells here; ring positions are checked in the live editor.
	assert_array(_game.belt_placement.locked_points).contains_exactly([Vector3i(2, 0, 0)])
	_key(KEY_C)
	_game._process(0.0)
	assert_int(rings.multimesh.instance_count).is_equal(1)
	_game.player.camera.look_at(Vector3(1.25, 0, 1.25), Vector3.UP)
	_key(KEY_C)
	_game._process(0.0)
	assert_int(rings.multimesh.instance_count).is_equal(2)
	_game.player.camera.rotation.x = 0.5
	_key(KEY_C)
	_click(MOUSE_BUTTON_RIGHT)
	_game._process(0.0)
	assert_int(rings.multimesh.instance_count).is_equal(2)
	var material: StandardMaterial3D = rings.material_override as StandardMaterial3D
	assert_float(material.albedo_color.r).is_greater(0.9)
	assert_float(material.albedo_color.g).is_greater(0.7)
	assert_float(material.albedo_color.b).is_less(0.3)
	_key(KEY_I)
	assert_bool(_game.build_preview.visible).is_false()
	_key(KEY_I)
	_game._process(0.0)
	assert_bool(_game.build_preview.visible).is_true()
	assert_int(rings.multimesh.instance_count).is_equal(2)
	_click(MOUSE_BUTTON_LEFT)
	assert_int(rings.multimesh.instance_count).is_equal(0)
	_game.player.camera.look_at(Vector3(0.25, 0, 0.25), Vector3.UP)
	_click(MOUSE_BUTTON_RIGHT)
	_game.player.camera.look_at(Vector3(1.25, 0, 0.25), Vector3.UP)
	_key(KEY_C)
	_game.player.camera.look_at(Vector3(1.25, 0, 1.25), Vector3.UP)
	_click(MOUSE_BUTTON_RIGHT)
	_game._process(0.0)
	assert_int(rings.multimesh.instance_count).is_equal(0)
	assert_int(_game.world_data.get_block(Vector3i(2, 0, 0))).is_equal(VoxelWorldData.Block.BELT)


func test_belt_build_lifts_overlapping_player_immediately_and_stands_still() -> void:
	_game.player.set_physics_process(false)
	_game.player.global_position = Vector3(0.25, 0, 1.25)
	_game.player.camera.look_at(Vector3(0.25, 0, 0.25), Vector3.UP)
	_key(KEY_5)
	_click(MOUSE_BUTTON_RIGHT)
	_game.player.camera.look_at(Vector3(0.25, 0, 2.25), Vector3.UP)
	_game.player.velocity = Vector3(1, -2, 0)
	_click(MOUSE_BUTTON_RIGHT)
	assert_int(_game.world_data.get_block(Vector3i(0, 0, 2))).is_equal(VoxelWorldData.Block.BELT)
	assert_float(_game.player.global_position.y).is_equal_approx(0.08 + _game.player.safe_margin, 0.0001)
	assert_float(_game.player.velocity.y).is_equal(0.0)
	assert_float(_game.player.global_position.x).is_equal(0.25)
	assert_float(_game.player.global_position.z).is_equal(1.25)
	_game.world_view.rebuild_pending()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_game.player.set_physics_process(true)
	for frame: int in range(15):
		await get_tree().physics_frame
	assert_bool(_game.player.is_on_floor()).is_true()
	assert_float(_game.player.global_position.y).is_equal_approx(0.08, 0.005)
	assert_float(_game.player.global_position.x).is_equal_approx(0.25, 0.001)
	assert_float(_game.player.global_position.z).is_equal_approx(1.25, 0.001)


func test_belt_build_without_player_overlap_does_not_move_player() -> void:
	_game.player.set_physics_process(false)
	var before: Vector3 = _game.player.global_position
	_key(KEY_5)
	_click(MOUSE_BUTTON_RIGHT)
	_game.player.camera.look_at(Vector3(1.25, 0, 0.25), Vector3.UP)
	_click(MOUSE_BUTTON_RIGHT)
	assert_vector(_game.player.global_position).is_equal(before)


func test_player_can_begin_and_lock_at_own_feet_then_commit_locked_prefix() -> void:
	_game.player.set_physics_process(false)
	_game.player.global_position = Vector3(0.25, 0, 0.25)
	_game.player.camera.look_at(Vector3(0.35, 0, 0.35), Vector3.UP)
	_key(KEY_5)
	_click(MOUSE_BUTTON_RIGHT)
	assert_bool(_game.belt_placement.active).is_true()
	_game.player.global_position = Vector3(1.25, 0, 0.25)
	_game.player.camera.look_at(Vector3(1.35, 0, 0.35), Vector3.UP)
	_key(KEY_C)
	assert_array(_game.belt_placement.locked_points).contains_exactly([Vector3i(2, 0, 0)])
	assert_array(_game.belt_placement.path).contains_exactly([
		Vector3i.ZERO, Vector3i.RIGHT, Vector3i(2, 0, 0),
	])
	_click(MOUSE_BUTTON_RIGHT)
	assert_bool(_game.belt_placement.active).is_false()
	assert_float(_game.player.global_position.y).is_equal_approx(0.081, 0.0001)
	for x: int in range(3):
		assert_int(_game.world_data.get_block(Vector3i(x, 0, 0))).is_equal(VoxelWorldData.Block.BELT)


func test_belt_build_with_no_headroom_preserves_route_and_player() -> void:
	_game.player.set_physics_process(false)
	_game.player.global_position = Vector3(0.25, 0, 1.25)
	_game.world_data.place_block(Vector3i(0, 4, 2), VoxelWorldData.Block.STONE)
	_game.world_data.place_block(Vector3i(0, 0, 0), VoxelWorldData.Block.STONE)
	_game.world_data.place_block(Vector3i(0, 0, 4), VoxelWorldData.Block.STONE)
	_game.world_view.rebuild_pending()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_game.player.camera.look_at(Vector3(0.25, 0.5, 0.25), Vector3.UP)
	_key(KEY_5)
	_click(MOUSE_BUTTON_RIGHT)
	_game.player.camera.look_at(Vector3(0.25, 0.5, 2.25), Vector3.UP)
	_click(MOUSE_BUTTON_RIGHT)
	assert_int(_game.world_data.get_block(Vector3i(0, 1, 2))).is_equal(VoxelWorldData.Block.AIR)
	assert_bool(_game.belt_placement.active).is_true()
	assert_float(_game.player.global_position.y).is_equal(0.0)


func test_pending_ceiling_collision_cannot_allow_belt_lift_through_ceiling() -> void:
	_game.player.set_physics_process(false)
	_game.player.global_position = Vector3(0.25, 0, 1.25)
	_game.world_data.place_block(Vector3i(0, 0, 0), VoxelWorldData.Block.STONE)
	_game.world_data.place_block(Vector3i(0, 0, 4), VoxelWorldData.Block.STONE)
	_game.world_view.rebuild_pending()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_game.player.camera.look_at(Vector3(0.25, 0.5, 0.25), Vector3.UP)
	_key(KEY_5)
	_click(MOUSE_BUTTON_RIGHT)
	_game.player.camera.look_at(Vector3(0.25, 0.5, 2.25), Vector3.UP)
	_key(KEY_C)
	assert_array(_game.belt_placement.locked_points).contains_exactly([Vector3i(0, 1, 4)])
	# Commit in the same tick: the new ceiling has data but no collider yet.
	_game.world_data.place_block(Vector3i(0, 4, 2), VoxelWorldData.Block.STONE)
	_click(MOUSE_BUTTON_RIGHT)
	assert_bool(_game.belt_placement.active).is_true()
	assert_array(_game.belt_placement.locked_points).contains_exactly([Vector3i(0, 1, 4)])
	assert_float(_game.player.global_position.y).is_equal(0.0)
	for z: int in range(5):
		assert_int(_game.world_data.get_block(Vector3i(0, 1, z))).is_equal(VoxelWorldData.Block.AIR)
