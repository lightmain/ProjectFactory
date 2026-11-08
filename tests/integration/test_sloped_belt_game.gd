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
	event.pressed = true
	_game.player.handle_input(event)


func test_keys_rotate_preview_place_slope_with_real_45_degree_collision_and_remove() -> void:
	_key(KEY_8)
	assert_int(_game.selected_block).is_equal(9)
	_key(KEY_R)
	_game._process(0.0)
	assert_bool(_game.build_preview.visible).is_true()
	_click(MOUSE_BUTTON_RIGHT)
	assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(10)
	assert_vector(_game.logistics_data.direction_at(Vector3i.ZERO)).is_equal(Vector3i.LEFT)
	assert_bool(_game.world_data.structure_rows().is_empty()).is_true()
	_game.world_view.rebuild_pending()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		Vector3(0.25, 2.0, 0.25), Vector3(0.25, -1.0, 0.25), 1
	)
	var hit: Dictionary = _game.get_world_3d().direct_space_state.intersect_ray(query)
	assert_bool(hit.is_empty()).is_false()
	if not hit.is_empty():
		assert_float(Vector3(hit["position"]).y).is_equal_approx(0.33, 0.001)
		assert_vector(Vector3(hit["normal"])).is_equal_approx(Vector3(1, 1, 0).normalized(), Vector3.ONE * 0.001)
	_game.player.camera.look_at(Vector3(0.25, 0.33, 0.25), Vector3.UP)
	_click(MOUSE_BUTTON_LEFT)
	assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(0)
	_key(KEY_9)
	assert_int(_game.selected_block).is_equal(13)
	assert_vector(_game.build_direction()).is_equal(Vector3i.LEFT)


func test_session_round_trip_and_legacy_versions_reject_slope_payloads() -> void:
	_key(KEY_9)
	_key(KEY_R)
	_click(MOUSE_BUTTON_RIGHT)
	var state: Dictionary = _game.save_state()
	var decoded: SessionSnapshot = SessionSnapshot.decode(state)
	assert_object(decoded).is_not_null()
	if decoded != null:
		assert_int(decoded.selected_block).is_equal(13)
		assert_int(decoded.world.get_block(Vector3i.ZERO)).is_equal(14)
	for version: int in [1, 2]:
		var forged: Dictionary = state.duplicate(true)
		forged["version"] = version
		assert_object(SessionSnapshot.decode(forged)).is_null()
	for tool: int in [10, 11, 12, 14, 15, 16]:
		var forged: Dictionary = state.duplicate(true)
		var player: Dictionary = forged["player"]
		player["tool"] = tool
		assert_object(SessionSnapshot.decode(forged)).is_null()


func test_preview_and_commit_both_reject_upper_lip_overlap_and_inventory_hides_preview() -> void:
	_key(KEY_8)
	_game.world_data.place_block(Vector3i.UP, VoxelWorldData.Block.STONE)
	_game._process(0.0)
	assert_bool(_game._preview_error.is_empty()).is_false()
	_click(MOUSE_BUTTON_RIGHT)
	assert_int(_game.world_data.get_block(Vector3i.ZERO)).is_equal(0)
	_key(KEY_I)
	assert_bool(_game.build_preview.visible).is_false()


func test_preview_geometry_arrow_and_ports_match_all_eight_physical_slopes() -> void:
	for block: int in range(9, 17):
		var cell: Vector3i = Vector3i((block - 9) * 2, 0, 0)
		assert_bool(_game.world_data.place_block(cell, block)).is_true()
		var direction: Vector3i = VoxelWorldData.slope_direction(block)
		_game.build_preview.show_cells([cell], [direction], block, _game.world_data, false)
		# Dummy headless RenderingServer does not retain MultiMesh transforms.
		# Validate the same geometry sent to the batch; live capture checks upload.
		var body: Transform3D = BuildPreview.cell_body_transform(cell, block)
		var top_start: Vector3 = body * Vector3(-Vector3(direction).x * 0.5, 0.5, -Vector3(direction).z * 0.5)
		var top_end: Vector3 = body * Vector3(Vector3(direction).x * 0.5, 0.5, Vector3(direction).z * 0.5)
		assert_float(top_end.y - top_start.y).is_equal_approx(VoxelWorldData.slope_rise(block) * 0.5, 0.01)
		assert_vector((LogisticsView.arrow_facing(direction, block) * Vector3.FORWARD).normalized()).is_equal_approx(
			(Vector3(direction) + Vector3.UP * VoxelWorldData.slope_rise(block)).normalized(), Vector3.ONE * 0.00001
		)
	_game.logistics_view.render_distance = 100.0
	_game.logistics_view.refresh_from_data()
	for block: int in range(9, 17):
		var root: Node3D = _game.logistics_view.get_node("Machine_%d_0_0" % ((block - 9) * 2)) as Node3D
		assert_bool(root.has_node("InputLeft")).is_false()
		assert_bool(root.has_node("InputRight")).is_false()
		var output: Node3D = root.get_node("Output") as Node3D
		var input: Node3D = root.get_node("Input") as Node3D
		assert_float(output.position.y - input.position.y).is_equal_approx(VoxelWorldData.slope_rise(block) * 0.5, 0.00001)


func test_slope_ore_crosses_render_chunk_boundary_without_jump_or_identity_change() -> void:
	_game.set_physics_process(false)
	_game.logistics_view.set_process(false)
	_game.world_data.place_block(Vector3i(6, 0, 0), 5)
	_game.logistics_data.set_direction(Vector3i(6, 0, 0), Vector3i.RIGHT)
	_game.world_data.place_block(Vector3i(7, 0, 0), 12)
	_game.world_data.place_block(Vector3i(8, 1, 0), 6)
	_game.logistics_data.set_direction(Vector3i(8, 1, 0), Vector3i.RIGHT)
	_game.logistics_data.advance(1.25)
	_game.logistics_view.refresh_from_data()
	var id: int = _game.logistics_data.belt_ores(Vector3i(7, 0, 0))[0].id
	var pool: ItemRenderPool = _game.logistics_view.item_render_pool
	assert_float(pool.item_transform(id).origin.y).is_equal_approx(0.37, 0.00001)
	_game.logistics_data.advance(0.249999)
	_game.logistics_view.refresh_from_data()
	var before: Vector3 = pool.item_transform(id).origin
	var batch: ItemRenderBatch = pool.item_batch(id)
	_game.logistics_data.advance(0.000001)
	_game.logistics_view.refresh_from_data()
	assert_vector(pool.item_transform(id).origin).is_equal_approx(before, Vector3.ONE * 0.00001)
	assert_int(_game.logistics_data.belt_ores(Vector3i(8, 1, 0))[0].id).is_equal(id)
	assert_object(pool.item_batch(id)).is_not_same(batch)
	assert_int(batch.multimesh.visible_instance_count).is_equal(0)
	assert_int(pool.stats()["visible_items"]).is_equal(1)


func test_player_falls_onto_real_slope_and_cannot_pass_through_plate() -> void:
	_game.set_physics_process(false)
	assert_bool(_game.world_data.place_block(Vector3i.ZERO, 12)).is_true()
	_game.world_view.rebuild_pending()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_game.player.position = Vector3(0.25, 2.0, 0.25)
	_game.player.velocity = Vector3.ZERO
	_game.player.set_physics_process(true)
	for frame: int in range(60):
		await get_tree().physics_frame
	assert_float(_game.player.position.y).is_greater(0.5)
	assert_float(_game.player.position.y).is_less(0.65)
	assert_bool(_game.player.is_on_floor()).is_true()
	assert_bool(_game.player.test_move(_game.player.global_transform, Vector3.DOWN * 0.1)).is_true()


func test_player_body_passes_under_elevated_slope_but_hits_upper_lip() -> void:
	assert_bool(_game.world_data.place_block(Vector3i(0, 4, 0), 12)).is_true()
	_game.world_view.rebuild_pending()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_game.player.position = Vector3(0.25, 0.01, -0.5)
	assert_bool(_game.player.test_move(_game.player.global_transform, Vector3.BACK)).is_false()
	# Feet are above the base cell's ceiling but still intersect the high lip.
	_game.player.position = Vector3(0.25, 2.53, -0.5)
	assert_bool(_game.player.test_move(_game.player.global_transform, Vector3.BACK)).is_true()


func test_free_camera_engine_sweep_matches_slope_air_and_high_lip() -> void:
	assert_bool(_game.world_data.place_block(Vector3i(0, 4, 0), 12)).is_true()
	_game.world_view.rebuild_pending()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_game.free_camera.set_physics_process(false)
	_game.free_camera.active = true
	_game.free_camera.camera.rotation = Vector3.ZERO
	_game.free_camera.position = Vector3(0.4, 2.1, -0.4)
	assert_bool(_game.free_camera.test_move(
		_game.free_camera.global_transform, Vector3.BACK * 0.8
	)).is_false()
	_game.free_camera.move_camera(Vector3.BACK, 0.16)
	assert_float(_game.free_camera.position.z).is_equal_approx(0.4, 0.001)
	_game.free_camera.position = Vector3(0.48, 2.55, -0.4)
	assert_bool(_game.free_camera.test_move(
		_game.free_camera.global_transform, Vector3.BACK * 0.8
	)).is_true()
	_game.free_camera.move_camera(Vector3.BACK, 0.16)
	assert_float(_game.free_camera.position.z).is_less(0.0)
	assert_float(_game.free_camera.position.z).is_greater(-0.2)


func test_version_two_keeps_multiblock_and_pending_flat_belt_rotation() -> void:
	assert_bool(_game.world_data.place_structure(Vector3i(5, 0, 5), 1)).is_true()
	_game.set_physics_process(false)
	_game.world_data.place_block(Vector3i.LEFT, VoxelWorldData.Block.MINER)
	_game.logistics_data.set_direction(Vector3i.LEFT, Vector3i.RIGHT)
	_game.world_data.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	_game.logistics_data.set_direction(Vector3i.ZERO, Vector3i.RIGHT)
	_game.logistics_data.advance(1.25)
	_game.logistics_data.set_direction(Vector3i.ZERO, Vector3i.BACK)
	var state: Dictionary = _game.save_state()
	state["version"] = 2
	var decoded: SessionSnapshot = SessionSnapshot.decode(state)
	assert_object(decoded).is_not_null()
	if decoded != null:
		assert_int(decoded.world.structure_rows().size()).is_equal(1)
		assert_vector(decoded.logistics.direction_at(Vector3i.ZERO)).is_equal(Vector3i.BACK)
		assert_int(decoded.logistics.belt_ores(Vector3i.ZERO).size()).is_equal(1)
		assert_bool(decoded.logistics.save_state() == _game.logistics_data.save_state()).is_true()


func test_r_switches_live_route_order_without_rotating_tool_and_keeps_locks() -> void:
	_key(KEY_5)
	_click(MOUSE_BUTTON_RIGHT)
	var direction: Vector3i = _game.build_direction()
	_game.player.camera.look_at(Vector3(1.75, 0, 1.25), Vector3.UP)
	_game._process(0.0)
	assert_vector(_game.belt_placement.path[1]).is_equal(Vector3i.BACK)
	_key(KEY_R)
	_game._process(0.0)
	assert_vector(_game.belt_placement.path[1]).is_equal(Vector3i.RIGHT)
	assert_vector(_game.build_direction()).is_equal(direction)
	assert_str(_game.hud._build_hint.text).contains("先东西后南北")
	_key(KEY_C)
	var prefix: Array[Vector3i] = _game.belt_placement.locked_path.duplicate()
	_game.player.camera.look_at(Vector3(2.75, 0, 2.25), Vector3.UP)
	_key(KEY_R)
	_game._process(0.0)
	assert_array(_game.belt_placement.path.slice(0, prefix.size())).contains_exactly(prefix)
	_key(KEY_8)
	_key(KEY_R)
	assert_vector(_game.build_direction()).is_equal(Vector3i.LEFT)


func test_route_ghost_uses_mixed_ramps_and_commit_places_those_types() -> void:
	_game.world_data.place_block(Vector3i(2, 0, 0), VoxelWorldData.Block.BELT)
	_key(KEY_5)
	_click(MOUSE_BUTTON_RIGHT)
	_game.player.camera.look_at(Vector3(2.75, 0, 0.25), Vector3.UP)
	_game._process(0.0)
	assert_str(_game._preview_error).is_empty()
	assert_array(_game.belt_placement.blocks).contains_exactly([6, 12, 6, 16, 6, 6])
	var cells: Array[Vector3i] = _game.belt_placement.path.duplicate()
	var blocks: Array[int] = _game.belt_placement.blocks.duplicate()
	var bodies: MultiMeshInstance3D = _game.build_preview.get_node("Bodies") as MultiMeshInstance3D
	assert_int(bodies.multimesh.instance_count).is_equal(cells.size())
	_click(MOUSE_BUTTON_RIGHT)
	for index: int in range(cells.size()):
		assert_int(_game.world_data.get_block(cells[index])).is_equal(blocks[index])
	assert_int(_game.world_data.get_block(Vector3i(2, 0, 0))).is_equal(6)


func test_terminal_downhill_c_and_r_keep_the_ghost_and_commit_from_forward_exit() -> void:
	_key(KEY_5)
	_game.belt_placement.begin(
		VoxelHit.new(Vector3i(0, 3, 0), Vector3i.UP, 1.0), Vector3i.RIGHT
	)
	_game.player.camera.look_at(Vector3(1.75, 0, 0.25), Vector3.UP)
	_game._update_preview(_game.current_hit(), true)
	assert_str(_game._preview_error).is_empty()
	if not _game._preview_error.is_empty():
		return
	assert_array(_game.belt_placement.blocks).contains_exactly([16, 16, 16, 16])
	_key(KEY_C)
	var prefix: Array[Vector3i] = _game.belt_placement.locked_path.duplicate()
	_game._process(0.0)
	assert_array(_game.belt_placement.path).contains_exactly(prefix)
	_game.player.camera.look_at(Vector3(2.75, 0, 1.25), Vector3.UP)
	_key(KEY_R)
	_game._process(0.0)
	assert_str(_game._preview_error).is_empty()
	assert_array(_game.belt_placement.path.slice(0, prefix.size())).contains_exactly(prefix)
	assert_vector(_game.belt_placement.path[prefix.size()]).is_equal(Vector3i(4, 0, 0))
	assert_int(_game.belt_placement.blocks[prefix.size() - 1]).is_equal(16)
	assert_vector(_game.belt_placement.directions[prefix.size() - 1]).is_equal(Vector3i.RIGHT)
	var cells: Array[Vector3i] = _game.belt_placement.path.duplicate()
	var kinds: Array[int] = _game.belt_placement.blocks.duplicate()
	var bodies: MultiMeshInstance3D = _game.build_preview.get_node("Bodies") as MultiMeshInstance3D
	assert_int(bodies.multimesh.instance_count).is_equal(cells.size())
	_click(MOUSE_BUTTON_RIGHT)
	assert_bool(_game.belt_placement.active).is_false()
	for index: int in range(cells.size()):
		assert_int(_game.world_data.get_block(cells[index])).is_equal(kinds[index])


func test_camera_rejects_slope_plate_and_high_lip_but_allows_air_under_ramp() -> void:
	_game.free_camera.active = true
	_game.free_camera.set_physics_process(false)
	_game.free_camera.global_position = Vector3(0.4, 2.1, 0.25)
	assert_bool(_game._belt_overlaps_camera([Vector3i(0, 4, 0)], [12])).is_false()
	_game.free_camera.global_position = Vector3(0.4, 2.45, 0.25)
	assert_bool(_game._belt_overlaps_camera([Vector3i(0, 4, 0)], [12])).is_true()
	_game.free_camera.global_position = Vector3(0.48, 2.57, 0.25)
	assert_bool(_game._belt_overlaps_camera([Vector3i(0, 4, 0)], [12])).is_true()


func test_player_lift_uses_slope_surface_within_body_footprint() -> void:
	_game.belt_placement.path.assign([Vector3i.ZERO])
	_game.belt_placement.blocks.assign([12])
	_game.player.global_position = Vector3(0.25, 0.1, 0.25)
	assert_float(_game._overlapping_belt_surface()).is_greater(0.4)
	_game.belt_placement.path.assign([Vector3i(0, 5, 0)])
	assert_float(_game._overlapping_belt_surface()).is_equal_approx(0.1, 0.001)
