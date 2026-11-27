extends GdUnitTestSuite
## Regressions for ordinary editing and the reused player interface.

var _game: Node3D
var _player: FactoryPlayer


func before(_do_skip: bool = not ClassDB.class_exists(&"FactoryBackend"),
		_skip_reason: String = "FactoryBackend is optional; install it to validate the playground.") -> void:
	pass


func before_test() -> void:
	var scene: PackedScene = load("res://scenes/factory_playground.tscn") as PackedScene
	_game = auto_free(scene.instantiate()) as Node3D
	_game.set("save_root", "user://test_playground_" + SaveGameStore.new_id())
	add_child(_game)
	_game.set_process(false)
	_game.set_physics_process(false)
	_player = _game.get("player") as FactoryPlayer
	_player.set_physics_process(false)
	_player.set_controls_captured(true)
	for frame: int in range(600):
		_game.call("poll_persistence")
		if _game.get("_job_id") == 0:
			break
		await get_tree().process_frame


func after_test() -> void:
	_player.set_controls_captured(false)
	var root: String = _game.get("save_root")
	var directory: DirAccess = DirAccess.open(root)
	if directory != null:
		for file: String in directory.get_files():
			directory.remove(file)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(root))


func test_hud_hotbar_inventory_and_pause_use_the_original_ui() -> void:
	var hud: FactoryHud = _game.get_node_or_null("Interface/Hud") as FactoryHud
	var inventory: InventoryView = _game.get_node_or_null("Interface/InventoryView") as InventoryView
	var menu: SessionMenu = _game.find_child("SessionMenu", true, false) as SessionMenu
	assert_object(hud).is_not_null()
	assert_object(inventory).is_not_null()
	assert_object(menu).is_not_null()
	if hud == null or inventory == null or menu == null:
		return
	var slots: Array = hud.get("_slots")
	assert_int(slots.size()).is_equal(9)
	_player.handle_input(_key(KEY_4))
	assert_int(_game.get("_selected")).is_equal(VoxelWorldData.Block.MINER)
	_player.handle_input(_key(KEY_I))
	assert_bool(inventory.visible).is_true()
	assert_int(inventory.slot_grid.get_child_count()).is_equal(24)
	assert_bool(_player.controls_captured()).is_false()
	_player.handle_input(_key(KEY_ESCAPE))
	assert_bool(inventory.visible).is_false()
	assert_bool(_player.controls_captured()).is_true()
	_player.handle_input(_key(KEY_ESCAPE))
	assert_bool(menu.visible).is_true()
	assert_bool((_button(menu, "保存游戏")).disabled).is_false()
	assert_bool((_button(menu, "载入游戏")).disabled).is_false()
	menu.transport_selected.emit(false)
	assert_bool(menu.confirmation_visible()).is_true()
	(menu.get("_dialog") as ConfirmationDialog).confirmed.emit()
	var switched: Dictionary = _game.call("snapshot")
	assert_str(switched.ruleset).is_equal("legacy_discrete_v1")
	var resume: Button = _button(menu, "继续  [Esc]")
	assert_object(resume).is_not_null()
	if resume == null:
		return
	resume.pressed.emit()
	assert_bool(menu.visible).is_false()
	assert_bool(_player.controls_captured()).is_true()
	assert_object(hud).is_not_null()


func test_placing_and_removing_one_block_preserves_unaffected_display_and_collision_nodes() -> void:
	var world: Node3D = _game.get("_world_view") as Node3D
	var before_count: int = world.get_child_count()
	var all_ids: Array[int] = []
	for child: Node in world.get_children().slice(0, 3):
		all_ids.append(child.get_instance_id())
		for part: Node in child.get_children():
			all_ids.append(part.get_instance_id())
			for shape: Node in part.get_children():
				all_ids.append(shape.get_instance_id())
	var result: bool = _game.call("_command", "place_block", [Vector3i(2, 0, 0), 1, 0])
	assert_bool(result).is_true()
	_game.call("_refresh")
	await get_tree().process_frame
	assert_int(world.get_child_count()).is_equal(before_count + 1)
	for identity: int in all_ids:
		assert_bool(is_instance_id_valid(identity)).is_true()
	result = _game.call("_command", "remove_block", [Vector3i(2, 0, 0)])
	assert_bool(result).is_true()
	_game.call("_refresh")
	await get_tree().process_frame
	assert_int(world.get_child_count()).is_equal(before_count)
	for identity: int in all_ids:
		assert_bool(is_instance_id_valid(identity)).is_true()


func test_inventory_and_pause_block_build_input_without_losing_ui() -> void:
	var inventory: InventoryView = _game.get_node_or_null("Interface/InventoryView") as InventoryView
	assert_object(inventory).is_not_null()
	if inventory == null:
		return
	_player.handle_input(_key(KEY_I))
	var before: Dictionary = _game.call("snapshot")
	var click: InputEventMouseButton = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	_player.handle_input(click)
	_player.handle_input(_key(KEY_R))
	var after: Dictionary = _game.call("snapshot")
	assert_int(after.revision).is_equal(before.revision)
	assert_int(_game.get("_facing")).is_equal(0)
	_game.call("advance", 1.0)
	after = _game.call("snapshot")
	assert_int(after.tick).is_greater(before.tick)
	inventory.close_button.pressed.emit()
	_game.call("set_paused", true)
	before = _game.call("snapshot")
	_game.call("advance", 1.0)
	after = _game.call("snapshot")
	assert_int(after.tick).is_equal(before.tick)
	assert_bool(inventory.visible).is_false()
	assert_bool(_player.controls_enabled()).is_false()


func test_split_arrows_show_all_ports_and_collapse_after_branch_removal() -> void:
	assert_bool(_game.call("_command", "begin_belt_route", [Vector3i(0, 0, 2), 3])).is_true()
	assert_bool(_game.call("_command", "preview_belt_route", [Vector3i(2, 0, 2), 3])).is_true()
	assert_bool(_game.call("_command", "commit_belt_route", [])).is_true()
	_game.call("_refresh")
	var nodes: Dictionary = _game.get("_cell_nodes")
	var junction: Node3D = nodes[Vector3i(0, 0, 2)]
	var ports: Node3D = junction.get_node_or_null("Ports") as Node3D
	assert_object(ports).is_not_null()
	if ports == null:
		return
	assert_int(ports.get_child_count()).is_equal(3)
	assert_bool(_game.call("_command", "remove_block", [Vector3i(1, 0, 2)])).is_true()
	_game.call("_refresh")
	await get_tree().process_frame
	assert_int(ports.get_child_count()).is_equal(2)


func _key(key: Key) -> InputEventKey:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = true
	return event


func test_route_ghost_order_lock_inventory_and_cancel() -> void:
	_player.handle_input(_key(KEY_5))
	var hit: Dictionary = _ground_hit(Vector3i(2, 0, 0))
	_game.call("_place_hit", hit)
	var route: Dictionary = _game.get("_route")
	assert_bool(route.get("active", false)).is_true()
	var ghost: BuildPreview = _game.get("_route_preview") as BuildPreview
	assert_object(ghost).is_not_null()
	if ghost == null:
		return
	_game.call("_update_route", _ground_hit(Vector3i(4, 0, 2)), true)
	route = _game.get("_route")
	assert_int(route.cells.size()).is_equal(5)
	assert_bool(ghost.visible).is_true()
	_player.handle_input(_key(KEY_R))
	assert_int(_game.get("_facing")).is_equal(0)
	_game.call("_update_route", _ground_hit(Vector3i(4, 0, 2)), true)
	route = _game.get("_route")
	assert_vector(Vector3i(route.cells[1])).is_equal(Vector3i(3, 0, 0))
	# Lock consumes the latest supplied hit, just as C consumes the current ray.
	_game.call("_lock_route_hit", _ground_hit(Vector3i(4, 0, 2)))
	route = _game.get("_route")
	assert_int(route.locked_points.size()).is_equal(1)
	_player.handle_input(_key(KEY_I))
	assert_bool(ghost.visible).is_false()
	route = _game.get("_route")
	assert_bool(route.active).is_true()
	_player.handle_input(_key(KEY_ESCAPE))
	_game.call("_update_route", _ground_hit(Vector3i(4, 0, 4)), true)
	assert_bool(ghost.visible).is_true()
	_game.call("_place_hit", _ground_hit(Vector3i(4, 0, 4)))
	route = _game.get("_route")
	assert_bool(route.get("active", false)).is_false()
	assert_bool(ghost.visible).is_false()
	_game.call("_place_hit", _ground_hit(Vector3i(-2, 0, 0)))
	_game.call("set_paused", true)
	route = _game.get("_route")
	assert_bool(route.get("active", false)).is_false()


func test_route_commit_lifts_player_and_keeps_failed_draft() -> void:
	_player.handle_input(_key(KEY_5))
	_player.velocity = Vector3.DOWN
	var initial_y: float = _player.position.y
	_game.call("_place_hit", _ground_hit(Vector3i(-5, 0, -5)))
	_game.call("_place_hit", _ground_hit(Vector3i(-3, 0, -5)))
	assert_float(_player.position.y).is_equal(initial_y)
	assert_vector(_player.velocity).is_equal(Vector3.DOWN)
	_player.position = Vector3(1.25, 0.01, 0.25)
	_game.call("_place_hit", _ground_hit(Vector3i(2, 0, 0)))
	_game.call("_place_hit", _ground_hit(Vector3i(4, 0, 0)))
	assert_float(_player.position.y).is_greater_equal(VoxelWorldData.BELT_HEIGHT)
	# Too little length for a one metre climb leaves the factory unchanged.
	_game.call("_place_hit", _ground_hit(Vector3i(-2, 0, 0)))
	var before: Dictionary = _game.call("snapshot")
	_game.call("_place_hit", _ground_hit(Vector3i(-1, 2, 0)))
	var after: Dictionary = _game.call("snapshot")
	assert_int(after.revision).is_equal(before.revision)
	var route: Dictionary = _game.get("_route")
	assert_bool(route.active).is_true()
	assert_bool(route.ok).is_false()
	var click: InputEventMouseButton = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	_player.handle_input(click)
	route = _game.get("_route")
	assert_bool(route.get("active", false)).is_false()


func _ground_hit(at: Vector3i) -> Dictionary:
	return {"hit": true, "cell": at + Vector3i.DOWN, "normal": Vector3i.UP}


func test_route_rejects_player_ceiling_and_free_camera_overlap() -> void:
	_player.handle_input(_key(KEY_5))
	_player.position = Vector3(1.25, 0.01, 1.25)
	var initial_y: float = _player.position.y
	assert_bool(_game.call("_command", "place_block", [Vector3i(2, 4, 2), 1, 0])).is_true()
	_game.call("_refresh")
	_game.call("_place_hit", _ground_hit(Vector3i(2, 1, 2)))
	var before: Dictionary = _game.call("snapshot")
	_game.call("_place_hit", _ground_hit(Vector3i(4, 1, 2)))
	var after: Dictionary = _game.call("snapshot")
	assert_int(after.revision).is_equal(before.revision)
	var route: Dictionary = _game.get("_route")
	assert_bool(route.active).is_true()
	assert_float(_player.position.y).is_equal(initial_y)
	_game.call("_toggle_view")
	var camera: Camera3D = _game.get("_free_camera") as Camera3D
	camera.position = Vector3(-1.75, 0.05, -1.75)
	_game.call("_place_hit", _ground_hit(Vector3i(-4, 0, -4)))
	before = _game.call("snapshot")
	_game.call("_place_hit", _ground_hit(Vector3i(-2, 0, -4)))
	after = _game.call("snapshot")
	assert_int(after.revision).is_equal(before.revision)
	route = _game.get("_route")
	assert_bool(route.active).is_true()


func _button(node: Node, text: String) -> Button:
	var button: Button = node as Button
	if button != null and button.text == text and button.is_visible_in_tree():
		return button
	for child: Node in node.get_children():
		var result: Button = _button(child, text)
		if result != null:
			return result
	return null
