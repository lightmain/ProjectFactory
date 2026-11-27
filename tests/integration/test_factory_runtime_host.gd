extends GdUnitTestSuite

const FakeBackend: Script = preload("res://tests/helpers/fake_runtime_backend.gd")
const CoordinatorTests: Script = preload("res://tests/unit/test_factory_runtime_coordinator.gd")

var _player: FactoryPlayer
var _camera: Camera3D
var _backend: RefCounted
var _coordinator: FactoryRuntimeCoordinator
var _host: FactoryRuntimeHost


func before_test() -> void:
	var scene: PackedScene = load("res://scenes/player.tscn") as PackedScene
	_player = auto_free(scene.instantiate()) as FactoryPlayer
	add_child(_player)
	_player.set_physics_process(false)
	_camera = auto_free(Camera3D.new()) as Camera3D
	add_child(_camera)
	_backend = FakeBackend.new()
	_coordinator = FactoryRuntimeCoordinator.new(_backend, 1)
	_host = FactoryRuntimeHost.new(_coordinator, _player, _camera)
	_host.set_session({"world_id": "07070707070707070707070707070707",
		"world_name": "输入世界", "autosave_minutes": 5.0, "autosave_retention": 3})
	_host.pump()


func after_test() -> void:
	Input.action_release("jump")
	_host.disconnect_inputs()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func test_busy_freezes_motion_and_look_but_pause_input_still_reaches_menu_boundary() -> void:
	_backend.set("submit_busy", true)
	assert_bool(_host.finish_physics_frame(1, 0.02)).is_true()
	_host.pump()
	var position_before: Vector3 = _player.position
	var velocity_before: Vector3 = _player.velocity
	var rotation_before: Vector3 = _player.camera.rotation
	_player.call("_physics_process", 0.02)
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.relative = Vector2(30, 20)
	_player.handle_input(motion)
	assert_vector(_player.position).is_equal(position_before)
	assert_vector(_player.velocity).is_equal(velocity_before)
	assert_vector(_player.camera.rotation).is_equal(rotation_before)
	var pause: InputEventAction = InputEventAction.new()
	pause.action = "toggle_mouse"
	pause.pressed = true
	_player.handle_input(pause)
	assert_bool(_host.paused()).is_true()
	_backend.set("submit_busy", false)
	_pump()
	_backend.call("emit_command", 1, "frame_completed", {"frame_seq": 1})
	_pump()
	var inputs: Array = _backend.get("inputs")
	assert_str(inputs[0].kind).is_equal("frame")
	assert_str(inputs[1].kind).is_equal("pause")
	assert_bool(_player.controls_enabled()).is_false()


func test_manual_save_captures_paused_pose_without_a_frame_pair_and_exit_waits_for_success() -> void:
	var exits: Array[bool] = []
	_host.exit_ready.connect(func() -> void: exits.append(true))
	_player.position = Vector3(1.25, 3, -2.5)
	_player.velocity = Vector3(0.5, -1.25, 0.75)
	_player.spawn_position = Vector3(2.5, 0.05, 3.5)
	_camera.position = Vector3(3, 8, 4)
	_host.select_tool(13)
	_host.rotate_tool()
	assert_bool(_host.request_save("退出存档", true, "exit").ok).is_true()
	_pump()
	_backend.call("emit_command", 1, "paused", {"paused": true})
	_pump()
	var inputs: Array = _backend.get("inputs")
	assert_int(inputs.size()).is_equal(2)
	assert_str(inputs[0].kind).is_equal("pause")
	assert_str(inputs[1].kind).is_equal("save")
	var pose: Dictionary = inputs[1].player
	assert_vector(pose.position).is_equal(_player.position)
	assert_vector(pose.velocity).is_equal(_player.velocity)
	assert_vector(pose.spawn).is_equal(_player.spawn_position)
	assert_vector(pose.free_position).is_equal(_camera.position)
	assert_int(pose.tool).is_equal(13)
	assert_int(pose.frame).is_equal(0)
	assert_bool(inputs[1].has("frame_seq")).is_false()
	assert_array(exits).is_empty()
	_backend.call("emit_command", 2, "save_started", {"job_id": 2})
	_pump()
	assert_array(exits).is_empty()
	_backend.call("emit_command", 2, "save_failed", {"error": "disk", "job_id": 2})
	_pump()
	assert_array(exits).is_empty()
	assert_bool(_host.request_save("退出存档", true, "exit").ok).is_true()
	_pump()
	_backend.call("emit_command", 3, "save_started", {"job_id": 3})
	_pump()
	_backend.call("emit_command", 3, "save_completed",
		{"save_id": "08080808080808080808080808080808", "directory_sequence": 1, "job_id": 3})
	_pump()
	assert_array(exits).is_equal([true])


func test_held_frame_is_not_recaptured_or_overtaken_by_pause() -> void:
	_coordinator = FactoryRuntimeCoordinator.new(_backend, 1)
	_host.disconnect_inputs()
	_host = FactoryRuntimeHost.new(_coordinator, _player, _camera)
	_host.pump()
	_coordinator.enqueue({"kind": "cell", "cell": Vector3i.ZERO})
	_host.pump()
	assert_bool(_host.finish_physics_frame(1, 0.02)).is_false()
	_player.position = Vector3(5, 2, 7)
	_host.request_pause(true)
	_backend.call("emit_command", 1, "cell", {"block": 0})
	_host.pump()
	_host.pump()
	var inputs: Array = _backend.get("inputs")
	assert_str(inputs[1].kind).is_equal("frame")
	assert_int(inputs[1].frame_seq).is_equal(1)
	assert_float(inputs[1].delta).is_equal(0.02)
	assert_bool(inputs[1].has("player")).is_false()
	_backend.call("emit_command", 2, "frame_completed", {"frame_seq": 1})
	_host.pump()
	_host.pump()
	inputs = _backend.get("inputs")
	assert_str(inputs[2].kind).is_equal("pause")


func test_save_capture_and_terminal_in_one_poll_release_save_and_resume() -> void:
	var saved: Array[bool] = []
	_host.save_finished.connect(func(_kind: String, success: bool, _message: String) -> void:
		saved.append(success)
	)
	assert_bool(_host.request_save("同页完成").ok).is_true()
	_pump()
	_backend.call("emit_command", 1, "paused", {"paused": true})
	_pump()
	_backend.call("emit_command", 2, "save_started", {"job_id": 2})
	_backend.call("emit_command", 2, "save_completed", {"job_id": 2, "directory_sequence": 4})
	_host.pump()
	assert_array(saved).is_equal([true])
	assert_array(_coordinator.pending_results()).is_empty()
	assert_bool(_coordinator.state().disk_pending).is_false()
	_pump()
	_backend.call("emit_command", 3, "paused", {"paused": false})
	_pump()
	assert_bool(_host.can_step_physics()).is_true()
	assert_bool(_host.request_save("下次保存").ok).is_true()


func test_single_save_rejects_second_intention_until_the_disk_terminal() -> void:
	assert_bool(_host.request_save("自动", false, "auto").ok).is_true()
	assert_str(_host.request_save("自动2", false, "auto").error).is_equal("auto_pending")
	assert_str(_host.request_save("手动", false, "manual").error).is_equal("busy")
	_pump()
	_backend.call("emit_command", 1, "paused", {"paused": true})
	_pump()
	_backend.call("emit_command", 2, "save_started", {"job_id": 2})
	_pump()
	assert_bool(_host.paused()).is_false()
	assert_str(_host.request_save("手动").error).is_equal("busy")
	_backend.call("emit_command", 3, "paused", {"paused": false})
	_pump()
	assert_bool(_host.can_step_physics()).is_true()
	_backend.call("emit_command", 2, "save_completed", {"directory_sequence": 1})
	_pump()
	assert_bool(_host.request_save("手动").ok).is_true()
	_pump()
	_backend.call("emit_command", 4, "paused", {"paused": true})
	_pump()
	var inputs: Array = _backend.get("inputs")
	assert_str(inputs[1].name).is_equal("自动")
	assert_str(inputs[4].name).is_equal("手动")
	assert_int(inputs[4].sequence).is_equal(1)


func test_frozen_free_camera_does_not_apply_distance_correction() -> void:
	var rig: FreeCameraRig = auto_free(FreeCameraRig.new()) as FreeCameraRig
	add_child(rig)
	rig.set_physics_process(false)
	var world: VoxelWorldData = VoxelWorldData.new()
	rig.configure(_player, world)
	rig.active = true
	rig.position = Vector3(100, 20, 100)
	rig.set_backend_frozen(true)
	rig.call("_physics_process", 0.02)
	assert_vector(rig.position).is_equal(Vector3(100, 20, 100))


func test_continuous_frame_waits_allow_jump_after_releasing_the_key() -> void:
	var floor_body: StaticBody3D = auto_free(StaticBody3D.new()) as StaticBody3D
	var floor_shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(10, 1, 10)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	floor_body.position.y = -0.5
	add_child(floor_body)
	_player.position = Vector3(0, 0.05, 0)
	_player.configure_gravity(9.81)
	_player.set_controls_captured(true)
	for frame: int in range(1, 9):
		await get_tree().physics_frame
		_player.call("_physics_process", 1.0 / 60.0)
		assert_bool(_host.finish_physics_frame(frame, 1.0 / 60.0)).is_true()
		_pump()
		_backend.call("emit_command", frame, "frame_completed", {"frame_seq": frame})
		_pump()
	assert_bool(_player.is_on_floor()).is_true()
	Input.action_press("jump")
	await get_tree().physics_frame
	_player.call("_physics_process", 1.0 / 60.0)
	assert_float(_player.velocity.y).is_greater(1.0)


func test_frame_wait_preserves_middle_drag_but_accepts_release_while_frozen() -> void:
	var rig: FreeCameraRig = _drag_rig()
	var middle: InputEventMouseButton = InputEventMouseButton.new()
	middle.button_index = MOUSE_BUTTON_MIDDLE
	middle.pressed = true
	_player.handle_input(middle)
	assert_bool(rig.is_rotating()).is_true()
	assert_bool(_host.finish_physics_frame(1, 0.02)).is_true()
	_pump()
	assert_bool(rig.is_rotating()).is_true()
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.relative = Vector2(20, 10)
	_player.handle_input(motion)
	assert_vector(rig.get("_orbit_motion")).is_equal(Vector2.ZERO)
	_backend.call("emit_command", 1, "frame_completed", {"frame_seq": 1})
	_pump()
	var before: Vector3 = rig.camera.rotation
	_player.handle_input(motion)
	assert_bool((rig.get("_orbit_motion") as Vector2).is_zero_approx()).is_false()
	rig.call("_physics_process", 0.02)
	assert_bool(rig.camera.rotation.is_equal_approx(before)).is_false()
	assert_bool(_host.finish_physics_frame(2, 0.02)).is_true()
	_pump()
	middle.pressed = false
	_player.handle_input(middle)
	assert_bool(rig.is_rotating()).is_false()
	_backend.call("emit_command", 2, "frame_completed", {"frame_seq": 2})
	_pump()
	assert_bool(rig.is_rotating()).is_false()
	assert_int(Input.mouse_mode).is_equal(Input.MOUSE_MODE_VISIBLE)


func test_closing_during_middle_drag_releases_mouse_capture() -> void:
	var rig: FreeCameraRig = _drag_rig()
	var middle: InputEventMouseButton = InputEventMouseButton.new()
	middle.button_index = MOUSE_BUTTON_MIDDLE
	middle.pressed = true
	_player.handle_input(middle)
	assert_bool(rig.is_rotating()).is_true()
	_coordinator.close()
	_host.pump()
	assert_bool(rig.is_rotating()).is_false()
	assert_int(Input.mouse_mode).is_equal(Input.MOUSE_MODE_VISIBLE)


func test_disconnecting_inputs_during_frame_wait_releases_middle_capture() -> void:
	var rig: FreeCameraRig = _drag_rig()
	var middle: InputEventMouseButton = InputEventMouseButton.new()
	middle.button_index = MOUSE_BUTTON_MIDDLE
	middle.pressed = true
	_player.handle_input(middle)
	assert_bool(_host.finish_physics_frame(1, 0.02)).is_true()
	_pump()
	assert_bool(rig.is_rotating()).is_true()
	_host.disconnect_inputs()
	assert_bool(rig.is_rotating()).is_false()
	assert_int(Input.mouse_mode).is_equal(Input.MOUSE_MODE_VISIBLE)


func _drag_rig() -> FreeCameraRig:
	var rig: FreeCameraRig = auto_free(FreeCameraRig.new()) as FreeCameraRig
	add_child(rig)
	rig.set_physics_process(false)
	var world: VoxelWorldData = VoxelWorldData.new()
	assert_bool(world.generate_flat()).is_true()
	rig.configure(_player, world)
	_host.disconnect_inputs()
	_host = FactoryRuntimeHost.new(_coordinator, _player, rig)
	_host.camera_input_requested.connect(rig.handle_input)
	_host.set_free_view(true)
	return rig


func test_paused_host_rejects_a_new_positive_frame_without_faulting() -> void:
	assert_bool(_host.request_pause(true)).is_true()
	assert_bool(_host.finish_physics_frame(1, 0.02)).is_false()
	assert_str(_host.get("_error")).is_empty()
	_pump()
	var inputs: Array = _backend.get("inputs")
	assert_int(inputs.size()).is_equal(1)
	assert_str(inputs[0].kind).is_equal("pause")


func test_autosave_clock_stops_on_pause_or_backpressure_and_keeps_single_pending() -> void:
	_host.set_session({"world_id": "07070707070707070707070707070707",
		"world_name": "自动世界", "autosave_minutes": 1.0, "autosave_retention": 3})
	_host.call("advance_autosave", 59.0)
	_host.request_pause(true)
	_host.call("advance_autosave", 120.0)
	_host.request_pause(false)
	_pump()
	_backend.call("emit_command", 1, "paused", {"paused": true})
	_pump()
	_backend.call("emit_command", 2, "paused", {"paused": false})
	_pump()
	_host.call("advance_autosave", 1.0)
	assert_str(_host.request_save("另一个自动", false, "auto").get("error", "")).is_equal("auto_pending")
	_host.call("set_save_settings", "重命名", 1.0, 2)
	assert_str(_host.request_save("另一个自动", false, "auto").get("error", "")).is_equal("auto_pending")
	assert_str(_host.request_save("手动优先").error).is_equal("busy")


func test_inventory_escape_and_focus_do_not_restore_capture_through_backend_freeze() -> void:
	var inventory: InventoryView = auto_free(InventoryView.new()) as InventoryView
	add_child(inventory)
	inventory.bind_inventory(InventoryData.new())
	inventory.hide()
	_host.call("bind_inventory", inventory)
	_player.set_controls_captured(true)
	var open: InputEventAction = InputEventAction.new()
	open.action = "toggle_inventory"
	open.pressed = true
	_player.handle_input(open)
	assert_bool(inventory.visible).is_true()
	_backend.set("submit_busy", true)
	_host.finish_physics_frame(1, 0.02)
	_host.pump()
	_player.notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	var escape: InputEventAction = InputEventAction.new()
	escape.action = "toggle_mouse"
	escape.pressed = true
	_player.handle_input(escape)
	assert_bool(inventory.visible).is_false()
	assert_bool(_host.paused()).is_false()
	assert_bool(_player.controls_captured()).is_false()
	assert_bool(_player.controls_enabled()).is_false()


func test_pause_menu_and_exit_overwrite_require_confirmation() -> void:
	var menu: SessionMenu = auto_free(SessionMenu.new()) as SessionMenu
	add_child(menu)
	menu.hide()
	_host.disconnect_inputs()
	_host = FactoryRuntimeHost.new(_coordinator, _player, _camera, menu)
	_host.set_session({"world_id": "07070707070707070707070707070707",
		"world_name": "菜单世界", "autosave_minutes": 5.0, "autosave_retention": 3})
	assert_bool(_host.request_pause(true)).is_true()
	assert_bool(menu.visible).is_true()
	_host.pump()
	menu.return_requested.emit()
	_host.pump()
	_host.pump()
	_backend.call("emit_command", 1, "paused", {"paused": true})
	_host.pump()
	_host.pump()
	_host.pump()
	_backend.call("emit_command", 2, "directory_ready", {"job_id": 2})
	_backend.call("set_directory_entries", [{"id": "08080808080808080808080808080808",
		"world_id": "07070707070707070707070707070707", "name": "退出存档",
		"world_name": "菜单世界", "saved_at": 1, "kind": "manual"}])
	_host.pump()
	assert_bool(menu.confirmation_visible()).is_true()
	assert_array(_host.get("_saves") as Array).is_empty()
	var dialog: ConfirmationDialog = menu.get("_dialog") as ConfirmationDialog
	dialog.confirmed.emit()
	assert_int((_host.get("_saves") as Array).size()).is_equal(1)


func test_saves_use_updated_directory_sequence_and_block_load() -> void:
	assert_bool(_host.request_save("第一个").ok).is_true()
	assert_str(_host.request_save("第二个").error).is_equal("busy")
	_pump()
	_backend.call("emit_command", 1, "paused", {"paused": true})
	_pump()
	_host.request_load("08080808080808080808080808080808")
	assert_bool(_host.get("_load_requested")).is_false()
	var inputs: Array = _backend.get("inputs")
	assert_int(inputs.size()).is_equal(2)
	_backend.call("emit_command", 2, "save_started", {"job_id": 2})
	_pump()
	_backend.call("emit_command", 3, "paused", {"paused": false})
	_pump()
	_backend.call("emit_command", 2, "save_completed",
		{"directory_sequence": 9, "job_id": 2})
	_pump()
	assert_bool(_host.request_save("第二个").ok).is_true()
	_pump()
	_backend.call("emit_command", 4, "paused", {"paused": true})
	_pump()
	inputs = _backend.get("inputs")
	assert_str(inputs[4].name).is_equal("第二个")
	assert_int(inputs[4].sequence).is_equal(9)


func test_backend_busy_time_does_not_count_toward_autosave() -> void:
	_host.set_session({"world_id": "07070707070707070707070707070707",
		"world_name": "计时", "autosave_minutes": 1.0, "autosave_retention": 3})
	_host.advance_autosave(59.0)
	_backend.set("submit_busy", true)
	_host.finish_physics_frame(1, 0.02)
	_host.pump()
	_host.advance_autosave(60.0)
	assert_array(_host.get("_saves") as Array).is_empty()


func test_exit_save_rejects_resume_until_its_failure() -> void:
	_host.request_pause(true)
	_host.pump()
	_host.pump()
	_backend.call("emit_command", 1, "paused", {"paused": true})
	_host.pump()
	_host.request_save("退出存档", true, "exit")
	_pump()
	assert_bool(_host.request_pause(false)).is_false()
	assert_bool(_host.paused()).is_true()
	_backend.call("emit_command", 2, "save_failed", {"error": "disk"})
	_host.pump()
	assert_bool(_host.request_pause(false)).is_true()


func test_full_legal_directory_is_paged_without_fault_or_sequence_regression() -> void:
	var entries: Array[Dictionary] = []
	for index: int in range(1024):
		entries.append({"id": str(index), "name": str(index)})
	_backend.call("set_directory_entries", entries)
	_host.set("_sequence", 9)
	_host.request_directory()
	_host.pump()
	_host.pump()
	_backend.call("emit_command", 1, "directory_ready", {"job_id": 1})
	for index: int in range(66):
		_host.pump()
	assert_str(_host.get("_error")).is_empty()
	assert_int((_host.get("_directory_entries") as Array).size()).is_equal(1024)
	assert_int(_host.get("_sequence")).is_equal(9)


func test_exit_directory_waits_for_prior_named_save() -> void:
	var menu: SessionMenu = auto_free(SessionMenu.new()) as SessionMenu
	add_child(menu)
	_host.disconnect_inputs()
	_host = FactoryRuntimeHost.new(_coordinator, _player, _camera, menu)
	_host.set_session({"world_id": "07070707070707070707070707070707",
		"world_name": "排队", "autosave_minutes": 5.0, "autosave_retention": 3})
	_host.request_save("在途")
	assert_str(_host.request_save("退出存档").error).is_equal("busy")
	_pump()
	menu.return_requested.emit()
	for index: int in range(4):
		_host.pump()
	for input: Dictionary in _backend.get("inputs"):
		assert_str(input.kind).is_not_equal("list_directory")


func test_unbounded_input_is_rejected_before_host_admission() -> void:
	_player.set_controls_captured(true)
	var command: Dictionary = {"kind": "cell", "cell": Vector3i.ZERO, "extra": "x".repeat(10000)}
	assert_bool(_host.queue_edit(command)).is_false()
	assert_array(_host.get("_events") as Array).is_empty()
	assert_bool(_host.can_step_physics()).is_true()
	_host.set_session({"world_name": "x".repeat(10000)})
	assert_str((_host.get("_session") as Dictionary).world_name).is_equal("输入世界")
	assert_str(_host.get("_error")).is_equal("invalid_session")


func test_cancel_load_has_one_job_terminal_and_releases_old_session() -> void:
	var outcomes: Array[bool] = []
	_host.load_finished.connect(func(success: bool) -> void: outcomes.append(success))
	_host.request_load("07070707070707070707070707070707")
	_pump()
	_backend.call("emit_command", 1, "paused", {"paused": true})
	_pump()
	assert_bool(_host.cancel_load()).is_true()
	assert_array(outcomes).is_empty()
	_backend.call("emit_command", 2, "load_failed", {"job_id": 2, "error": "cancelled"})
	_pump()
	_backend.call("emit_command", 3, "paused", {"paused": false})
	_pump()
	assert_array(outcomes).is_equal([false])
	assert_str(_host.get("_error")).is_empty()
	assert_bool(_host.get("_load_requested")).is_false()
	assert_bool(_host.paused()).is_false()


func test_load_byte_admission_is_atomic_with_pause() -> void:
	var padding: Array[String] = []
	for index: int in range(16):
		padding.append("x".repeat(4096))
	var command: Dictionary = {"kind": "cell", "cell": Vector3i.ZERO, "padding": padding}
	var excess: int = var_to_bytes(command).size() - 65500
	padding[-1] = padding[-1].substr(0, 4096 - excess)
	assert_bool(_host.call("_queue_event", command, "")).is_true()
	assert_int(var_to_bytes(command).size()).is_equal(65500)
	_host.request_load("07070707070707070707070707070707")
	assert_bool(_host.get("_load_requested")).is_false()
	assert_bool(_host.paused()).is_false()
	assert_int((_host.get("_events") as Array).size()).is_equal(1)
	assert_bool(_host.request_pause(false)).is_true()


func test_rejected_load_payload_preserves_playable_old_session() -> void:
	_host.request_load("x".repeat(5000))
	assert_bool(_host.get("_load_requested")).is_false()
	assert_bool(_host.paused()).is_false()
	assert_array(_host.get("_events") as Array).is_empty()
	assert_bool(_host.can_step_physics()).is_true()


func _pump(count: int = 3) -> void:
	for index: int in range(count):
		_host.pump()
