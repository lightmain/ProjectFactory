extends GdUnitTestSuite
## Default playable scene must use the worker, guarded collision and packed display.

var _game: Node3D
var _root: String


func before(_do_skip: bool = not ClassDB.class_exists(&"FactoryBackend"),
		_skip_reason: String = "Install FactoryBackend to validate the background playground.") -> void:
	pass


func before_test() -> void:
	_root = "user://runtime_playground_" + SaveGameStore.new_id()
	_game = auto_free(load("res://scenes/factory_playground.tscn").instantiate()) as Node3D
	_game.set("save_root", _root)
	add_child(_game)
	_game.get("player").set_physics_process(false)
	await _settle()
	await _wait_edit()


func after_test() -> void:
	Input.action_release("move_left")
	Input.action_release("move_right")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var directory: DirAccess = DirAccess.open(_root)
	if directory != null:
		for file: String in directory.get_files():
			directory.remove(file)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_root))


func _settle() -> void:
	for frame: int in range(600):
		if _game.get("ready_for_play"):
			return
		await get_tree().process_frame
	fail("Background playground failed to become ready")


func test_default_scene_runs_dynamic_logistics_and_guarded_edits() -> void:
	assert_bool(_game.get("background_runtime")).is_true()
	var runtime: FactoryRuntimePlayground = _game.get("_runtime") as FactoryRuntimePlayground
	assert_object(runtime).is_not_null()
	for frame: int in range(240):
		await get_tree().physics_frame
	assert_str(str(runtime.state().error)).is_empty()
	assert_int(runtime.state().tick).is_greater(0)
	assert_int(runtime.display_snapshot().machines.size()).is_equal(6)
	var player: FactoryPlayer = _game.get("player") as FactoryPlayer
	player.set_controls_captured(true)
	runtime.place_hit({"found": true, "cell": Vector3i(5, -1, 2), "normal": Vector3i.UP,
		"block": 1}, 7)
	for frame: int in range(120):
		await get_tree().physics_frame
	assert_str(str(runtime.state().error)).is_empty()
	assert_int(runtime.state().revision).is_greater(1)
	runtime.set_paused(true)
	for frame: int in range(60):
		await get_tree().physics_frame
	var tick: int = runtime.state().tick
	for frame: int in range(30):
		await get_tree().physics_frame
	assert_int(runtime.state().tick).is_equal(tick)
	assert_bool(player.controls_enabled()).is_false()


func _action(player: FactoryPlayer, action: StringName) -> void:
	var event: InputEventAction = InputEventAction.new()
	event.action = action
	event.pressed = true
	player.handle_input(event)


func _click(player: FactoryPlayer, button: MouseButton, pressed: bool = true) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	player.handle_input(event)


func _aim(camera: Camera3D, target: Vector3) -> void:
	camera.look_at(target)
	var runtime: FactoryRuntimePlayground = _game.get("_runtime") as FactoryRuntimePlayground
	for frame: int in range(240):
		await get_tree().process_frame
		if runtime.state().operation.is_empty() and not runtime.get("_hit").is_empty() \
				and _game.get("player").controls_enabled() and runtime.get("_fingerprint") == runtime.call("_ray_input") \
				and (runtime.get("_route").is_empty() or runtime.get("_route_valid")):
			return
	fail("Aim did not complete its ray and preview")


func _wait_edit() -> void:
	var runtime: FactoryRuntimePlayground = _game.get("_runtime") as FactoryRuntimePlayground
	for frame: int in range(180):
		await get_tree().physics_frame
		if runtime.state().operation.is_empty() and runtime.get("_build_pose").is_empty() \
				and _game.get("player").controls_enabled():
			return
	fail("Edit did not finish")


func test_real_right_click_builds_and_left_click_removes() -> void:
	var runtime: FactoryRuntimePlayground = _game.get("_runtime") as FactoryRuntimePlayground
	var player: FactoryPlayer = _game.get("player") as FactoryPlayer
	player.set_controls_captured(true)
	_action(player, &"select_chest")
	await _aim(player.camera, Vector3(2.75, 0, 2.75))
	var revision: int = runtime.state().revision
	_click(player, MOUSE_BUTTON_RIGHT)
	await _wait_edit()
	assert_int(runtime.state().revision).is_greater(revision)
	for frame: int in range(45):
		await get_tree().physics_frame
	assert_int(runtime.display_snapshot().machines.size()).is_equal(7)
	await _aim(player.camera, Vector3(2.75, 0.5, 2.75))
	revision = runtime.state().revision
	_click(player, MOUSE_BUTTON_LEFT)
	await _wait_edit()
	assert_int(runtime.state().revision).is_greater(revision)
	for frame: int in range(45):
		await get_tree().physics_frame
	assert_int(runtime.display_snapshot().machines.size()).is_equal(6)


func test_world_boundary_allows_inward_movement_after_outward_approach() -> void:
	var runtime: FactoryRuntimePlayground = _game.get("_runtime") as FactoryRuntimePlayground
	var player: FactoryPlayer = _game.get("player") as FactoryPlayer
	player.respawn(Vector3(-3.5, 0.05, 1))
	player.camera.rotation = Vector3(-0.6, 0, 0)
	player.set_controls_captured(true)
	Input.action_press("move_left")
	for frame: int in range(2):
		await get_tree().physics_frame
	Input.action_release("move_left")
	var start: float = player.position.x
	Input.action_press("move_right")
	for frame: int in range(100):
		await get_tree().physics_frame
	Input.action_release("move_right")
	assert_float(player.position.x).is_greater(start + 0.1)
	assert_str(str(runtime.state().error)).is_empty()


func test_free_camera_wheel_waits_for_physics_and_center_ray() -> void:
	var player: FactoryPlayer = _game.get("player") as FactoryPlayer
	player.set_controls_captured(true)
	_action(player, &"toggle_view")
	var camera: Camera3D = _game.get("_free_camera") as Camera3D
	await _aim(camera, Vector3(2.75, 0, 2.75))
	var start: Transform3D = camera.global_transform
	_click(player, MOUSE_BUTTON_WHEEL_UP)
	assert_that(camera.global_transform).is_equal(start)
	for frame: int in range(120):
		await get_tree().physics_frame
	assert_float(camera.global_position.distance_to(start.origin)).is_greater(0.05)


func test_actual_route_rotation_repeated_locks_cancel_and_submit() -> void:
	var runtime: FactoryRuntimePlayground = _game.get("_runtime") as FactoryRuntimePlayground
	var player: FactoryPlayer = _game.get("player") as FactoryPlayer
	player.set_controls_captured(true)
	_action(player, &"select_belt")
	await _aim(player.camera, Vector3(2.75, 0, 2.75))
	_click(player, MOUSE_BUTTON_RIGHT)
	assert_bool(runtime.get("_route").is_empty()).is_false()
	await _aim(player.camera, Vector3(1.75, 0, 2.75))
	_action(player, &"toggle_inventory")
	assert_bool(runtime.get("_route").is_empty()).is_false()
	assert_bool((_game.get("_route_preview") as BuildPreview).visible).is_false()
	_action(player, &"toggle_inventory")
	await _aim(player.camera, Vector3(1.75, 0, 2.75))
	_action(player, &"rotate_build")
	await _aim(player.camera, Vector3(1.75, 0, 2.75))
	_action(player, &"lock_belt_path")
	assert_int(runtime.get("_route").targets.size()).is_equal(1)
	await _aim(player.camera, Vector3(1.75, 0, 1.75))
	_action(player, &"lock_belt_path")
	assert_int(runtime.get("_route").targets.size()).is_equal(2)
	await _aim(player.camera, Vector3(2.75, 0, 1.75))
	var revision: int = runtime.state().revision
	_click(player, MOUSE_BUTTON_RIGHT)
	await _wait_edit()
	assert_int(runtime.state().revision).is_greater(revision)
	assert_bool(runtime.get("_route").is_empty()).is_true()
	await _aim(player.camera, Vector3(3.75, 0, 2.75))
	_click(player, MOUSE_BUTTON_RIGHT)
	await _aim(player.camera, Vector3(3.75, 0, 1.75))
	_click(player, MOUSE_BUTTON_LEFT)
	assert_bool(runtime.get("_route").is_empty()).is_true()
	assert_bool((_game.get("_route_preview") as BuildPreview).visible).is_false()


func test_cancelled_route_does_not_restore_from_outstanding_query() -> void:
	var runtime: FactoryRuntimePlayground = _game.get("_runtime") as FactoryRuntimePlayground
	var player: FactoryPlayer = _game.get("player") as FactoryPlayer
	player.set_controls_captured(true)
	_action(player, &"select_belt")
	await _aim(player.camera, Vector3(2.75, 0, 2.75))
	_click(player, MOUSE_BUTTON_RIGHT)
	await _aim(player.camera, Vector3(1.75, 0, 2.75))
	player.camera.look_at(Vector3(1.75, 0, 1.75))
	runtime.pump(0)
	assert_bool(runtime.state().operation.is_empty()).is_false()
	runtime.cancel_interaction()
	for frame: int in range(120):
		await get_tree().physics_frame
	assert_bool(runtime.get("_route").is_empty()).is_true()
	assert_bool((_game.get("_route_preview") as BuildPreview).visible).is_false()
	assert_str(str(runtime.state().error)).is_empty()


func test_build_under_player_installs_collision_before_releasing_lift() -> void:
	var runtime: FactoryRuntimePlayground = _game.get("_runtime") as FactoryRuntimePlayground
	var player: FactoryPlayer = _game.get("player") as FactoryPlayer
	player.set_controls_captured(true)
	_action(player, &"select_belt")
	await _aim(player.camera, Vector3(2.65, 0, 3.85))
	_click(player, MOUSE_BUTTON_RIGHT)
	await _aim(player.camera, Vector3(2.65, 0, 3.35))
	var revision: int = runtime.state().revision
	_click(player, MOUSE_BUTTON_RIGHT)
	await _wait_edit()
	assert_int(runtime.state().revision).is_greater(revision)
	assert_float(player.position.y).is_greater_equal(0.08)
	for frame: int in range(60):
		await get_tree().physics_frame
	assert_bool(player.is_on_floor()).is_true()
	assert_float(player.position.y).is_greater_equal(0.08)


func test_free_camera_orbit_queues_motion_and_release_survives_wait() -> void:
	var runtime: FactoryRuntimePlayground = _game.get("_runtime") as FactoryRuntimePlayground
	var player: FactoryPlayer = _game.get("player") as FactoryPlayer
	player.set_controls_captured(true)
	_action(player, &"toggle_view")
	var camera: Camera3D = _game.get("_free_camera") as Camera3D
	await _aim(camera, Vector3(2.75, 0, 2.75))
	_click(player, MOUSE_BUTTON_MIDDLE)
	var start: Transform3D = camera.global_transform
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.relative = Vector2(40, 20)
	player.handle_input(motion)
	assert_that(camera.global_transform).is_equal(start)
	for frame: int in range(90):
		await get_tree().physics_frame
	assert_float(camera.global_position.distance_to(start.origin)).is_greater(0.05)
	assert_float(absf(camera.rotation.x)).is_less_equal(deg_to_rad(85))
	var host: FactoryRuntimeHost = runtime.get("_host") as FactoryRuntimeHost
	await _wait_edit()
	host.finish_physics_frame(int(runtime.get("_frame")) + 1, 0.01)
	host.pump()
	assert_bool(player.controls_enabled()).is_false()
	_click(player, MOUSE_BUTTON_MIDDLE, false)
	assert_bool(runtime.get("_rotating")).is_false()


func test_scene_error_keeps_directory_polling_and_can_close() -> void:
	var runtime: FactoryRuntimePlayground = _game.get("_runtime") as FactoryRuntimePlayground
	var host: FactoryRuntimeHost = runtime.get("_host") as FactoryRuntimeHost
	var delivered: Array[bool] = []
	host.directory_ready.connect(func(_entries: Array[Dictionary]) -> void: delivered.append(true))
	runtime.call("_fail", "invalid_display_page")
	assert_bool(_game.get("ready_for_play")).is_false()
	host.request_directory()
	for frame: int in range(120):
		await get_tree().physics_frame
		if not delivered.is_empty():
			break
	assert_int(delivered.size()).is_equal(1)
	runtime.close()
	assert_bool(runtime.get("_closed")).is_true()


func test_camera_entry_sweeps_from_player_eye_below_ceiling() -> void:
	var runtime: FactoryRuntimePlayground = _game.get("_runtime") as FactoryRuntimePlayground
	assert_bool(runtime.call("_submit", {"kind": "build",
		"cells": [Vector3i(5, 4, 7), Vector3i(6, 4, 7), Vector3i(5, 4, 8), Vector3i(6, 4, 8)],
		"blocks": PackedInt32Array([3, 3, 3, 3]), "directions": PackedInt32Array([0, 0, 0, 0])})).is_true()
	await _wait_edit()
	var handoff: FactoryRuntimeHandoff = runtime.get("_handoff") as FactoryRuntimeHandoff
	handoff.request_current(runtime.get("_keys"))
	await _wait_edit()
	var player: FactoryPlayer = _game.get("player") as FactoryPlayer
	player.set_controls_captured(true)
	_action(player, &"toggle_view")
	for frame: int in range(90):
		await get_tree().physics_frame
	var camera: Camera3D = _game.get("_free_camera") as Camera3D
	assert_float(camera.position.y).is_less(2.0 - FreeCameraRig.HALF_SIZE + 0.001)
	assert_float(camera.position.distance_to(player.camera.global_position)).is_less(1.0)
	assert_str(str(runtime.state().error)).is_empty()


func test_static_page_failure_reaches_scene_error_menu() -> void:
	var runtime: FactoryRuntimePlayground = _game.get("_runtime") as FactoryRuntimePlayground
	var handoff: FactoryRuntimeHandoff = runtime.get("_handoff") as FactoryRuntimeHandoff
	var stream: FactoryPresentationStream = handoff.get("_stream") as FactoryPresentationStream
	handoff.request_current(runtime.get("_keys"))
	for frame: int in range(180):
		await get_tree().process_frame
		if stream.state().snapshot > 0 and not stream.state().prepared:
			(runtime.get("_static") as FactoryStaticView).abort()
			break
	for frame: int in range(60):
		await get_tree().process_frame
	assert_str(str(runtime.state().error)).is_equal("invalid_page")
	assert_bool(_game.get("ready_for_play")).is_false()
	assert_bool((_game.get("_menu") as SessionMenu).visible).is_true()


func test_restart_preserves_tool_and_facing_in_new_save_host() -> void:
	var player: FactoryPlayer = _game.get("player") as FactoryPlayer
	player.set_controls_captured(true)
	_action(player, &"select_chest")
	_action(player, &"rotate_build")
	_game.call("start_factory", "legacy_discrete_v1")
	await _settle()
	await _wait_edit()
	var runtime: FactoryRuntimePlayground = _game.get("_runtime") as FactoryRuntimePlayground
	var host: FactoryRuntimeHost = runtime.get("_host") as FactoryRuntimeHost
	assert_int(host.get("_tool")).is_equal(7)
	assert_int(host.get("_facing")).is_equal(1)


func test_paused_rule_restart_can_resume_player_and_menu() -> void:
	var runtime: FactoryRuntimePlayground = _game.get("_runtime") as FactoryRuntimePlayground
	runtime.set_paused(true)
	for frame: int in range(15):
		await get_tree().physics_frame
	_game.call("start_factory", "legacy_discrete_v1")
	await _settle()
	for frame: int in range(45):
		await get_tree().physics_frame
	runtime.set_paused(false)
	var player: FactoryPlayer = _game.get("player") as FactoryPlayer
	player.set_controls_captured(true)
	for frame: int in range(30):
		await get_tree().physics_frame
	assert_bool(player.controls_enabled()).is_true()
	assert_bool((_game.get("_menu") as SessionMenu).visible).is_false()


func test_failed_dynamic_page_keeps_previous_complete_picture() -> void:
	var view: FactoryDynamicView = auto_free(FactoryDynamicView.new()) as FactoryDynamicView
	add_child(view)
	var info: Dictionary = {"world_epoch": 1, "view_generation": 1, "snapshot_id": 1,
		"tick": 4, "revision": 1, "total_pages": 1, "total_bytes": 296}
	assert_bool(view.begin_snapshot(info)).is_true()
	var page: Dictionary = info.duplicate()
	page.merge({"page_index": 0, "page_bytes": 296, "cells": PackedInt32Array([0, 0, 0]),
		"blocks": PackedInt32Array([7]), "directions": PackedInt32Array([3]),
		"quantities": PackedInt64Array([5]), "inputs": PackedInt32Array([1]),
		"outputs": PackedInt32Array([8]), "ore_ids": PackedInt64Array(),
		"transforms": PackedFloat32Array()})
	assert_bool(view.stage_page(page)).is_true()
	assert_bool(view.activate(1, 1)).is_true()
	var previous: Dictionary = view.snapshot()
	info.snapshot_id = 2
	assert_bool(view.begin_snapshot(info)).is_true()
	page.snapshot_id = 2
	page.quantities = PackedInt64Array()
	assert_bool(view.stage_page(page)).is_false()
	assert_that(view.snapshot()).is_equal(previous)
	# A complete empty interest retires all members and ores together.
	info.snapshot_id = 3
	info.total_bytes = 256
	assert_bool(view.begin_snapshot(info)).is_true()
	page.snapshot_id = 3
	page.total_bytes = 256
	page.page_bytes = 256
	page.cells = PackedInt32Array()
	page.blocks = PackedInt32Array()
	page.directions = PackedInt32Array()
	page.quantities = PackedInt64Array()
	page.inputs = PackedInt32Array()
	page.outputs = PackedInt32Array()
	assert_bool(view.stage_page(page)).is_true()
	assert_bool(view.activate(1, 3)).is_true()
	assert_int(view.snapshot().machines.size()).is_equal(0)


func test_actual_movement_inventory_and_both_rule_sessions_continue() -> void:
	var runtime: FactoryRuntimePlayground = _game.get("_runtime") as FactoryRuntimePlayground
	var player: FactoryPlayer = _game.get("player") as FactoryPlayer
	player.set_controls_captured(true)
	var start: Vector3 = player.position
	Input.action_press("move_left")
	for frame: int in range(90):
		await get_tree().physics_frame
	Input.action_release("move_left")
	assert_float(player.position.distance_to(start)).is_greater(0.1)
	var inventory: InventoryView = _game.get("_inventory_view") as InventoryView
	var event: InputEventAction = InputEventAction.new()
	event.action = &"toggle_inventory"
	event.pressed = true
	player.handle_input(event)
	assert_bool(inventory.visible).is_true()
	var position: Vector3 = player.position
	for frame: int in range(30):
		await get_tree().physics_frame
	assert_float(player.position.x).is_equal(position.x)
	assert_float(player.position.z).is_equal(position.z)
	player.handle_input(event)
	assert_bool(inventory.visible).is_false()
	_game.call("start_factory", "legacy_discrete_v1")
	for frame: int in range(30):
		await get_tree().physics_frame
	await _settle()
	for frame: int in range(150):
		await get_tree().physics_frame
	assert_str(str(runtime.state().error)).is_empty()
	assert_int(runtime.state().tick).is_greater(0)
	assert_int(runtime.display_snapshot().machines.size()).is_equal(6)
