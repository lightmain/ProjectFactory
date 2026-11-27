class_name FactoryRuntimeHost
extends RefCounted
## Injected input/menu adapter. Resource installation is supplied by M07/3c.

signal save_finished(kind: String, success: bool, message: String)
signal exit_ready
signal directory_ready(entries: Array[Dictionary])
signal candidate_ready(candidate: Dictionary)
signal commit_decided(decision: Dictionary)
signal load_finished(success: bool)
signal edit_requested(operation: String)
signal camera_input_requested(event: InputEvent)
signal view_changed(free_view: bool)
signal interaction_cancelled
signal error_reported(message: String)
signal session_installed(session: Dictionary)
signal gameplay_finished(result: Dictionary)

const MAX_PENDING_EVENTS: int = 16
const MAX_PENDING_EVENT_BYTES: int = 65536
const MAX_DIRECTORY_ENTRIES: int = 1024

var _coordinator: FactoryRuntimeCoordinator
var _player: FactoryPlayer
var _free_camera: Node3D
var _menu: SessionMenu
var _inventory: InventoryView
var _session: Dictionary = {}
var _tool: int = 6
var _facing: int = 0
var _free_view: bool = false
var _paused: bool = false
var _capture_before_pause: bool = false
var _capture_before_inventory: bool = false
var _focused: bool = true
var _error: String = ""
var _events: Array[Dictionary] = []
var _saves: Array[Dictionary] = []
var _pending_frame: Dictionary = {}
var _operations: Dictionary[int, String] = {}
var _auto_waiting: bool = false
var _autosave_seconds: float = 0.0
var _save_inflight: bool = false
var _save_was_paused: bool = false
var _save_capture_pending: bool = false
var _exit_requested: bool = false
var _exit_directory_pending: bool = false
var _sequence: int = 0
var _directory_job: int = 0
var _directory_offset: int = 0
var _directory_entries: Array[Dictionary] = []
var _directory_needs_ack: bool = false
var _directory_requested: bool = false
var _directory_refresh: bool = false
var _file_mode: String = ""
var _candidate_result: int = 0
var _candidate_job: int = 0
var _candidate: Dictionary = {}
var _decision: Dictionary = {}
var _load_was_paused: bool = false
var _load_requested: bool = false
var _load_cancel_requested: bool = false
var _switch_requested: bool = false
var _session_installed: bool = false
var _pumping: bool = false
var _bindings: Array[Dictionary] = []
var _presentation_frozen: bool = false


func _init(coordinator: FactoryRuntimeCoordinator, player: FactoryPlayer,
		free_camera: Node3D, menu: SessionMenu = null) -> void:
	_coordinator = coordinator
	_player = player
	_free_camera = free_camera
	_menu = menu
	_bind(coordinator, "freeze_changed", _freeze_changed)
	_bind(coordinator, "protocol_error", _report_error)
	_bind(player, "pause_requested", _pause_requested)
	_bind(player, "block_selected", select_tool)
	_bind(player, "build_rotation_requested", rotate_tool)
	_bind(player, "break_requested", _break_requested)
	_bind(player, "place_requested", _place_requested)
	_bind(player, "camera_input_requested", _camera_input)
	_bind(player, "view_mode_requested", _toggle_view)
	_bind(player, "inventory_requested", _toggle_inventory)
	_bind(player, "focus_lost", _focus_lost)
	_bind(player, "focus_restored", _focus_restored)
	if menu != null:
		_bind(menu, "resume_requested", _resume_requested)
		_bind(menu, "save_confirmed", _save_confirmed)
		_bind(menu, "return_requested", _return_requested)
		_bind(menu, "load_confirmed", request_load)
		_bind(menu, "delete_confirmed", request_delete)
		_bind(menu, "save_requested", _open_save_files)
		_bind(menu, "load_requested", _open_load_files)
		_bind(menu, "backend_settings_changed", set_save_settings)
		_bind(menu, "file_panel_closed", _file_panel_closed)
	_sync_controls()


func _bind(owner: Object, name: String, callback: Callable) -> void:
	owner.connect(name, callback)
	_bindings.append({"owner": weakref(owner), "name": name, "callback": callback})


func disconnect_inputs() -> void:
	if _free_camera is FreeCameraRig:
		(_free_camera as FreeCameraRig).set_input_enabled(false)
	for binding: Dictionary in _bindings:
		var reference: WeakRef = binding.owner
		var owner: Object = reference.get_ref()
		var name: String = binding.name
		var callback: Callable = binding.callback
		if is_instance_valid(owner) and owner.is_connected(name, callback):
			owner.disconnect(name, callback)
	_bindings.clear()


func set_session(session: Dictionary) -> void:
	if not _coordinator.accepts_payload(session):
		_report_error("invalid_session")
		return
	_session = session.duplicate(true)
	_autosave_seconds = 0.0


func bind_inventory(inventory: InventoryView) -> void:
	_inventory = inventory
	_bind(inventory, "close_requested", _close_inventory)


func set_save_settings(name: String, minutes: float, retention: int) -> void:
	if _load_requested or _exit_requested:
		return
	var trimmed: String = name.strip_edges()
	if not trimmed.is_empty() and trimmed.length() <= 80:
		_session["world_name"] = trimmed
		if _menu != null:
			_menu.set_world_name(trimmed)
	if is_finite(minutes) and minutes >= 0 and minutes <= 1440 and retention >= 1 and retention <= 100:
		_session["autosave_minutes"] = minutes
		_session["autosave_retention"] = retention
		_autosave_seconds = 0.0


func advance_autosave(delta: float) -> void:
	if not can_step_physics() or _load_requested:
		return
	_accumulate_autosave(delta)


func _accumulate_autosave(delta: float) -> void:
	var interval: float = _number(_session.get("autosave_minutes", 0.0)) * 60.0
	if not is_finite(delta) or delta < 0 or interval <= 0:
		return
	_autosave_seconds = minf(interval, _autosave_seconds + delta)
	if _autosave_seconds >= interval and not _auto_waiting:
		if request_save(_default_save_name() + "_" + SaveGameStore.new_id().substr(0, 8), false, "auto").get("ok", false):
			_autosave_seconds = 0.0


func select_tool(tool: int) -> void:
	_tool = tool


func set_tool_state(tool: int, facing: int) -> void:
	_tool = tool
	_facing = facing


func rotate_tool() -> void:
	_facing = (_facing + 1) % 4


func set_free_view(enabled: bool) -> void:
	_free_view = enabled
	_player.set_free_view(enabled)
	if _free_camera is FreeCameraRig:
		var rig: FreeCameraRig = _free_camera as FreeCameraRig
		if enabled:
			rig.enter()
		else:
			rig.leave()
	elif _free_camera is Camera3D:
		(_free_camera as Camera3D).current = enabled
		_player.camera.current = not enabled
	_sync_controls()
	view_changed.emit(enabled)


func paused() -> bool:
	return _paused


func can_step_physics() -> bool:
	return not _paused and not _exit_requested and _error.is_empty() and _pending_frame.is_empty() \
		and _events.is_empty() and not _coordinator.motion_frozen() and not _presentation_frozen


func set_presentation_frozen(frozen: bool) -> void:
	_presentation_frozen = frozen
	_sync_controls()


func request_pause(value: bool) -> bool:
	if not value and (_exit_requested or not _error.is_empty()):
		return false
	if _load_requested:
		return value
	if not _saves.is_empty() or _save_capture_pending:
		_save_was_paused = value
		return true
	if value == _paused:
		return true
	if not _queue_event({"kind": "pause" if value else "resume"}, ""):
		return false
	_apply_pause(value)
	return true


func _apply_pause(value: bool) -> void:
	if value and not _paused:
		_capture_before_pause = _player.controls_captured()
		if _inventory != null and _inventory.visible:
			_capture_before_pause = _capture_before_inventory
			_close_inventory()
	_paused = value
	_player.set_session_paused(value)
	interaction_cancelled.emit()
	if _menu != null:
		if value:
			_show_pause_menu()
		else:
			_file_mode = ""
			_menu.hide()
	_sync_controls()


func queue_edit(command: Dictionary) -> bool:
	if not can_step_physics() or _load_requested or not _player.controls_enabled():
		return false
	return _queue_event(command, "")


func queue_gameplay(command: Dictionary) -> bool:
	if not _error.is_empty() or _load_requested or _exit_requested or _coordinator.state().closed:
		return false
	return _queue_event(command, "gameplay")


func _queue_event(command: Dictionary, operation: String) -> bool:
	return _queue_events([{"input": command, "operation": operation}])


func _queue_events(events: Array[Dictionary]) -> bool:
	if _events.size() + events.size() > MAX_PENDING_EVENTS or not _error.is_empty():
		return false
	var bytes: int = 0
	for event: Dictionary in events:
		var command: Dictionary = event.input
		if not _coordinator.accepts_payload(command):
			return false
		bytes += var_to_bytes(command).size()
	for event: Dictionary in _events:
		bytes += var_to_bytes(event.input).size()
	if bytes > MAX_PENDING_EVENT_BYTES:
		return false
	for event: Dictionary in events:
		_events.append(event.duplicate(true))
	_sync_controls()
	return true


func request_save(name: String, overwrite: bool = false, kind: String = "manual") -> Dictionary:
	if not _error.is_empty() or kind not in ["manual", "auto", "exit"] or name.is_empty() \
			or name.length() > 160 or _session.is_empty():
		return {"ok": false, "error": "invalid_save"}
	if _load_requested:
		return {"ok": false, "error": "load_in_progress"}
	if kind == "auto" and _auto_waiting:
		return {"ok": false, "error": "auto_pending"}
	if not _saves.is_empty() or _save_inflight:
		return {"ok": false, "error": "busy"}
	_save_was_paused = _paused
	if not request_pause(true):
		return {"ok": false, "error": "busy"}
	_saves.append({"name": name, "overwrite": overwrite, "save_kind": kind})
	if kind == "auto":
		_auto_waiting = true
	if kind == "exit":
		_exit_requested = true
	_sync_controls()
	return {"ok": true}


func finish_physics_frame(frame: int, delta: float) -> bool:
	# The caller has already sampled this frame. Keep it even if admission just
	# became Busy; further physics uses can_step_physics() before sampling.
	if not _pending_frame.is_empty():
		return _flush_frame()
	if not _error.is_empty() or _coordinator.state().handoff or _load_requested \
			or (_paused and delta > 0):
		return false
	var count_autosave: bool = can_step_physics()
	_pending_frame = {"frame": frame, "delta": delta}
	var admitted: bool = _flush_frame()
	# The sampled frame is retained before autosave queues its pause, including Busy.
	if count_autosave:
		_accumulate_autosave(delta)
	return admitted


func _flush_frame() -> bool:
	if _pending_frame.is_empty():
		return true
	var response: Dictionary = _coordinator.queue_frame(_integer(_pending_frame.frame),
		_number(_pending_frame.delta))
	if not response.get("ok", false):
		if response.get("error", "") != "busy":
			_report_error(str(response.get("error", "invalid_frame")))
		_sync_controls()
		return false
	_pending_frame = {}
	_sync_controls()
	return true


func _flush_save() -> void:
	if _saves.is_empty() or _save_inflight or not _events.is_empty() \
			or not _pending_frame.is_empty() or not _boolean(_coordinator.state().pause_confirmed):
		return
	var camera_rotation: Vector3 = _free_camera.rotation
	if _free_camera is FreeCameraRig:
		camera_rotation = (_free_camera as FreeCameraRig).camera.rotation
	var frame: int = _integer(_coordinator.state().last_frame_seq)
	var pose: Dictionary = {"frame": frame, "position": _player.position,
		"velocity": _player.velocity, "spawn": _player.spawn_position,
		"body_rotation": _player.rotation, "rotation": _player.camera.rotation,
		"tool": _tool, "build_rotation": _facing, "free_view": _free_view,
		"free_position": _free_camera.position, "free_rotation": camera_rotation}
	var save: Dictionary = _saves[0].duplicate(true)
	save.merge({"kind": "save", "player": pose,
		"world_id": str(_session.get("world_id", "")),
		"world_name": str(_session.get("world_name", "")),
		"autosave_minutes": _number(_session.get("autosave_minutes", 5.0)),
		"retention": _integer(_session.get("autosave_retention", 3)), "sequence": _sequence})
	var response: Dictionary = _coordinator.enqueue(save)
	if response.get("ok", false):
		_operations[_integer(response.request_id)] = str(save.save_kind)
		_save_inflight = true
		_save_capture_pending = true
		_saves.pop_front()
	elif response.get("error", "") != "busy":
		_report_error(str(response.get("error", "save_failed")))


func _flush_event() -> void:
	if _events.is_empty():
		return
	if _enqueue_event(_events[0]):
		_events.pop_front()


func _enqueue_event(event: Dictionary) -> bool:
	var input: Dictionary = event.input
	var response: Dictionary = _coordinator.enqueue(input)
	if response.get("ok", false):
		var request: int = _integer(response.request_id)
		if not str(event.operation).is_empty():
			_operations[request] = event.operation
			if event.operation == "load":
				_candidate_job = request
		return true
	elif response.get("error", "") != "busy":
		_report_error(str(response.get("error", "invalid_event")))
	return false


func pump() -> void:
	if _pumping:
		return
	_pumping = true
	_coordinator.pump()
	for result: Dictionary in _coordinator.pending_results():
		_handle_result(result)
	_poll_directory()
	_poll_candidate()
	if _error.is_empty():
		# A saved original frame always precedes later menu/input events.
		if _flush_frame():
			_flush_event()
		_flush_save()
		_prepare_exit_directory()
	_sync_controls()
	_pumping = false


func _handle_result(result: Dictionary) -> void:
	var seq: int = _integer(result.request_id)
	var command: int = seq
	var operation: String = _operations.get(command, "")
	var outcome: String = str(result.outcome)
	if operation == "gameplay":
		gameplay_finished.emit(result.duplicate(true))
		_coordinator.take_result(seq)
		_operations.erase(seq)
		return
	if outcome == "load_prepared":
		_candidate_job = _integer(result.job_id)
		_candidate_result = seq
		return
	if outcome == "directory_ready":
		_directory_job = _integer(result.job_id)
		_directory_offset = 0
		_directory_entries.clear()
	elif outcome == "commit_decided":
		_decision = result.duplicate(true)
	elif outcome == "load_completed":
		if not _coordinator.adopt_epoch(seq):
			return
		_candidate = {}
		_decision = {}
		_candidate_job = 0
		_load_requested = false
		_load_cancel_requested = false
		_switch_requested = false
		_session_installed = false
		if _menu != null:
			_show_pause_menu()
		load_finished.emit(true)
	elif _load_requested and _integer(result.get("job_id", 0)) == _candidate_job \
			and outcome == "load_failed":
		_candidate = {}
		_candidate_job = 0
		_candidate_result = 0
		_decision = {}
		_load_requested = false
		_load_cancel_requested = false
		_session_installed = false
		request_pause(_load_was_paused)
		load_finished.emit(false)
	elif operation in ["manual", "auto", "exit"] and outcome == "save_started":
		_save_capture_pending = false
		_coordinator.take_result(seq)
		request_pause(_save_was_paused or _exit_requested)
		return
	elif operation in ["manual", "auto", "exit"] and outcome in ["save_completed", "save_failed"]:
		var success: bool = outcome == "save_completed"
		_save_inflight = false
		if _save_capture_pending:
			_save_capture_pending = false
			request_pause(_save_was_paused or _exit_requested)
		var message: String = "保存完成。" if success else "保存失败：" + str(result.get("error", outcome))
		if operation == "auto":
			_auto_waiting = false
		if operation == "exit" and not success:
			_exit_requested = false
		if success:
			_sequence = _integer(result.directory_sequence)
		save_finished.emit(operation, success, message)
		if _menu != null:
			_menu.set_message(message)
		if operation == "exit" and success:
			exit_ready.emit()
	elif outcome == "delete_completed":
		_sequence = _integer(result.directory_sequence)
		request_directory()
	elif outcome in ["directory_failed", "delete_failed"]:
		if outcome == "directory_failed":
			_directory_requested = false
			if _file_mode == "exit":
				_exit_requested = false
				_file_mode = ""
		if _menu != null:
			_menu.set_message("存档操作失败：" + str(result.get("error", outcome)))
	elif outcome == "faulted":
		_report_error("faulted")
	_coordinator.take_result(seq)
	_operations.erase(command)
	if outcome == "commit_decided":
		commit_decided.emit(_decision.duplicate(true))


func request_directory() -> void:
	if _load_requested:
		return
	if _directory_requested:
		_directory_refresh = true
		return
	_directory_requested = _queue_event({"kind": "list_directory"}, "list")


func _poll_directory() -> void:
	if _directory_job == 0:
		return
	if _directory_needs_ack:
		if _coordinator.acknowledge_directory(_directory_job).get("ok", false):
			_directory_job = 0
			_directory_needs_ack = false
			_directory_requested = false
			if _directory_refresh:
				_directory_refresh = false
				request_directory()
		return
	var page: Dictionary = _coordinator.poll_directory(_directory_job, _directory_offset)
	if not page.get("ok", false):
		if page.get("error", "") != "busy":
			_report_error(str(page.get("error", "directory_failed")))
		return
	var entries: Array = page.entries
	if _directory_entries.size() + entries.size() > MAX_DIRECTORY_ENTRIES:
		_report_error("directory_capacity")
		return
	for value: Variant in entries:
		if value is Dictionary:
			var entry: Dictionary = value
			_directory_entries.append(entry.duplicate(true))
	_directory_offset = _integer(page.next_offset)
	_sequence = maxi(_sequence, _integer(page.directory_sequence))
	if _directory_offset >= _integer(page.total_entries):
		_directory_needs_ack = true
		_show_directory()
		directory_ready.emit(_directory_entries.duplicate(true))


func request_load(save_id: String) -> void:
	if _load_requested or not _saves.is_empty() \
			or _save_inflight or not _pending_frame.is_empty() or _directory_requested or _exit_requested:
		if _menu != null:
			_menu.set_message("请等待当前存档操作结束。")
		return
	var events: Array[Dictionary] = []
	if not _paused:
		events.append({"input": {"kind": "pause"}, "operation": ""})
	events.append({"input": {"kind": "prepare_load", "save_id": save_id}, "operation": "load"})
	if not _queue_events(events):
		if _menu != null:
			_menu.set_message("载入请求暂时无法提交。")
		return
	_load_was_paused = _paused
	_load_requested = true
	_load_cancel_requested = false
	if not _paused:
		_apply_pause(true)


func request_delete(save_id: String) -> void:
	if not _load_requested:
		_queue_event({"kind": "delete", "save_id": save_id, "sequence": _sequence}, "delete")


func _poll_candidate() -> void:
	if _candidate_result == 0:
		return
	if _load_cancel_requested:
		# The candidate can be destroyed between prepared delivery and payload
		# reading. Release the local notification so its terminal can be taken.
		_coordinator.take_result(_candidate_result)
		_operations.erase(_candidate_job)
		_candidate_result = 0
		return
	var candidate: Dictionary = _coordinator.poll_candidate(_candidate_job)
	if not candidate.get("ok", false):
		if candidate.get("error", "") not in ["busy", "not_ready"]:
			_report_error(str(candidate.get("error", "candidate_failed")))
		return
	_candidate = candidate.duplicate(true)
	_coordinator.take_result(_candidate_result)
	_operations.erase(_candidate_job)
	_candidate_result = 0
	candidate_ready.emit(_candidate.duplicate(true))


func presentation_ready() -> bool:
	if _load_cancel_requested or _candidate.is_empty() or not _coordinator.begin_handoff(_candidate_job):
		return false
	return _boolean(_coordinator.queue_control("ready", _candidate_job).get("ok", false))


func confirm_installed() -> bool:
	if _decision.is_empty() or not _session_installed or _switch_requested:
		return _switch_requested
	var response: Dictionary = _coordinator.queue_control("switch", _candidate_job, _integer(_decision.next_epoch))
	_switch_requested = _boolean(response.get("ok", false))
	return _switch_requested


func cancel_load() -> bool:
	if _candidate_job == 0 or not _decision.is_empty():
		return false
	var response: Dictionary = _coordinator.queue_control("cancel", _candidate_job)
	if response.get("ok", false) and response.get("cancelled", false):
		_load_cancel_requested = true
		return true
	return false


func _sync_controls() -> void:
	var frozen: bool = _coordinator.motion_frozen() or _paused or _exit_requested or not _error.is_empty() \
		or not _pending_frame.is_empty() or not _events.is_empty() or _presentation_frozen
	_player.set_backend_frozen(frozen)
	if _free_camera is FreeCameraRig:
		var rig: FreeCameraRig = _free_camera as FreeCameraRig
		rig.set_backend_frozen(frozen)
		rig.set_input_enabled(_focused and not _paused and not _exit_requested and _error.is_empty() \
			and not _boolean(_coordinator.state().closed) \
			and (_inventory == null or not _inventory.visible))
	if not frozen and _focused and _capture_before_pause \
			and (_inventory == null or not _inventory.visible):
		_capture_before_pause = false
		_player.set_controls_captured(true)


func _freeze_changed(_frozen: bool) -> void:
	_sync_controls()


func _report_error(message: String) -> void:
	if _error.is_empty():
		_error = message
		error_reported.emit(message)
		if _menu != null:
			_menu.set_message("后端错误：" + message, true)
	_sync_controls()


func _pause_requested() -> void:
	handle_escape()


func handle_escape() -> void:
	if _inventory != null and _inventory.visible:
		_close_inventory()
	elif _menu != null and _menu.visible and _menu.close_panel():
		pass
	elif _paused:
		request_pause(false)
	else:
		request_pause(true)


func _resume_requested() -> void:
	request_pause(false)


func _save_confirmed(name: String, overwrite: bool) -> void:
	var response: Dictionary = request_save(name, overwrite)
	if _menu != null:
		_menu.set_message("等待暂停后保存…" if response.get("ok", false) else "保存请求失败：" + str(response.get("error", "")))


func _return_requested() -> void:
	if _exit_requested or _load_requested or not request_pause(true):
		return
	_exit_requested = true
	_exit_directory_pending = true
	_file_mode = ""
	_prepare_exit_directory()
	_sync_controls()


func _prepare_exit_directory() -> void:
	if not _exit_directory_pending or _save_inflight or not _saves.is_empty() \
			or not _pending_frame.is_empty() or not _events.is_empty() or _directory_requested \
			or _boolean(_coordinator.state().operation_pending):
		return
	_exit_directory_pending = false
	_file_mode = "exit"
	request_directory()
	if not _directory_requested:
		_exit_directory_pending = true


func _break_requested() -> void:
	if can_step_physics() and _player.controls_enabled():
		edit_requested.emit("remove")


func _place_requested() -> void:
	if can_step_physics() and _player.controls_enabled():
		edit_requested.emit("build")


func _camera_input(event: InputEvent) -> void:
	if _free_view and event is InputEventMouseButton:
		var release: InputEventMouseButton = event as InputEventMouseButton
		if release.button_index == MOUSE_BUTTON_MIDDLE and not release.pressed:
			camera_input_requested.emit(event)
			return
	if can_step_physics() and _player.controls_enabled():
		camera_input_requested.emit(event)


func _show_pause_menu() -> void:
	_menu.show_runtime_menu(not _error.is_empty(), not _directory_entries.is_empty(),
		str(_session.get("world_name", "")), _number(_session.get("autosave_minutes", 5.0)),
		_integer(_session.get("autosave_retention", 3)), str(_session.get("world_id", "")))


func _default_save_name() -> String:
	return str(_session.get("world_name", "世界")) + "_" \
		+ Time.get_datetime_string_from_system().replace(":", "").replace("T", "_")


func _open_save_files() -> void:
	_open_files("save")


func _open_load_files() -> void:
	_open_files("load")


func _open_files(mode: String) -> void:
	if request_pause(true):
		_file_mode = mode
		request_directory()
		if _menu != null:
			_menu.set_message("正在读取存档列表…")


func _show_directory() -> void:
	if _menu == null or _file_mode.is_empty():
		return
	if _file_mode == "exit":
		_file_mode = ""
		for entry: Dictionary in _directory_entries:
			if entry.get("world_id", "") == _session.get("world_id", "") \
					and entry.get("name", "") == "退出存档" and entry.get("kind", "") != "exit":
				_exit_requested = false
				_menu.confirm_overwrite("退出存档", _save_exit)
				return
		_save_exit()
	else:
		_menu.show_files(_file_mode == "save", _directory_entries.duplicate(true), _default_save_name())


func _save_exit() -> void:
	var response: Dictionary = request_save("退出存档", true, "exit")
	if not response.get("ok", false):
		_exit_requested = false
	if _menu != null:
		_menu.set_message("等待保存后退出…" if response.get("ok", false) else "保存请求失败：" + str(response.get("error", "")))


func _file_panel_closed() -> void:
	_file_mode = ""
	if _load_requested:
		cancel_load()


func _toggle_inventory() -> void:
	if _inventory == null or _paused or _load_requested:
		return
	if _inventory.visible:
		_close_inventory()
	else:
		_capture_before_inventory = _player.controls_captured()
		_inventory.show()
		_player.set_inventory_open(true)
		interaction_cancelled.emit()
		_inventory.close_button.grab_focus()
		_sync_controls()


func _close_inventory() -> void:
	_inventory.hide()
	_player.set_inventory_open(false)
	_capture_before_pause = _capture_before_pause or _capture_before_inventory
	_capture_before_inventory = false
	_sync_controls()


func _toggle_view() -> void:
	if can_step_physics() and _player.controls_enabled():
		interaction_cancelled.emit()
		set_free_view(not _free_view)


func _focus_lost() -> void:
	_focused = false
	_capture_before_pause = false
	_capture_before_inventory = false
	interaction_cancelled.emit()
	_sync_controls()


func _focus_restored() -> void:
	_focused = true
	_sync_controls()


func can_apply_candidate_session() -> bool:
	if _decision.is_empty() or _candidate.is_empty() or _switch_requested:
		return false
	var value: Variant = _candidate.get("session")
	if not value is Dictionary:
		return false
	var session: Dictionary = value
	if not _coordinator.accepts_payload(session) or not session.get("player") is Dictionary:
		return false
	var pose: Dictionary = session.player
	# The native decoder validates the save; guard the engine-facing boundary
	# before making any scene changes so an invalid payload is retryable.
	for key: String in ["position", "velocity", "spawn", "body_rotation", "rotation", "free_position", "free_rotation"]:
		if not pose.get(key) is Vector3:
			return false
		var vector: Vector3 = pose[key]
		if not vector.is_finite():
			return false
	if not pose.get("tool") is int or not pose.get("build_rotation") is int \
			or not pose.get("free_view") is bool or not session.get("world_name") is String:
		return false
	if not SaveGameFiles.valid_id(session.get("world_id")) \
			or not SaveGameFiles.valid_name(session.get("world_name")):
		return false
	var minutes: float = _number(session.get("autosave_minutes"))
	var retention: int = _integer(session.get("autosave_retention"))
	var tool: int = _integer(pose.tool)
	var facing: int = _integer(pose.build_rotation)
	if not is_finite(minutes) or minutes < 0 or minutes > 1440 \
			or not session.get("autosave_retention") is int or retention < 1 or retention > 100 \
			or tool not in [1, 2, 3, 4, 5, 6, 7, 9, 13] or facing < 0 or facing > 3:
		return false
	return true


func apply_candidate_session() -> bool:
	if not can_apply_candidate_session():
		return false
	var session: Dictionary = _candidate.session
	var pose: Dictionary = session.player
	_paused = true
	_player.set_session_paused(true)
	_player.set_backend_frozen(true)
	set_session(session)
	_player.position = pose.position
	_player.velocity = pose.velocity
	_player.spawn_position = pose.spawn
	_player.rotation = pose.body_rotation
	_player.camera.rotation = pose.rotation
	_tool = _integer(pose.tool)
	_facing = _integer(pose.build_rotation)
	_free_view = _boolean(pose.free_view)
	_player.set_free_view(_free_view)
	_free_camera.position = pose.free_position
	if _free_camera is FreeCameraRig:
		var rig: FreeCameraRig = _free_camera as FreeCameraRig
		rig.active = _free_view
		rig.camera.rotation = pose.free_rotation
		rig.camera.current = _free_view
	elif _free_camera is Camera3D:
		_free_camera.rotation = pose.free_rotation
		(_free_camera as Camera3D).current = _free_view
	_player.camera.current = not _free_view
	_capture_before_pause = not _free_view and _focused
	_capture_before_inventory = false
	if _inventory != null:
		_inventory.hide()
		_player.set_inventory_open(false)
	_session_installed = true
	if _menu != null:
		_show_pause_menu()
	_sync_controls()
	view_changed.emit(_free_view)
	session_installed.emit(_session.duplicate(true))
	return true


static func _integer(value: Variant) -> int:
	if value is int:
		return value
	return 0


static func _number(value: Variant) -> float:
	if value is float:
		return value
	if value is int:
		var integer: int = value
		return float(integer)
	return NAN


static func _boolean(value: Variant) -> bool:
	if value is bool:
		return value
	return false
