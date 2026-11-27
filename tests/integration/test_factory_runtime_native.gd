extends GdUnitTestSuite
## Host adapter against the actual extension, without installing M07 resources.

var _backend: RefCounted
var _coordinator: FactoryRuntimeCoordinator
var _host: FactoryRuntimeHost
var _player: FactoryPlayer
var _camera: Camera3D
var _root: String
var _observed: Array[Dictionary] = []
var _handoff: FactoryRuntimeHandoff


static func _has_runtime() -> bool:
	if not ClassDB.class_exists(&"FactoryBackend"):
		return false
	var backend: RefCounted = ClassDB.instantiate(&"FactoryBackend") as RefCounted
	return backend != null and backend.has_method("open_runtime")


func before(_do_skip: bool = not _has_runtime(),
		_skip_reason: String = "Install current FactoryBackend for actual host transport.") -> void:
	pass


func before_test() -> void:
	_root = "user://runtime_host_" + SaveGameStore.new_id()
	var scene: PackedScene = load("res://scenes/player.tscn") as PackedScene
	_player = auto_free(scene.instantiate()) as FactoryPlayer
	add_child(_player)
	_player.set_physics_process(false)
	_camera = auto_free(Camera3D.new()) as Camera3D
	add_child(_camera)
	_backend = ClassDB.instantiate(&"FactoryBackend") as RefCounted
	assert_bool((_backend.call("open_backend", {"api_version": 1}) as Dictionary).ok).is_true()


func after_test() -> void:
	if _handoff != null:
		_handoff.close()
	if _host != null:
		_host.disconnect_inputs()
	if _coordinator != null:
		_coordinator.close()
		for frame: int in range(300):
			_coordinator.pump()
			if _coordinator.state().stopped:
				break
			await get_tree().process_frame
		assert_bool(_coordinator.state().stopped).is_true()
	_backend.call("close_backend")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var directory: DirAccess = DirAccess.open(_root)
	if directory != null:
		for file: String in directory.get_files():
			directory.remove(file)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_root))


func test_both_rules_save_directory_and_switch_through_actual_host() -> void:
	for ruleset: String in ["legacy_discrete_v1", "conveyor_continuous_v1"]:
		var options: Dictionary = {"epoch": 1, "ruleset": ruleset,
			"minimum": Vector3i(-8, -3, -8), "maximum": Vector3i(9, 12, 9),
			"floor_depth": 3, "interval": 0.1, "amount": 1,
			"save_root": ProjectSettings.globalize_path(_root)}
		assert_bool((_backend.call("open_runtime", options) as Dictionary).ok).is_true()
		_coordinator = FactoryRuntimeCoordinator.new(_backend, 1)
		_coordinator.result_ready.connect(_observe)
		_host = FactoryRuntimeHost.new(_coordinator, _player, _camera)
		_host.set_session({"world_id": "07070707070707070707070707070707",
			"world_name": "实际宿主", "autosave_minutes": 5.0, "autosave_retention": 3})
		var saved: Array[Dictionary] = []
		var directories: Array[Array] = []
		var candidates: Array[Dictionary] = []
		var decisions: Array[Dictionary] = []
		var loaded: Array[bool] = []
		_coordinator.result_ready.connect(func(result: Dictionary) -> void:
			if result.outcome == "save_completed":
				saved.append(result.duplicate(true))
		)
		_host.directory_ready.connect(func(entries: Array[Dictionary]) -> void: directories.append(entries))
		_host.candidate_ready.connect(func(candidate: Dictionary) -> void: candidates.append(candidate))
		_host.commit_decided.connect(func(decision: Dictionary) -> void: decisions.append(decision))
		_host.load_finished.connect(func(success: bool) -> void: loaded.append(success))
		# Reopened worlds share the directory; initialise its current sequence.
		_host.request_directory()
		await _wait(func() -> bool: return not directories.is_empty())
		if directories.is_empty():
			return
		directories.clear()
		_host.pump()
		_player.position = Vector3(2, 1, 3)
		_player.velocity = Vector3(0.1, 0.2, 0.3)
		_camera.position = Vector3(7, 8, 9)
		_host.select_tool(13)
		_host.set_free_view(true)
		assert_bool(_host.finish_physics_frame(1, 0.02)).is_true()
		assert_bool(_host.request_save(ruleset).ok).is_true()
		await _wait(func() -> bool: return not saved.is_empty())
		if saved.is_empty():
			return
		assert_int(saved[0].frame_seq).is_equal(1)
		_host.request_directory()
		await _wait(func() -> bool: return not directories.is_empty())
		if directories.is_empty():
			return
		var save_id: String = saved[0].save_id
		var found: bool = false
		for entry: Dictionary in directories[0]:
			if entry.id == save_id:
				found = true
		assert_bool(found).is_true()
		# Allow the independent directory payload ACK to complete before loading.
		_host.pump()
		_host.request_load(save_id)
		await _wait(func() -> bool: return not candidates.is_empty())
		if candidates.is_empty():
			return
		assert_vector(candidates[0].session.player.position).is_equal(Vector3(2, 1, 3))
		assert_vector(candidates[0].session.player.velocity).is_equal(Vector3(0.1, 0.2, 0.3))
		assert_vector(candidates[0].session.player.free_position).is_equal(Vector3(7, 8, 9))
		assert_str(candidates[0].ruleset).is_equal(ruleset)
		assert_bool(_host.presentation_ready()).is_true()
		await _wait(func() -> bool: return not decisions.is_empty())
		if decisions.is_empty():
			return
		_player.position = Vector3(100, 100, 100)
		assert_bool(_host.confirm_installed()).is_false()
		assert_bool(bool(_host.call("apply_candidate_session"))).is_true()
		assert_vector(_player.position).is_equal(Vector3(2, 1, 3))
		assert_vector(_player.velocity).is_equal(Vector3(0.1, 0.2, 0.3))
		assert_vector(_camera.position).is_equal(Vector3(7, 8, 9))
		assert_bool(_player.controls_enabled()).is_false()
		assert_bool(_host.confirm_installed()).is_true()
		await _wait(func() -> bool: return not loaded.is_empty())
		assert_array(loaded).is_equal([true])
		assert_int(_coordinator.state().epoch).is_equal(2)
		assert_int(_coordinator.state().last_frame_seq).is_equal(1)
		assert_bool(_coordinator.motion_frozen()).is_true()
		_host.request_pause(false)
		await _wait(func() -> bool: return _host.can_step_physics())
		assert_bool(_host.finish_physics_frame(2, 0.02)).is_true()
		await _wait(func() -> bool: return not _coordinator.state().operation_pending)
		_host.disconnect_inputs()
		_coordinator.close()
		for frame: int in range(300):
			_coordinator.pump()
			if _coordinator.state().stopped:
				break
			await get_tree().process_frame
		assert_bool(_coordinator.state().stopped).is_true()


func _wait(predicate: Callable) -> void:
	for frame: int in range(600):
		_host.pump()
		if predicate.call():
			return
		await get_tree().process_frame
	print("HOST_WAIT_FAILED state=", _coordinator.state(), " host_error=", _host.get("_error"),
		" observed=", _observed)
	assert_bool(bool(predicate.call())).is_true()


func _observe(result: Dictionary) -> void:
	_observed.append(result.duplicate(true))


func test_actual_exit_save_disk_failure_preserves_session_and_allows_retry() -> void:
	var options: Dictionary = {"epoch": 1, "ruleset": "legacy_discrete_v1",
		"minimum": Vector3i(-8, -3, -8), "maximum": Vector3i(9, 12, 9),
		"floor_depth": 3, "interval": 0.1, "amount": 1,
		"save_root": ProjectSettings.globalize_path(_root)}
	assert_bool((_backend.call("open_runtime", options) as Dictionary).ok).is_true()
	# A regular file at the not-yet-created save root forces actual I/O failure.
	var obstacle: FileAccess = FileAccess.open(_root, FileAccess.WRITE)
	assert_object(obstacle).is_not_null()
	if obstacle == null:
		return
	obstacle.store_string("save directory obstacle")
	obstacle.close()
	_coordinator = FactoryRuntimeCoordinator.new(_backend, 1)
	_host = FactoryRuntimeHost.new(_coordinator, _player, _camera)
	_host.set_session({"world_id": "07070707070707070707070707070707",
		"world_name": "磁盘失败会话", "autosave_minutes": 0.0, "autosave_retention": 3})
	var saved: Array[bool] = []
	var exits: Array[bool] = []
	_host.save_finished.connect(func(_kind: String, success: bool, _message: String) -> void:
		saved.append(success)
	)
	_host.exit_ready.connect(func() -> void: exits.append(true))
	_player.position = Vector3(2, 1, 3)
	assert_bool(_host.request_save("退出存档", true, "exit").ok).is_true()
	await _wait(func() -> bool: return not saved.is_empty())
	assert_array(saved).is_equal([false])
	assert_array(exits).is_empty()
	assert_vector(_player.position).is_equal(Vector3(2, 1, 3))
	assert_int(_coordinator.state().epoch).is_equal(1)
	assert_str(_coordinator.state().error).is_empty()
	assert_str(_host.get("_error")).is_empty()
	assert_int(DirAccess.remove_absolute(ProjectSettings.globalize_path(_root))).is_equal(OK)
	assert_bool(_host.request_save("退出存档", true, "exit").ok).is_true()
	await _wait(func() -> bool: return saved.size() == 2)
	assert_array(saved).is_equal([false, true])
	assert_array(exits).is_equal([true])


func test_actual_cancel_prepared_load_keeps_old_player_and_releases_candidate() -> void:
	var options: Dictionary = {"epoch": 1, "ruleset": "legacy_discrete_v1",
		"minimum": Vector3i(-8, -3, -8), "maximum": Vector3i(9, 12, 9),
		"floor_depth": 3, "interval": 0.1, "amount": 1,
		"save_root": ProjectSettings.globalize_path(_root)}
	assert_bool((_backend.call("open_runtime", options) as Dictionary).ok).is_true()
	_coordinator = FactoryRuntimeCoordinator.new(_backend, 1)
	_coordinator.result_ready.connect(_observe)
	_host = FactoryRuntimeHost.new(_coordinator, _player, _camera)
	_host.set_session({"world_id": "07070707070707070707070707070707",
		"world_name": "实际取消", "autosave_minutes": 0.0, "autosave_retention": 3})
	_observed.clear()
	assert_bool(_host.request_save("取消来源").ok).is_true()
	await _wait(func() -> bool: return _has_outcome("save_completed"))
	var saved: Dictionary = _outcome("save_completed")
	if saved.is_empty():
		return
	await _wait(func() -> bool: return _host.can_step_physics())
	_player.position = Vector3(3, 2, 1)
	var candidates: Array[Dictionary] = []
	var loaded: Array[bool] = []
	_host.candidate_ready.connect(func(candidate: Dictionary) -> void: candidates.append(candidate))
	_host.load_finished.connect(func(success: bool) -> void: loaded.append(success))
	_host.request_load(saved.save_id)
	await _wait(func() -> bool: return not candidates.is_empty())
	assert_bool(_host.cancel_load()).is_true()
	assert_bool(_host.presentation_ready()).is_false()
	await _wait(func() -> bool: return not loaded.is_empty())
	assert_array(loaded).is_equal([false])
	await _wait(func() -> bool: return _host.can_step_physics())
	assert_vector(_player.position).is_equal(Vector3(3, 2, 1))
	assert_int(_coordinator.state().epoch).is_equal(1)
	assert_str(_coordinator.state().error).is_empty()
	assert_str(_host.get("_error")).is_empty()
	assert_array(_coordinator.pending_results()).is_empty()
	assert_bool(_coordinator.state().disk_pending).is_false()
	assert_str(_outcome("load_failed").error).is_equal("cancelled")
	_host.request_load(saved.save_id)
	await _wait(func() -> bool: return candidates.size() == 2)
	assert_bool(_host.cancel_load()).is_true()
	await _wait(func() -> bool: return loaded.size() == 2)
	assert_array(loaded).is_equal([false, false])


func test_actual_static_handoff_preserves_old_root_until_decision_and_refreshes_new_epoch() -> void:
	for ruleset: String in ["legacy_discrete_v1", "conveyor_continuous_v1"]:
		var options: Dictionary = {"epoch": 1, "ruleset": ruleset,
			"minimum": Vector3i(-8, -3, -8), "maximum": Vector3i(9, 12, 9),
			"floor_depth": 3, "interval": 0.1, "amount": 1,
			"save_root": ProjectSettings.globalize_path(_root)}
		assert_bool((_backend.call("open_runtime", options) as Dictionary).ok).is_true()
		_coordinator = FactoryRuntimeCoordinator.new(_backend, 1)
		_observed.clear()
		_coordinator.result_ready.connect(_observe)
		var menu: SessionMenu = auto_free(SessionMenu.new()) as SessionMenu
		add_child(menu)
		_host = FactoryRuntimeHost.new(_coordinator, _player, _camera, menu)
		_host.set_session({"world_id": "07070707070707070707070707070707",
			"world_name": "真实交接", "autosave_minutes": 0.0, "autosave_retention": 3,
			"ruleset": ruleset})
		var view: FactoryStaticView = auto_free(FactoryStaticView.new()) as FactoryStaticView
		add_child(view)
		_handoff = FactoryRuntimeHandoff.new(_backend, _coordinator, _host, view)
		var keys: Array[Vector3i] = [Vector3i(0, -1, 0), Vector3i.ZERO]
		assert_bool(_handoff.request_current(keys)).is_true()
		await _scene_wait(func() -> bool: return not _handoff.state().waiting_current)
		assert_bool(_host.can_step_physics()).is_true()
		_host.request_directory()
		await _scene_wait(func() -> bool: return not bool(_host.get("_directory_requested")))
		var saved_position: Vector3 = Vector3(-3.9, 0.05, -3.9)
		_player.position = saved_position
		_player.velocity = Vector3(0.1, 0.2, 0.3)
		_camera.position = Vector3(100, 20, 100)
		_host.select_tool(13)
		_host.rotate_tool()
		assert_bool(_host.request_save("场景_" + ruleset).ok).is_true()
		assert_bool(_host.finish_physics_frame(1, 0.0)).is_true()
		await _scene_wait(func() -> bool: return _has_outcome("save_completed"))
		var saved: Dictionary = _outcome("save_completed")
		if saved.is_empty():
			return
		_player.position = Vector3(3, 2, 1)
		var old_position: Vector3 = _player.position
		var old_root: int = view.get_child(0).get_instance_id()
		_host.request_load(saved.save_id)
		await _scene_wait(func() -> bool: return _handoff.state().candidate, false)
		await _scene_wait(func() -> bool: return _handoff.state().stream.prepared, false)
		assert_int(view.get_child(0).get_instance_id()).is_equal(old_root)
		assert_vector(_player.position).is_equal(old_position)
		_handoff.physics_frame()
		await _scene_wait(func() -> bool: return _has_outcome("commit_decided"), false)
		assert_int(view.get_child(0).get_instance_id()).is_equal(old_root)
		assert_vector(_player.position).is_equal(old_position)
		_handoff.physics_frame()
		assert_bool(is_instance_id_valid(old_root)).is_false()
		assert_vector(_player.position).is_equal(saved_position)
		assert_vector(_player.velocity).is_equal(Vector3(0.1, 0.2, 0.3))
		assert_vector(_camera.position).is_equal(Vector3(100, 20, 100))
		assert_str((menu.get("_backend_name") as LineEdit).text).is_equal("真实交接")
		assert_bool(_host.can_step_physics()).is_false()
		await _scene_wait(func() -> bool: return _coordinator.state().epoch == 2, false)
		_host.request_pause(false)
		await _scene_wait(func() -> bool: return not _coordinator.motion_frozen(), false)
		assert_bool(_host.can_step_physics()).is_false()
		await _scene_wait(func() -> bool: return not _handoff.state().waiting_current)
		assert_bool(_host.can_step_physics()).is_true()
		assert_bool(view.covers_sweep(saved_position, saved_position,
			Vector3.ONE * 0.1, 2, 0)).is_true()
		assert_str(_handoff.state().error).is_empty()
		_handoff.close()
		_host.disconnect_inputs()
		_coordinator.close()
		for frame: int in range(300):
			_coordinator.pump()
			if _coordinator.state().stopped:
				break
			await get_tree().process_frame
		assert_bool(_coordinator.state().stopped).is_true()
		menu.free()
		view.free()


func _scene_wait(predicate: Callable, install: bool = true) -> void:
	for frame: int in range(600):
		_host.pump()
		_handoff.pump()
		if install:
			_handoff.physics_frame()
		if predicate.call():
			return
		await get_tree().process_frame
	print("SCENE_WAIT_FAILED state=", _coordinator.state(), " handoff=", _handoff.state(),
		" observed=", _observed)
	assert_bool(bool(predicate.call())).is_true()


func _has_outcome(name: String) -> bool:
	return not _outcome(name).is_empty()


func _outcome(name: String) -> Dictionary:
	for result: Dictionary in _observed:
		if result.outcome == name:
			return result
	return {}
