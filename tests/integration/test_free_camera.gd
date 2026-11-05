extends GdUnitTestSuite

var _game: FactoryGame


func before_test() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_game = auto_free(scene.instantiate()) as FactoryGame
	add_child(_game)
	await get_tree().physics_frame
	for frame: int in range(12):
		await get_tree().physics_frame


func after_test() -> void:
	_game.player.set_controls_captured(false)


func _key(code: Key) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = true
	_game.player.handle_input(event)


func test_tab_enters_above_player_and_returns_to_unchanged_first_person() -> void:
	var original_rotation: Vector3 = _game.player.camera.rotation
	var player_position: Vector3 = _game.player.global_position
	_key(KEY_TAB)
	var current: Camera3D = _game.get_viewport().get_camera_3d()
	assert_bool(current != _game.player.camera).is_true()
	assert_bool(_game.player.controls_captured()).is_false()
	assert_float(current.global_position.y).is_equal_approx(
		player_position.y + FactoryPlayer.BODY_HEIGHT + 4.0, 0.001
	)
	assert_float(current.rotation.x).is_equal_approx(deg_to_rad(-75.0), 0.001)
	_key(KEY_TAB)
	assert_bool(_game.player.camera.is_current()).is_true()
	assert_bool(_game.player.controls_captured()).is_true()
	assert_vector(_game.player.camera.rotation).is_equal(original_rotation)
	assert_vector(_game.player.global_position).is_equal(player_position)


func _mouse(button: MouseButton, position: Vector2, pressed: bool = true) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button
	event.position = position
	event.pressed = pressed
	_game.player.handle_input(event)


func test_tab_always_enters_north_up_from_each_player_heading() -> void:
	for heading: float in [0.0, PI * 0.5, PI, -PI * 0.5]:
		var player_rotation: Vector3 = Vector3(-0.2, heading, 0)
		_game.player.camera.rotation = player_rotation
		_key(KEY_TAB)
		var camera: Camera3D = _game.free_camera.camera
		var ground: Vector3 = Vector3(
			_game.player.global_position.x, 0, _game.player.global_position.z
		)
		var origin_screen: Vector2 = camera.unproject_position(ground)
		var north_screen: Vector2 = camera.unproject_position(ground + Vector3.FORWARD)
		var east_screen: Vector2 = camera.unproject_position(ground + Vector3.RIGHT)
		assert_float(north_screen.y).is_less(origin_screen.y)
		assert_float(north_screen.x).is_equal_approx(origin_screen.x, 0.001)
		assert_float(east_screen.x).is_greater(origin_screen.x)
		assert_float(east_screen.y).is_equal_approx(origin_screen.y, 0.001)
		assert_float(camera.rotation.x).is_equal_approx(deg_to_rad(-75), 0.001)
		# A prior free-camera turn must not become the next entry orientation.
		camera.rotation = Vector3(-0.8, 0.6, 0)
		_key(KEY_TAB)
		assert_vector(_game.player.camera.rotation).is_equal_approx(
			player_rotation, Vector3.ONE * 0.001
		)
		assert_bool(_game.player.camera.is_current()).is_true()


func _point_at(position: Vector3) -> Vector2:
	var screen: Vector2 = _game.free_camera.camera.unproject_position(position)
	var event: InputEventMouseMotion = InputEventMouseMotion.new()
	event.position = screen
	_game.player.handle_input(event)
	return screen


func test_free_cursor_builds_in_two_places_without_recapturing_or_moving_player() -> void:
	_key(KEY_TAB)
	_key(KEY_4)
	var before: Vector3 = _game.player.global_position
	for cell: Vector3i in [Vector3i(-2, 0, 4), Vector3i(2, 0, 4)]:
		var screen: Vector2 = _point_at(Vector3(cell) * 0.5 + Vector3(0.25, 0, 0.25))
		_mouse(MOUSE_BUTTON_RIGHT, screen)
		assert_int(_game.world_data.get_block(cell)).is_equal(VoxelWorldData.Block.MINER)
		assert_vector(_game.logistics_data.direction_at(cell)).is_equal(Vector3i.BACK)
	assert_bool(_game.player.controls_captured()).is_false()
	assert_int(Input.mouse_mode).is_equal(Input.MOUSE_MODE_VISIBLE)
	Input.action_press("move_forward")
	Input.action_press("jump")
	for frame: int in range(8):
		await get_tree().physics_frame
	Input.action_release("move_forward")
	Input.action_release("jump")
	assert_vector(_game.player.global_position).is_equal_approx(before, Vector3.ONE * 0.002)
	assert_bool(_game.player.body_visual.visible).is_true()
	_key(KEY_TAB)
	assert_bool(_game.player.body_visual.visible).is_false()


func test_only_middle_drag_rotates_camera_and_does_not_build() -> void:
	_key(KEY_TAB)
	var rotation: Vector3 = _game.free_camera.camera.rotation
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = Vector2(300, 250)
	motion.relative = Vector2(30, 20)
	_game.player.handle_input(motion)
	assert_vector(_game.free_camera.camera.rotation).is_equal(rotation)
	_mouse(MOUSE_BUTTON_MIDDLE, motion.position)
	_game.player.handle_input(motion)
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_bool(_game.free_camera.camera.rotation.is_equal_approx(rotation)).is_false()
	var count: int = _game.world_data.block_count()
	_mouse(MOUSE_BUTTON_RIGHT, motion.position)
	assert_int(_game.world_data.block_count()).is_equal(count)
	_mouse(MOUSE_BUTTON_MIDDLE, motion.position, false)
	assert_int(Input.mouse_mode).is_equal(Input.MOUSE_MODE_VISIBLE)
	assert_vector(_game.free_camera.cursor_position).is_equal(motion.position)


func test_camera_hits_real_wall_and_data_only_ceiling_and_stays_near_player() -> void:
	_game.world_data.place_block(Vector3i(0, 5, 6), VoxelWorldData.Block.STONE)
	_key(KEY_TAB)
	assert_float(_game.free_camera.global_position.y).is_less_equal(2.381)
	_game.world_data.place_block(Vector3i(2, 4, 0), VoxelWorldData.Block.STONE)
	_game.world_view.rebuild_pending()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_game.free_camera.global_position = Vector3(0.25, 2.25, 0.25)
	_game.free_camera.camera.rotation.y = 0
	_game.free_camera.move_camera(Vector3.RIGHT, 1)
	assert_float(_game.free_camera.global_position.x).is_between(0.87, 0.881)
	assert_bool(_game.free_camera.test_move(_game.free_camera.global_transform, Vector3.RIGHT * 0.03)).is_true()
	_game.free_camera.move_camera(Vector3.UP, 10)
	assert_float(_game.free_camera.global_position.distance_to(
		_game.free_camera.anchor_position()
	)).is_less_equal(12.001)


func test_voxels_and_belts_cannot_be_built_into_camera_and_occlusion_is_preserved() -> void:
	_key(KEY_TAB)
	_game.free_camera.global_position = Vector3(0.25, 0.19, 0.25)
	var screen: Vector2 = _point_at(Vector3(0.25, 0, 0.25))
	_mouse(MOUSE_BUTTON_RIGHT, screen)
	assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)
	_key(KEY_5)
	_mouse(MOUSE_BUTTON_RIGHT, screen)
	_mouse(MOUSE_BUTTON_RIGHT, screen)
	assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)
	assert_bool(_game.belt_placement.active).is_true()
	_key(KEY_ESCAPE)
	assert_bool(_game.belt_placement.active).is_false()
	_game.free_camera.global_position = Vector3(0.25, 4, 0.25)
	_game.world_data.place_block(Vector3i(0, 2, 0), VoxelWorldData.Block.STONE)
	_point_at(Vector3(0.25, 0, 0.25))
	var hit: VoxelHit = _game.current_hit()
	assert_object(hit).is_not_null()
	assert_vector(hit.cell).is_equal(Vector3i(0, 2, 0))


func test_inventory_and_focus_loss_stop_free_motion_and_middle_capture() -> void:
	_key(KEY_TAB)
	_mouse(MOUSE_BUTTON_MIDDLE, Vector2(300, 250))
	_key(KEY_I)
	assert_bool(_game.free_camera.is_rotating()).is_false()
	var before: Vector3 = _game.free_camera.global_position
	_game.free_camera.move_camera(Vector3.UP, 1)
	assert_vector(_game.free_camera.global_position).is_equal(before)
	_key(KEY_I)
	_mouse(MOUSE_BUTTON_MIDDLE, Vector2(300, 250))
	_game.player._notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	assert_bool(_game.free_camera.is_rotating()).is_false()
	assert_int(Input.mouse_mode).is_equal(Input.MOUSE_MODE_VISIBLE)
	_game.free_camera.move_camera(Vector3.UP, 1)
	assert_vector(_game.free_camera.global_position).is_equal(before)
	_game.player._notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	_game.free_camera.move_camera(Vector3.UP, 0.1)
	assert_float(_game.free_camera.global_position.y).is_greater(before.y)


func test_world_build_direction_survives_turning_and_tool_selection() -> void:
	_key(KEY_4)
	var initial: Vector3i = _game.build_direction()
	assert_vector(initial).is_equal(Vector3i.BACK)
	_game.player.camera.rotation.y += PI
	assert_vector(_game.build_direction()).is_equal(initial)
	_key(KEY_R)
	var rotated: Vector3i = _game.build_direction()
	assert_vector(rotated).is_equal(Vector3i.LEFT)
	_key(KEY_6)
	assert_vector(_game.build_direction()).is_equal(rotated)
	_key(KEY_TAB)
	assert_vector(_game.build_direction()).is_equal(rotated)


func test_tab_is_blocked_by_inventory_and_free_cursor_survives_modal_close() -> void:
	_key(KEY_I)
	_key(KEY_TAB)
	assert_bool(_game.player.camera.is_current()).is_true()
	_key(KEY_I)
	_key(KEY_TAB)
	var current: Camera3D = _game.get_viewport().get_camera_3d()
	assert_bool(current != _game.player.camera).is_true()
	_key(KEY_I)
	_key(KEY_I)
	assert_bool(_game.get_viewport().get_camera_3d() == current).is_true()
	assert_bool(_game.player.controls_captured()).is_false()


func test_camera_reset_keeps_inventory_pause_and_recovers_after_close() -> void:
	_key(KEY_TAB)
	_key(KEY_I)
	_game.player.respawn(Vector3(30, 0, 30))
	_game.free_camera._physics_process(0.016)
	assert_float(_game.free_camera.global_position.distance_to(
		_game.free_camera.anchor_position()
	)).is_less_equal(12.001)
	var reset_position: Vector3 = _game.free_camera.global_position
	_game.free_camera.move_camera(Vector3.UP, 0.1)
	assert_vector(_game.free_camera.global_position).is_equal(reset_position)
	_key(KEY_I)
	_game.free_camera.move_camera(Vector3.UP, 0.1)
	assert_float(_game.free_camera.global_position.y).is_greater(reset_position.y)


func test_belt_preview_tracks_camera_overlap_before_and_after_rejected_commit() -> void:
	_key(KEY_TAB)
	_key(KEY_5)
	_game.free_camera.global_position = Vector3(0.25, 0.25, 0.25)
	var screen: Vector2 = _point_at(Vector3(0.25, 0, 0.25))
	_game._process(0.016)
	var bodies: MultiMeshInstance3D = _game.build_preview.get_node("Bodies") as MultiMeshInstance3D
	var material: StandardMaterial3D = bodies.material_override as StandardMaterial3D
	assert_bool(material.albedo_color.b > material.albedo_color.r).is_true()
	# The cursor still hits the same ground cell while the thin belt overlap changes.
	_game.free_camera.move_camera(Vector3.DOWN, 0.012)
	screen = _point_at(Vector3(0.25, 0, 0.25))
	_game._process(0.016)
	assert_bool(material.albedo_color.r > material.albedo_color.b).is_true()
	_mouse(MOUSE_BUTTON_RIGHT, screen)
	assert_bool(_game.belt_placement.active).is_true()
	var path_before_lock: Array[Vector3i] = _game.belt_placement.locked_path.duplicate()
	var points_before_lock: Array[Vector3i] = _game.belt_placement.locked_points.duplicate()
	_key(KEY_C)
	assert_array(_game.belt_placement.locked_path).is_equal(path_before_lock)
	assert_array(_game.belt_placement.locked_points).is_equal(points_before_lock)
	_mouse(MOUSE_BUTTON_RIGHT, screen)
	assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(VoxelWorldData.Block.AIR)
	_game._process(0.5)
	assert_bool(material.albedo_color.r > material.albedo_color.b).is_true()
	_game.free_camera.move_camera(Vector3.UP, 0.012)
	_point_at(Vector3(0.25, 0, 0.25))
	_game._process(0.016)
	assert_bool(material.albedo_color.b > material.albedo_color.r).is_true()


func _center_surface() -> Vector3:
	var camera: Camera3D = _game.free_camera.camera
	var ray: Vector3 = -camera.global_basis.z
	var hit: VoxelHit = VoxelRaycast.cast(_game.world_data, camera.global_position, ray, 40)
	assert_object(hit).is_not_null()
	return camera.global_position + ray * hit.distance if hit != null else Vector3.ZERO


func test_wheel_zooms_towards_nearest_center_surface_without_rotating() -> void:
	_key(KEY_TAB)
	_game.free_camera.global_position = Vector3(0.25, 4, 0.25)
	_game.free_camera.camera.rotation = Vector3(deg_to_rad(-75), 0, 0)
	_game.world_data.place_block(Vector3i(0, 3, -1), VoxelWorldData.Block.STONE)
	var pivot: Vector3 = _center_surface()
	assert_float(pivot.y).is_equal_approx(2, 0.001)
	var before: Vector3 = _game.free_camera.global_position
	var rotation: Vector3 = _game.free_camera.camera.rotation
	_mouse(MOUSE_BUTTON_WHEEL_UP, Vector2(50, 50))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var after: Vector3 = _game.free_camera.global_position
	assert_float(after.distance_to(pivot)).is_less(before.distance_to(pivot))
	assert_vector(_center_surface()).is_equal_approx(pivot, Vector3.ONE * 0.001)
	assert_vector(_game.free_camera.camera.rotation).is_equal(rotation)
	_mouse(MOUSE_BUTTON_WHEEL_DOWN, Vector2(1200, 600))
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_vector(_game.free_camera.global_position).is_equal_approx(before, Vector3.ONE * 0.002)


func test_middle_drag_orbits_fixed_surface_even_after_surface_is_removed() -> void:
	_key(KEY_TAB)
	var pivot: Vector3 = _center_surface()
	var radius: float = _game.free_camera.global_position.distance_to(pivot)
	var before: Vector3 = _game.free_camera.global_position
	_mouse(MOUSE_BUTTON_MIDDLE, Vector2(200, 200))
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.relative = Vector2(90, -35)
	_game.player.handle_input(motion)
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_bool(_game.free_camera.global_position.is_equal_approx(before)).is_false()
	assert_float(_game.free_camera.global_position.distance_to(pivot)).is_equal_approx(radius, 0.005)
	assert_float((-_game.free_camera.camera.global_basis.z).dot(
		(pivot - _game.free_camera.global_position).normalized()
	)).is_greater(0.9999)
	_game.world_data.break_block(VoxelWorldData.world_to_cell(pivot + Vector3.DOWN * 0.001))
	_game.player.handle_input(motion)
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_float(_game.free_camera.global_position.distance_to(pivot)).is_equal_approx(radius, 0.005)
	assert_float((-_game.free_camera.camera.global_basis.z).dot(
		(pivot - _game.free_camera.global_position).normalized()
	)).is_greater(0.9999)
	_mouse(MOUSE_BUTTON_MIDDLE, Vector2.ZERO, false)
	assert_int(Input.mouse_mode).is_equal(Input.MOUSE_MODE_VISIBLE)


func test_free_space_shift_are_inactive_and_modal_discards_pending_zoom() -> void:
	_key(KEY_TAB)
	var before: Vector3 = _game.free_camera.global_position
	Input.action_press("jump")
	for frame: int in range(4):
		await get_tree().physics_frame
	Input.action_release("jump")
	assert_vector(_game.free_camera.global_position).is_equal(before)
	var shift: InputEventKey = InputEventKey.new()
	shift.keycode = KEY_SHIFT
	shift.physical_keycode = KEY_SHIFT
	shift.pressed = true
	Input.parse_input_event(shift)
	for frame: int in range(4):
		await get_tree().physics_frame
	shift.pressed = false
	Input.parse_input_event(shift)
	assert_vector(_game.free_camera.global_position).is_equal(before)
	_mouse(MOUSE_BUTTON_WHEEL_UP, Vector2(500, 300))
	_key(KEY_I)
	_key(KEY_I)
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_vector(_game.free_camera.global_position).is_equal(before)
	_game.free_camera.camera.rotation.x = deg_to_rad(45)
	_mouse(MOUSE_BUTTON_WHEEL_UP, Vector2(500, 300))
	_mouse(MOUSE_BUTTON_MIDDLE, Vector2(500, 300))
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.relative = Vector2(100, 20)
	_game.player.handle_input(motion)
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_vector(_game.free_camera.global_position).is_equal(before)
	assert_float(_game.free_camera.camera.rotation.x).is_equal_approx(deg_to_rad(45), 0.001)


func test_soft_boundary_slows_outward_motion_and_allows_tangent_and_return() -> void:
	_key(KEY_TAB)
	_game.free_camera.camera.rotation.y = 0
	var anchor: Vector3 = _game.free_camera.anchor_position()
	_game.free_camera.global_position = anchor + Vector3.RIGHT * 9
	_game.free_camera.move_camera(Vector3.RIGHT, 0.02)
	var inner_step: float = _game.free_camera.global_position.x - anchor.x - 9
	_game.free_camera.global_position = anchor + Vector3.RIGHT * 11
	_game.free_camera.move_camera(Vector3.RIGHT, 0.02)
	var outer_step: float = _game.free_camera.global_position.x - anchor.x - 11
	assert_float(outer_step).is_between(0.001, inner_step * 0.8)
	_game.free_camera.global_position = anchor + Vector3.RIGHT * 12
	_game.free_camera.move_camera(Vector3.BACK, 0.1)
	assert_float(_game.free_camera.global_position.z).is_greater(anchor.z + 0.3)
	assert_float(_game.free_camera.global_position.distance_to(anchor)).is_less_equal(12.001)
	var before_return: Vector3 = _game.free_camera.global_position
	_game.free_camera.move_camera(Vector3.LEFT, 0.1)
	assert_float(_game.free_camera.global_position.x).is_less(before_return.x - 0.4)


func test_wheel_stops_before_thin_belt_and_ignores_release_events() -> void:
	_key(KEY_TAB)
	_game.free_camera.global_position = Vector3(0.25, 1, 0.25)
	_game.free_camera.camera.rotation = Vector3(deg_to_rad(-85), 0, 0)
	_game.world_data.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	var pivot: Vector3 = _center_surface()
	assert_float(pivot.y).is_equal_approx(0.08, 0.001)
	var before: Vector3 = _game.free_camera.global_position
	_mouse(MOUSE_BUTTON_WHEEL_UP, Vector2.ZERO, false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_vector(_game.free_camera.global_position).is_equal(before)
	for step: int in range(20):
		_mouse(MOUSE_BUTTON_WHEEL_UP, Vector2.ZERO)
		await get_tree().physics_frame
		await get_tree().physics_frame
	assert_float(_game.free_camera.global_position.distance_to(pivot)).is_between(0.499, 0.501)
	assert_bool(_game.free_camera.occupied_bounds().intersects(
		VoxelWorldData.block_bounds(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	)).is_false()


func test_orbit_stops_at_obstacle_on_arc_before_free_endpoint() -> void:
	_key(KEY_TAB)
	_game.free_camera.global_position = Vector3(0.25, 2.25, -1.75)
	_game.free_camera.camera.rotation = Vector3(0, PI, 0)
	_game.world_data.place_block(Vector3i(0, 4, 1), VoxelWorldData.Block.STONE)
	_game.world_data.place_block(Vector3i(-3, 4, -3), VoxelWorldData.Block.STONE)
	var pivot: Vector3 = _center_surface()
	_mouse(MOUSE_BUTTON_MIDDLE, Vector2.ZERO)
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.relative = Vector2(-628, 0)
	_game.player.handle_input(motion)
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_float(_game.free_camera.global_position.x).is_less(-0.4)
	assert_float(_game.free_camera.global_position.distance_to(Vector3(-2, 2.25, 0.5))).is_greater(0.3)
	assert_bool(_game.free_camera.occupied_bounds().intersects(
		VoxelWorldData.block_bounds(Vector3i(-3, 4, -3), VoxelWorldData.Block.STONE)
	)).is_false()
	assert_float((-_game.free_camera.camera.global_basis.z).dot(
		(pivot - _game.free_camera.global_position).normalized()
	)).is_greater(0.9999)


func test_wheel_out_sweeps_obstacles_behind_camera_and_keeps_player_limit() -> void:
	_key(KEY_TAB)
	_game.free_camera.global_position = Vector3(0.25, 2.25, -1.75)
	_game.free_camera.camera.rotation = Vector3(0, PI, 0)
	_game.world_data.place_block(Vector3i(0, 4, 1), VoxelWorldData.Block.STONE)
	_game.world_data.place_block(Vector3i(0, 4, -5), VoxelWorldData.Block.STONE)
	_mouse(MOUSE_BUTTON_WHEEL_DOWN, Vector2.ZERO)
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_float(_game.free_camera.global_position.z).is_between(-1.881, -1.87)
	assert_float(_game.free_camera.global_position.distance_to(
		_game.free_camera.anchor_position()
	)).is_less_equal(12.001)


func test_focus_loss_and_escape_discard_pending_wheel_and_orbit_motion() -> void:
	_key(KEY_TAB)
	var before: Vector3 = _game.free_camera.global_position
	var rotation: Vector3 = _game.free_camera.camera.rotation
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.relative = Vector2(150, 50)
	_mouse(MOUSE_BUTTON_WHEEL_UP, Vector2.ZERO)
	_game.player._notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	_game.player._notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_vector(_game.free_camera.global_position).is_equal(before)
	for use_escape: bool in [false, true]:
		_mouse(MOUSE_BUTTON_MIDDLE, Vector2.ZERO)
		_game.player.handle_input(motion)
		if use_escape:
			_key(KEY_ESCAPE)
		else:
			_game.player._notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
			_game.player._notification(NOTIFICATION_APPLICATION_FOCUS_IN)
		await get_tree().physics_frame
		await get_tree().physics_frame
		assert_vector(_game.free_camera.global_position).is_equal(before)
		assert_vector(_game.free_camera.camera.rotation).is_equal(rotation)
		assert_bool(_game.free_camera.is_rotating()).is_false()


func test_orbit_at_player_limit_remains_safe_and_aims_at_locked_surface() -> void:
	_key(KEY_TAB)
	var anchor: Vector3 = _game.free_camera.anchor_position()
	_game.free_camera.global_position = anchor + Vector3.RIGHT * 11.9
	_game.free_camera.camera.look_at(Vector3(0.25, -0.5, 3.25), Vector3.UP)
	var pivot: Vector3 = _center_surface()
	_mouse(MOUSE_BUTTON_MIDDLE, Vector2.ZERO)
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.relative = Vector2(-500, -300)
	_game.player.handle_input(motion)
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_float(_game.free_camera.global_position.distance_to(anchor)).is_less_equal(12.001)
	assert_float((-_game.free_camera.camera.global_basis.z).dot(
		(pivot - _game.free_camera.global_position).normalized()
	)).is_greater(0.9999)


func test_engine_only_wall_cannot_push_boundary_slide_outside_player_limit() -> void:
	_key(KEY_TAB)
	var anchor: Vector3 = _game.free_camera.anchor_position()
	var wall: StaticBody3D = StaticBody3D.new()
	var collision: CollisionShape3D = CollisionShape3D.new()
	var shape: BoxShape3D = BoxShape3D.new()
	shape.size = Vector3(0.5, 1, 2)
	collision.shape = shape
	wall.add_child(collision)
	_game.add_child(wall)
	wall.global_position = anchor + Vector3(11.628, 0, 0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_game.free_camera.global_position = anchor + Vector3.RIGHT * 12
	_game.free_camera.camera.rotation.y = 0
	_game.free_camera.move_camera(Vector3.BACK, 0.1)
	assert_float(_game.free_camera.global_position.distance_to(anchor)).is_less_equal(12.001)
	assert_float(_game.free_camera.global_position.x).is_greater(anchor.x + 11.99)


func test_zoom_near_player_limit_stays_on_center_ray() -> void:
	_key(KEY_TAB)
	var anchor: Vector3 = _game.free_camera.anchor_position()
	_game.free_camera.global_position = anchor + Vector3(7.7, 7.7, 0)
	_game.free_camera.camera.look_at(Vector3(0.25, 0, -2.25), Vector3.UP)
	var before: Vector3 = _game.free_camera.global_position
	var ray: Vector3 = -_game.free_camera.camera.global_basis.z
	var pivot: Vector3 = _center_surface()
	_mouse(MOUSE_BUTTON_WHEEL_DOWN, Vector2.ZERO)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var actual: Vector3 = _game.free_camera.global_position - before
	assert_float(actual.cross(ray).length()).is_less(0.001)
	assert_vector(_center_surface()).is_equal_approx(pivot, Vector3.ONE * 0.002)
	assert_float(_game.free_camera.global_position.distance_to(anchor)).is_less_equal(12.001)


func test_wheel_up_never_moves_away_when_already_closer_than_zoom_minimum() -> void:
	_key(KEY_TAB)
	_game.free_camera.global_position = Vector3(0.25, 0.35, 0.25)
	_game.free_camera.camera.rotation = Vector3(deg_to_rad(-85), 0, 0)
	var before: Vector3 = _game.free_camera.global_position
	assert_float(before.distance_to(_center_surface())).is_less(0.5)
	_mouse(MOUSE_BUTTON_WHEEL_UP, Vector2.ZERO)
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_vector(_game.free_camera.global_position).is_equal(before)
