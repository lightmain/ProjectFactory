class_name FactoryRuntimePlayground
extends RefCounted
## Injected scene adapter. All authority stays in the worker; only local display is retained.

var _game: Node3D
var _backend: RefCounted
var _player: FactoryPlayer
var _camera: Camera3D
var _hud: FactoryHud
var _preview: MeshInstance3D
var _route_preview: BuildPreview
var _coordinator: FactoryRuntimeCoordinator
var _host: FactoryRuntimeHost
var _handoff: FactoryRuntimeHandoff
var _static: FactoryStaticView
var _dynamic: FactoryDynamicView
var _minimum: Vector3i = Vector3i(-8, -3, -8)
var _maximum: Vector3i = Vector3i(9, 12, 9)
var _keys: Array[Vector3i] = []
var _rules: String = ""
var _restart: String = ""
var _restart_paused: bool = false
var _closed: bool = false
var _error: String = ""
var _starting: bool = false
var _seeded: bool = false
var _frame: int = 0
var _tool: int = 6
var _facing: int = 0
var _free: bool = false
var _rotating: bool = false
var _anchor: Vector3
var _has_anchor: bool = false
var _camera_hit: Dictionary = {}
var _zoom_steps: int = 0
var _orbit_motion: Vector2 = Vector2.ZERO
var _enter_camera: bool = false
var _revision: int = 0
var _hit: Dictionary = {}
var _fingerprint: Dictionary = {}
var _operation: Dictionary = {}
var _terminal: Dictionary = {}
var _view_generation: int = 1
var _query_id: int = 0
var _route: Dictionary = {}
var _route_valid: bool = false
var _build_pose: Dictionary = {}
var _build_transform: Transform3D
var _camera_transform: Transform3D
var _notice_text: String = ""
var _notice_until: int = 0
var _candidate_bounds: Dictionary = {}
var _lift: float = NAN
var _display_generation: int = 0
var _display_pending: bool = false
var _display_info: Dictionary = {}
var _display_page: int = 0
var _display_release: bool = false
var _display_elapsed: float = 0.0


func _init(game: Node3D, backend: RefCounted) -> void:
	_game = game
	_backend = backend
	_player = game.get("player") as FactoryPlayer
	_camera = game.get("_free_camera") as Camera3D
	_hud = game.get("_hud") as FactoryHud
	_preview = game.get("_preview") as MeshInstance3D
	_route_preview = game.get("_route_preview") as BuildPreview
	_static = FactoryStaticView.new()
	_static.name = "StaticWorld"
	game.add_child(_static)
	_dynamic = FactoryDynamicView.new()
	_dynamic.name = "DynamicLogistics"
	game.add_child(_dynamic)
	_player.set_physics_process(false)
	_player.build_waypoint_requested.connect(_lock_route)
	_player.free_cancel_requested.connect(cancel_interaction)
	_player.respawn_requested.connect(_respawn)
	(game.get("_menu") as SessionMenu).return_requested.connect(_return_after_error)


func start_factory(rules: String) -> void:
	if _coordinator != null:
		_restart = rules
		_restart_paused = _host.paused() if _host != null else false
		_dispose_session()
		return
	_open(rules)


func _open(rules: String) -> void:
	_error = ""
	_rules = rules
	_starting = true
	_seeded = false
	_game.set("ready_for_play", false)
	var root: String = str(_game.get("save_root"))
	var response: Dictionary = _call("open_runtime", [{"epoch": 1, "ruleset": rules,
		"minimum": _minimum, "maximum": _maximum, "floor_depth": 3,
		"interval": 0.6, "amount": 1, "save_root": ProjectSettings.globalize_path(root)}])
	if not response.get("ok", false):
		_fail(str(response.get("error", "runtime_open_failed")))
		return
	_player.respawn(Vector3(2.8, 0.05, 4.0))
	_player.spawn_position = _player.position
	_player.set_session_paused(false)
	_game.set("_paused", false)
	(_game.get("_menu") as SessionMenu).hide()
	_player.set_free_view(false)
	_free = false
	_camera.current = false
	_player.camera.current = true
	# Rebind after each new host so its generic tool callback runs first.
	if _player.block_selected.is_connected(_select):
		_player.block_selected.disconnect(_select)
		_player.build_rotation_requested.disconnect(_rotate)
	_coordinator = FactoryRuntimeCoordinator.new(_backend, 1)
	_host = FactoryRuntimeHost.new(_coordinator, _player, _camera, _game.get("_menu") as SessionMenu)
	_host.set_tool_state(_tool, _facing)
	_player.block_selected.connect(_select)
	_player.build_rotation_requested.connect(_rotate)
	_host.bind_inventory(_game.get("_inventory_view") as InventoryView)
	var world_id: String = str(_backend.call("new_world_id"))
	_game.set("world_id", world_id)
	_host.set_session({"world_id": world_id, "world_name": str(_game.get("world_name")),
		"autosave_minutes": float(_game.get("autosave_minutes")),
		"autosave_retention": int(_game.get("autosave_retention"))})
	_host.edit_requested.connect(_edit)
	_host.camera_input_requested.connect(_camera_input)
	_host.view_changed.connect(_view_changed)
	_host.interaction_cancelled.connect(_cancel_from_host)
	_host.error_reported.connect(_fail)
	_host.gameplay_finished.connect(_result)
	_host.exit_ready.connect(_exit_ready)
	_host.session_installed.connect(_session_installed)
	_host.load_finished.connect(_load_finished)
	_host.candidate_ready.connect(_candidate_ready)
	_handoff = FactoryRuntimeHandoff.new(_backend, _coordinator, _host, _static)
	var cells: Array[Vector3i] = []
	for z: int in range(6):
		cells.append(Vector3i(0, 0, z))
	_submit({"kind": "build", "cells": cells, "blocks": PackedInt32Array([5, 6, 6, 6, 6, 7]),
		"directions": PackedInt32Array([0, 0, 0, 0, 0, 0]), "purpose": "seed"})
	if _restart_paused:
		set_paused(true)
	_restart_paused = false
	_player.set_physics_process(false)


func pump(delta: float) -> void:
	if _closed:
		return
	if not _restart.is_empty():
		if _call("runtime_stopped").get("stopped", false):
			_coordinator = null
			var rules: String = _restart
			_restart = ""
			_open(rules)
		return
	if _host == null:
		return
	_host.pump()
	_handoff.pump()
	if not str(_handoff.state().error).is_empty():
		_fail(str(_handoff.state().error))
	var timing: Dictionary = _coordinator.state().timing
	_revision = int(timing.get("revision", _revision))
	_handle_terminal()
	if not _error.is_empty():
		_player.set_backend_frozen(true)
		return
	_display_elapsed += delta
	_pump_display()
	if _starting:
		if _seeded and not _handoff.state().waiting_current:
			_starting = false
			_game.set("ready_for_play", true)
			_game.set("_persistence_ready", true)
			_host.request_directory()
			if _game.get_tree().has_meta("backend_open_saves"):
				_game.get_tree().remove_meta("backend_open_saves")
				_host.request_pause(true)
				var menu: SessionMenu = _game.get("_menu") as SessionMenu
				menu.load_requested.emit()
		return
	_update_interest()
	if _free and _operation.is_empty() and _host.can_step_physics() and _player.controls_enabled() \
			and (_zoom_steps != 0 or _rotating and not _has_anchor) and _camera_hit.is_empty():
		_query_id += 1
		var center_query: Dictionary = _center_ray()
		center_query.merge({"kind": "query_ray", "query_id": _query_id,
			"view_generation": _view_generation, "purpose": "camera_ray", "fingerprint": _center_ray()})
		_submit(center_query)
		return
	var fingerprint: Dictionary = _ray_input()
	if fingerprint != _fingerprint and _build_pose.is_empty():
		_hit = {}
		_preview.hide()
		_route_preview.hide()
	if _operation.is_empty() and _build_pose.is_empty() and _host.can_step_physics() \
			and _player.controls_enabled() and fingerprint != _fingerprint:
		_query_id += 1
		var query: Dictionary = fingerprint.duplicate()
		query.merge({"kind": "query_ray", "query_id": _query_id, "view_generation": _view_generation,
			"purpose": "ray", "fingerprint": fingerprint})
		_submit(query)
	_update_hud()


func physics_frame(delta: float) -> void:
	if _closed or _host == null or not _restart.is_empty():
		return
	_handoff.physics_frame()
	if not _error.is_empty():
		return
	if is_finite(_lift) and not _handoff.state().waiting_current:
		_player.raise_to(_lift)
		_lift = NAN
		_build_pose = {}
	if not _display_info.is_empty() and _dynamic.prepared() and not _display_release:
		if int(_display_info.revision) == _revision:
			_dynamic.activate(int(_coordinator.state().epoch), int(_display_info.snapshot_id))
		else:
			_dynamic.abort()
		_display_release = true
	if _starting or not _build_pose.is_empty():
		return
	var input: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back") \
		if _player.controls_captured() else Vector2.ZERO
	var horizontal: Vector3 = Basis(Vector3.UP, _player.camera.rotation.y) * Vector3(input.x, 0, input.y) * _player.move_speed
	var vertical_speed: float = _player.velocity.y
	if _player.controls_captured() and _player.is_on_floor() and Input.is_action_just_pressed("jump"):
		vertical_speed = maxf(vertical_speed, PlayerMotionRules.jump_speed(_player.max_jump_height, float(_player.get("_gravity"))))
	var vertical: Vector2 = PlayerMotionRules.vertical_step(vertical_speed, delta, float(_player.get("_gravity")))
	var end: Vector3 = _player.global_position + horizontal * delta + Vector3.UP * vertical.x
	var box: AABB = _player.occupied_bounds()
	var low: Vector3 = box.position.min(box.position + end - _player.global_position)
	var high: Vector3 = box.end.max(box.end + end - _player.global_position)
	if _player.is_on_floor():
		high.y += PlayerMotionRules.STEP_HEIGHT + _player.safe_margin * 2
		low.y -= _player.floor_snap_length
	var covered: bool = _guard_bounds(AABB(low, high - low).grow(_player.safe_margin), _revision)
	if not covered or not _host.can_step_physics():
		return
	_player.call("_physics_process", delta)
	if _free and _player.controls_enabled():
		_camera_physics(delta)
	_frame = maxi(_frame + 1, int(_coordinator.state().last_frame_seq) + 1)
	_host.finish_physics_frame(_frame, delta)


func _update_interest() -> void:
	var keys: Array[Vector3i] = FactoryRuntimeHandoff.interest_keys_in_bounds(
		_player.global_position.clamp(Vector3(_minimum) * 0.5, Vector3(_maximum) * 0.5 - Vector3.ONE * 0.001),
		(_camera.global_position if _free else _player.global_position).clamp(
			Vector3(_minimum) * 0.5, Vector3(_maximum) * 0.5 - Vector3.ONE * 0.001), _minimum, _maximum)
	if keys != _keys and not _handoff.state().candidate and not keys.is_empty():
		_keys = keys
		_handoff.request_current(keys)


func _submit(command: Dictionary) -> bool:
	if not _operation.is_empty():
		return false
	var input: Dictionary = command.duplicate(true)
	input.erase("purpose")
	input.erase("fingerprint")
	if not _host.queue_gameplay(input):
		return false
	_operation = command.duplicate(true)
	return true


func _result(result: Dictionary) -> void:
	if _operation.is_empty() or not _terminal.is_empty():
		_fail("unexpected_gameplay_result")
		return
	_terminal = result.duplicate(true)


func _handle_terminal() -> void:
	if _terminal.is_empty():
		return
	var result: Dictionary = _terminal
	var operation: Dictionary = _operation
	var kind: String = str(operation.kind)
	var outcome: String = str(result.outcome)
	if outcome == "query_ready":
		var page: Dictionary = _call("poll_query_runtime", [int(result.world_epoch),
			int(result.request_id), int(result.query_id), 8192])
		if page.get("error", "") == "busy":
			return
		if not page.get("ok", false):
			_fail(str(page.get("error", "query_failed")))
			return
		if int(page.world_epoch) != int(_coordinator.state().epoch) or int(page.query_id) != int(operation.query_id) \
				or int(page.view_generation) != _view_generation or int(page.revision) != _revision:
			_hit = {}
		elif operation.get("purpose") == "camera_ray" and _free and operation.fingerprint == _center_ray():
			_camera_hit = page
		elif kind == "query_ray" and operation.get("purpose") == "ray" and operation.fingerprint == _ray_input():
			_hit = page
			_fingerprint = operation.fingerprint
		elif kind in ["query_route", "query_build"] and operation.get("fingerprint") == _ray_input():
			_show_preview(page)
	_terminal = {}
	_operation = {}
	if operation.get("purpose") == "seed":
		if outcome != "committed":
			_fail("example_build_failed")
			return
		_revision = int(result.revision)
		_seeded = true
		_update_interest()
	elif outcome == "build_prepared":
		var lift: float = float(result.lift)
		var unchanged: bool = _player.global_transform == _build_transform and _camera.global_transform == _camera_transform
		var center: Vector3 = _player.occupied_bounds().get_center()
		var radius: Vector3 = _player.occupied_bounds().size * 0.5 + Vector3.ONE * _player.safe_margin
		var rise: float = maxf(0, lift - _player.global_position.y)
		var covered: bool = _guard_bounds(AABB(center - radius, radius * 2 + Vector3.UP * rise), int(result.revision))
		var clear: bool = unchanged and covered and _player.can_raise_to(lift)
		_submit({"kind": "confirm_build", "token": int(result.token), "pose": _build_pose, "engine_clear": clear})
	elif outcome == "build_committed" or kind == "remove" and outcome == "committed":
		_revision = int(result.revision)
		_lift = float(result.get("lift", _player.global_position.y))
		_handoff.request_current(_keys)
		cancel_interaction()
	elif kind in ["prepare_build", "prepare_route", "confirm_build"] and outcome == "rejected":
		_build_pose = {}
		_notice("无法在此建造；请检查占用与上方空间。")
	elif outcome == "faulted":
		_fail("faulted")
	elif outcome in ["rejected", "query_failed"]:
		if kind == "remove":
			_build_pose = {}
		if int(operation.get("view_generation", _view_generation)) == _view_generation:
			_route_valid = false
			_route_preview.set_invalid(true)
			_notice("操作未完成：" + str(result.get("error", outcome)))
	if operation.get("purpose") == "ray" and not _hit.is_empty() and _player.controls_enabled():
		_request_preview()


func _ray_input() -> Dictionary:
	var camera: Camera3D = _camera if _free else _player.camera
	var pointer: Vector2 = _game.get_viewport().get_mouse_position() if _free \
		else _game.get_viewport().get_visible_rect().size * 0.5
	return {"origin": camera.project_ray_origin(pointer), "ray": camera.project_ray_normal(pointer),
		"distance": 30.0 if _free else 6.0, "revision": _revision, "tool": _tool, "generation": _view_generation}


func _request_preview() -> void:
	if not _hit.get("found", false):
		_preview.hide()
		return
	var command: Dictionary
	if not _route.is_empty():
		var target: Variant = _target(_hit)
		if target == null:
			return
		command = _route_command(target)
		command["kind"] = "query_route"
	else:
		var cell: Vector3i = _hit.cell + _hit.normal
		command = {"kind": "query_build", "cells": [cell], "blocks": PackedInt32Array([_oriented_tool()]),
			"directions": PackedInt32Array([_facing])}
	_query_id += 1
	command.merge({"query_id": _query_id, "view_generation": _view_generation, "fingerprint": _ray_input()})
	_submit(command)


func _show_preview(page: Dictionary) -> void:
	var packed: PackedInt32Array = page.cells
	var blocks: PackedInt32Array = page.blocks
	var facing: PackedInt32Array = page.directions
	if packed.size() != blocks.size() * 3 or facing.size() != blocks.size() or blocks.size() > 256:
		_fail("invalid_preview")
		return
	var cells: Array[Vector3i] = []
	var directions: Array[Vector3i] = []
	var types: Array[int] = []
	var existing: Array[int] = []
	for i: int in range(blocks.size()):
		cells.append(Vector3i(packed[i*3], packed[i*3+1], packed[i*3+2]))
		directions.append([Vector3i.BACK, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.RIGHT][facing[i]])
		types.append(blocks[i])
		existing.append(0)
	if _route.is_empty():
		_preview.visible = not cells.is_empty()
		if not cells.is_empty():
			_preview.position = Vector3(cells[0]) * 0.5 + Vector3.ONE * 0.25
	else:
		var locks: Array[Vector3i] = []
		locks.assign(_route.targets)
		_route_preview.show_observation(cells, directions, 6, existing, false, locks, types)
		_route_valid = true


func _edit(operation: String) -> void:
	if operation == "remove" and not _route.is_empty():
		cancel_interaction()
		return
	if _operation.is_empty() and _host.can_step_physics() and _player.controls_enabled() and _fingerprint == _ray_input():
		if operation == "build":
			place_hit(_hit, _tool)
		elif operation == "remove" and _hit.get("found", false):
			_begin_edit({"kind": "remove", "cell": _hit.cell})


func place_hit(hit: Dictionary, tool: int) -> void:
	if not _host.can_step_physics() or not _player.controls_enabled() or not _operation.is_empty() or _rotating:
		return
	_tool = tool
	if tool == 6:
		var target: Variant = _target(hit)
		if target == null:
			return
		if _route.is_empty():
			_route = {"start": target, "direction": _facing, "targets": [], "orders": PackedInt32Array(), "order": true}
			_invalidate()
			return
		var command: Dictionary = _route_command(target)
		command["kind"] = "prepare_route"
		_begin_edit(command)
	elif hit.get("found", false):
		_begin_edit({"kind": "prepare_build", "cells": [hit.cell + hit.normal],
			"blocks": PackedInt32Array([_oriented_tool()]), "directions": PackedInt32Array([_facing])})


func _begin_edit(command: Dictionary) -> void:
	_build_transform = _player.global_transform
	_camera_transform = _camera.global_transform
	var occupied: AABB = _player.occupied_bounds()
	var camera_bounds: AABB = AABB(_camera.global_position - Vector3.ONE * FreeCameraRig.HALF_SIZE,
		Vector3.ONE * FreeCameraRig.HALF_SIZE * 2.0)
	_build_pose = {"frame": maxi(1, _frame), "player_min": occupied.position, "player_max": occupied.end,
		"free_view": _free, "camera_min": camera_bounds.position, "camera_max": camera_bounds.end,
		"margin": _player.safe_margin}
	if command.kind != "remove":
		command["pose"] = _build_pose
	if not _submit(command):
		_build_pose = {}


func _target(hit: Dictionary) -> Variant:
	if not hit.get("found", false):
		return null
	if hit.get("has_route_target", false):
		return hit.get("route_target")
	return hit.cell + hit.normal


func _route_command(target: Vector3i) -> Dictionary:
	var targets: Array[Vector3i] = []
	targets.assign(_route.targets)
	targets.append(target)
	var orders: PackedInt32Array = _route.orders.duplicate()
	orders.append(1 if _route.order else 0)
	return {"start": _route.start, "direction": _route.direction, "targets": targets,
		"orders": orders, "max_cells": 64}


func _lock_route() -> void:
	if _route.is_empty() or not _route_valid or not _hit.get("found", false) or _route.targets.size() >= 15:
		return
	var target: Variant = _target(_hit)
	if target == null or not _route.targets.is_empty() and _route.targets.back() == target:
		return
	_route.targets.append(target)
	_route.orders.append(1 if _route.order else 0)
	_invalidate()


func _select(tool: int) -> void:
	if tool == 8:
		_notice("多方块结构尚未接入此试玩。")
		_host.set_tool_state(_tool, _facing)
		return
	cancel_interaction()
	_tool = tool
	_host.set_tool_state(_tool, _facing)
	_invalidate()


func _rotate() -> void:
	if _route.is_empty():
		_facing = (_facing + 1) % 4
	else:
		_route.order = not _route.order
	_host.set_tool_state(_tool, _facing)
	_invalidate()


func _oriented_tool() -> int:
	return VoxelWorldData.oriented_slope(_tool, _facing) if _tool in [9, 13] else _tool


func cancel_interaction() -> void:
	_route = {}
	_route_valid = false
	_rotating = false
	_has_anchor = false
	_camera_hit = {}
	_zoom_steps = 0
	_orbit_motion = Vector2.ZERO
	_invalidate()


func _cancel_from_host() -> void:
	var inventory: InventoryView = _game.get("_inventory_view") as InventoryView
	if inventory.visible:
		_rotating = false
		_has_anchor = false
		_camera_hit = {}
		_zoom_steps = 0
		_orbit_motion = Vector2.ZERO
		_invalidate()
	else:
		cancel_interaction()


func _invalidate() -> void:
	_view_generation += 1
	_fingerprint = {}
	_hit = {}
	_preview.hide()
	_route_preview.hide()


func _view_changed(free: bool) -> void:
	_free = free
	_game.set("free_view", free)
	cancel_interaction()
	_enter_camera = free


func _camera_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button: InputEventMouseButton = event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_MIDDLE:
			_rotating = button.pressed
			_has_anchor = false
			_camera_hit = {}
			_orbit_motion = Vector2.ZERO
			_zoom_steps = 0
		elif button.pressed and button.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] \
				and not _rotating:
			_zoom_steps = clampi(_zoom_steps + (1 if button.button_index == MOUSE_BUTTON_WHEEL_UP else -1), -32, 32)
	elif event is InputEventMouseMotion and _rotating and _host.can_step_physics():
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		if motion.relative.is_finite():
			_orbit_motion = (_orbit_motion + motion.relative * 0.004).clamp(Vector2.ONE * -PI, Vector2.ONE * PI)


func _center_ray() -> Dictionary:
	return {"origin": _camera.global_position, "ray": -_camera.global_basis.z, "distance": 40.0}


func _camera_physics(delta: float) -> void:
	if _enter_camera:
		var eye: Vector3 = _player.camera.global_position
		var destination: Vector3 = eye + Vector3.UP * FreeCameraRig.INITIAL_HEIGHT
		if not _guard_bounds(AABB(eye, destination - eye).grow(FreeCameraRig.HALF_SIZE), _revision):
			return
		_camera.global_position = eye
		_move_camera(destination - eye)
		_enter_camera = false
		_camera.rotation = Vector3(deg_to_rad(FreeCameraRig.INITIAL_PITCH), 0, 0)
		_invalidate()
		return
	if not _camera_hit.is_empty():
		if _camera_hit.get("found", false):
			_anchor = _camera_hit.position
			_has_anchor = _rotating
			if _zoom_steps != 0:
				var distance: float = _camera.global_position.distance_to(_anchor)
				var target: float = maxf(FreeCameraRig.MIN_SURFACE_DISTANCE, distance * pow(FreeCameraRig.ZOOM_FACTOR, _zoom_steps))
				_move_camera(-_camera.global_basis.z * (distance - target))
		_zoom_steps = 0
		_camera_hit = {}
	if _rotating:
		if not _has_anchor or _orbit_motion.is_zero_approx():
			return
		var radius: float = _camera.global_position.distance_to(_anchor)
		var initial: Vector3 = _camera.rotation
		var target: Vector3 = Vector3(clampf(initial.x - _orbit_motion.y, deg_to_rad(-85), deg_to_rad(85)),
			initial.y - _orbit_motion.x, 0)
		_orbit_motion = Vector2.ZERO
		var angle: float = absf(target.x - initial.x) + absf(target.y - initial.y)
		var segments: int = maxi(1, ceili(angle / minf(0.02, 0.08 / maxf(radius, 0.001))))
		for step: int in range(1, segments + 1):
			var desired: Vector3 = _anchor + Basis.from_euler(initial.lerp(target, float(step) / segments)).z * radius
			if not _move_camera(desired - _camera.global_position):
				break
			if _camera.global_position.distance_to(_anchor) > 0.01:
				_camera.look_at(_anchor)
			if _camera.global_position.distance_to(desired) > 0.002:
				break
		return
	if _zoom_steps == 0:
		var input: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		var movement: Vector3 = Basis(Vector3.UP, _camera.rotation.y) * Vector3(input.x, 0, input.y)
		_move_camera(movement * delta * 4.0)


func _guard_bounds(box: AABB, revision: int) -> bool:
	# The backend defines out-of-world space as empty. Only intersecting world
	# chunks require installed collision; retain a boundary point for lifecycle guards.
	var minimum: Vector3 = Vector3(_minimum) * 0.5
	var maximum: Vector3 = Vector3(_maximum) * 0.5 - Vector3.ONE * 0.0001
	var low: Vector3 = box.position.clamp(minimum, maximum)
	var high: Vector3 = box.end.clamp(minimum, maximum)
	return _handoff.guard_motion((low + high) * 0.5, (low + high) * 0.5, (high - low) * 0.5, revision)


func _move_camera(motion: Vector3) -> bool:
	var end: Vector3 = _camera.global_position + motion
	if not _free or not _host.can_step_physics() or end.distance_to(_player.global_position) > 15.0 \
			or not _guard_bounds(AABB(_camera.global_position.min(end),
				_camera.global_position.max(end) - _camera.global_position.min(end)).grow(FreeCameraRig.HALF_SIZE), _revision):
		return false
	var query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
	var shape: BoxShape3D = BoxShape3D.new()
	shape.size = Vector3.ONE * FreeCameraRig.HALF_SIZE * 2.0
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, _camera.global_position)
	query.motion = motion
	query.collision_mask = 1
	var fraction: PackedFloat32Array = _game.get_world_3d().direct_space_state.cast_motion(query)
	if fraction.size() != 2:
		return false
	_camera.global_position += motion * fraction[0]
	return fraction[0] > 0


func _pump_display() -> void:
	if _coordinator.state().handoff or _handoff.state().candidate:
		if _display_pending:
			_display_release = true
		return
	var epoch: int = int(_coordinator.state().epoch)
	if _display_release:
		var released: Dictionary = _call("release_display_runtime", [int(_display_info.get("world_epoch", epoch)), _display_generation])
		if released.get("ok", false) or released.get("error", "") in ["stale_epoch", "closed"]:
			_display_pending = false
			_display_info = {}
			_display_release = false
			_dynamic.abort()
		return
	if not _display_pending:
		if _keys.is_empty() or _display_elapsed < 0.05:
			return
		_display_generation += 1
		var requested: Dictionary = _call("request_display_runtime", [epoch, _display_generation, _keys])
		if requested.get("ok", false):
			_display_pending = true
			_display_elapsed = 0
		elif requested.get("error", "") not in ["busy", "not_ready"]:
			_fail(str(requested.get("error", "display_failed")))
		return
	if _display_info.is_empty():
		var info: Dictionary = _call("poll_display_runtime", [epoch, _display_generation])
		if not info.get("ok", false):
			if info.get("error", "") not in ["busy", "not_ready"]:
				_display_release = true
			return
		if not _dynamic.begin_snapshot(info):
			_fail("invalid_display_manifest")
			return
		_display_info = info
		_display_page = 0
	if _dynamic.prepared():
		return
	var page: Dictionary = _call("poll_display_page_runtime", [epoch, _display_generation,
		int(_display_info.snapshot_id), _display_page, 65536])
	if not page.get("ok", false):
		if page.get("error", "") not in ["busy", "not_ready"]:
			_display_release = true
		return
	if not _dynamic.stage_page(page):
		_fail("invalid_display_page")
		return
	_display_page += 1


func _update_hud() -> void:
	var target: String = "瞄准方块查看设施数量"
	if _hit.get("found", false):
		var cell: Vector3i = _hit.cell
		target = "%s / [%d, %d, %d]" % [VoxelWorldData.block_name(int(_hit.block)), cell.x, cell.y, cell.z]
		for row: Dictionary in _dynamic.snapshot().get("machines", []):
			if row.cell == cell:
				target += " / 铁矿：%d" % int(row.quantity)
	var build: String = "右键放置 / R 转向 / 后台物流"
	if _tool == 6:
		build = "右键选起点，再右键提交线路" if _route.is_empty() else "右键提交 / C 锁定 / R 切换轴 / 左键取消"
	_hud.update_observation(_tool, target, build, _player.controls_enabled(), _free)
	var status: Label = _game.get("_status") as Label
	status.text = "%s / tick %d / 局部矿石 %d" % [_rules, int(_coordinator.state().timing.get("tick", 0)),
		int(_dynamic.snapshot().get("ore_count", 0))]
	if Time.get_ticks_msec() < _notice_until:
		status.text = _notice_text


func set_paused(paused: bool) -> void:
	if _host != null:
		_host.request_pause(paused)
	_game.set("_paused", paused)


func handle_escape() -> void:
	_host.handle_escape()


func _notice(message: String) -> void:
	_notice_text = message
	_notice_until = Time.get_ticks_msec() + 3000
	var status: Label = _game.get("_status") as Label
	status.text = message


func _session_installed(session: Dictionary) -> void:
	var pose: Dictionary = session.player
	_tool = int(pose.tool)
	_facing = int(pose.build_rotation)
	_free = bool(pose.free_view)
	_game.set("world_id", session.world_id)
	_game.set("world_name", session.world_name)
	_game.set("free_view", _free)
	cancel_interaction()
	_enter_camera = false


func _load_finished(_success: bool) -> void:
	if _success:
		_error = ""
		_game.set("ready_for_play", true)
	if _success and not _candidate_bounds.is_empty():
		_minimum = _candidate_bounds.minimum
		_maximum = _candidate_bounds.maximum
	_candidate_bounds = {}
	_frame = int(_coordinator.state().last_frame_seq)
	_display_release = _display_pending
	_keys = []
	_update_interest()


func _candidate_ready(candidate: Dictionary) -> void:
	_candidate_bounds = {"minimum": candidate.minimum, "maximum": candidate.maximum}


func _respawn() -> void:
	if _build_pose.is_empty():
		_player.respawn(_player.spawn_position)
		cancel_interaction()


func _exit_ready() -> void:
	_game.get_tree().change_scene_to_file("res://scenes/session.tscn")


func _fail(error: String) -> void:
	if _error.is_empty():
		_error = error
		_game.set("ready_for_play", false)
		_player.set_backend_frozen(true)
		if _host != null:
			_host.request_pause(true)
		(_game.get("_menu") as SessionMenu).set_message("后台试玩无法继续：" + error, true)
		_notice("后台试玩无法继续：" + error)


func _return_after_error() -> void:
	if not _error.is_empty():
		close()
		_exit_ready()


func _call(method: String, args: Array = []) -> Dictionary:
	if not _backend.has_method(method):
		return {"ok": false, "error": "missing_method"}
	var response: Variant = _backend.callv(method, args)
	return response as Dictionary if response is Dictionary else {"ok": false, "error": "invalid_response"}


func display_snapshot() -> Dictionary:
	return _dynamic.snapshot()


func state() -> Dictionary:
	return {"error": _error, "tick": int(_coordinator.state().timing.get("tick", 0)) if _coordinator != null else 0,
		"revision": _revision, "ready": not _starting, "operation": _operation.duplicate(),
		"paused": _host.paused() if _host != null else true}


func _dispose_session() -> void:
	_game.set("ready_for_play", false)
	_game.set("_persistence_ready", false)
	if _host != null:
		_host.disconnect_inputs()
	if _handoff != null:
		_handoff.close()
	if _coordinator != null:
		_coordinator.close()
	_player.set_backend_frozen(true)
	_operation = {}
	_terminal = {}
	_build_pose = {}
	_display_pending = false
	_display_info = {}
	_display_release = false
	_lift = NAN
	_keys = []
	cancel_interaction()


func close() -> void:
	_closed = true
	_dispose_session()
