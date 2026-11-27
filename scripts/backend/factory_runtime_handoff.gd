class_name FactoryRuntimeHandoff
extends RefCounted
## Scene installation is allowed only at the caller's physics boundary.

var _coordinator: FactoryRuntimeCoordinator
var _host: FactoryRuntimeHost
var _stream: FactoryPresentationStream
var _view: FactoryStaticView
var _keys: Array[Vector3i] = []
var _current_keys: Array[Vector3i] = []
var _candidate_interest: Callable
var _job: int = 0
var _decision: Dictionary = {}
var _ready_sent: bool = false
var _installed: bool = false
var _waiting_current: bool = true
var _closed: bool = false
var _error: String = ""


func _init(backend: RefCounted, coordinator: FactoryRuntimeCoordinator,
		host: FactoryRuntimeHost, view: FactoryStaticView,
		candidate_interest: Callable = Callable()) -> void:
	_coordinator = coordinator
	_host = host
	_stream = FactoryPresentationStream.new(backend, view)
	_view = view
	_candidate_interest = candidate_interest
	host.candidate_ready.connect(_candidate_ready)
	host.commit_decided.connect(_commit_decided)
	host.load_finished.connect(_load_finished)
	host.set_presentation_frozen(true)


func request_current(keys: Array[Vector3i]) -> bool:
	if _closed or _job != 0 or not _stream.request(_integer(_coordinator.state().epoch), 0, keys):
		return false
	_keys = keys.duplicate()
	_current_keys = keys.duplicate()
	_waiting_current = true
	_host.set_presentation_frozen(true)
	return true


func guard_motion(start: Vector3, end: Vector3, radius: Vector3, revision: int) -> bool:
	var covered: bool = not _closed and _error.is_empty() and _job == 0 and not _waiting_current \
		and _view.covers_sweep(start, end, radius, _integer(_coordinator.state().epoch), revision)
	_host.set_presentation_frozen(not covered)
	return covered


static func interest_keys(player_position: Vector3, camera_position: Vector3) -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	var unique: Dictionary[Vector3i, bool] = {}
	for position: Vector3 in [player_position, camera_position]:
		var grid: Vector3 = (position / 4.0).floor()
		if not grid.is_finite() or grid.x < -2147483647.0 or grid.x > 2147483646.0 \
				or grid.y < -2147483647.0 or grid.y > 2147483646.0 \
				or grid.z < -2147483647.0 or grid.z > 2147483646.0:
			return []
		var center: Vector3i = Vector3i(grid)
		for x: int in range(-1, 2):
			for y: int in range(-1, 2):
				for z: int in range(-1, 2):
					var key: Vector3i = center + Vector3i(x, y, z)
					if not unique.has(key):
						unique[key] = true
						keys.append(key)
	return keys


static func interest_keys_in_bounds(player_position: Vector3, camera_position: Vector3,
		minimum: Vector3i, maximum: Vector3i) -> Array[Vector3i]:
	for axis: int in range(3):
		if minimum[axis] >= maximum[axis]:
			return []
	var keys: Array[Vector3i] = []
	for key: Vector3i in interest_keys(player_position, camera_position):
		var intersects: bool = true
		for axis: int in range(3):
			var low: int = key[axis] * 8
			var high: int = low + 8
			if low < -2147483648 or high > 2147483647 \
					or low >= maximum[axis] or high <= minimum[axis]:
				intersects = false
				break
		if intersects:
			keys.append(key)
	return keys


func pump() -> void:
	_stream.pump()
	if not str(_stream.state().error).is_empty():
		_error = str(_stream.state().error)
	if not _error.is_empty():
		_host.set_presentation_frozen(true)


func physics_frame() -> void:
	if _closed or not _error.is_empty():
		return
	if _job == 0:
		if _stream.state().prepared and _stream.activate():
			_waiting_current = false
			_host.set_presentation_frozen(false)
		return
	if _decision.is_empty():
		if not _ready_sent and _stream.confirm_prepared():
			_ready_sent = _host.presentation_ready()
		return
	if not _installed:
		# No yield or engine frame between preflight, resources, pose and UI.
		# Invalid sessions retain both the old root and the staged new root.
		if not _host.can_apply_candidate_session() or not _stream.activate():
			return
		if not _host.apply_candidate_session():
			_error = "session_installation_failed"
			return
		_installed = true
	_host.confirm_installed()


func _candidate_ready(candidate: Dictionary) -> void:
	if _closed:
		return
	_job = _integer(candidate.get("job_id"))
	_ready_sent = false
	_installed = false
	_decision = {}
	var keys: Array[Vector3i] = []
	if _candidate_interest.is_valid():
		var value: Variant = _candidate_interest.call(candidate)
		if not value is Array:
			_error = "invalid_candidate_interest"
			return
		keys.clear()
		for item: Variant in value:
			if not item is Vector3i:
				_error = "invalid_candidate_interest"
				return
			var key: Vector3i = item
			keys.append(key)
	else:
		var session_value: Variant = candidate.get("session")
		if session_value is Dictionary:
			var session: Dictionary = session_value
			var pose_value: Variant = session.get("player")
			if pose_value is Dictionary:
				var pose: Dictionary = pose_value
				if pose.get("position") is Vector3 and pose.get("free_position") is Vector3:
					var position: Vector3 = pose.position
					var camera_position: Vector3 = pose.free_position
					if candidate.get("minimum") is Vector3i and candidate.get("maximum") is Vector3i:
						var minimum: Vector3i = candidate.minimum
						var maximum: Vector3i = candidate.maximum
						keys = interest_keys_in_bounds(position, camera_position, minimum, maximum)
	_keys = keys
	_host.set_presentation_frozen(true)
	if not _stream.request(_integer(_coordinator.state().epoch), _job, keys):
		_error = "candidate_subscription_failed"


func _commit_decided(decision: Dictionary) -> void:
	if not _closed and _integer(decision.get("job_id")) == _job:
		_decision = decision.duplicate(true)


func _load_finished(success: bool) -> void:
	if _closed:
		return
	var keys: Array[Vector3i] = _keys.duplicate() if success else _current_keys.duplicate()
	_job = 0
	_decision = {}
	_ready_sent = false
	_installed = false
	if not request_current(keys):
		_error = "current_subscription_failed"
	elif not success:
		_error = ""


func close() -> void:
	if _closed:
		return
	_closed = true
	_host.set_presentation_frozen(true)
	_host.candidate_ready.disconnect(_candidate_ready)
	_host.commit_decided.disconnect(_commit_decided)
	_host.load_finished.disconnect(_load_finished)
	_stream.close()


func state() -> Dictionary:
	return {"error": _error, "installed": _installed, "candidate": _job > 0,
		"waiting_current": _waiting_current, "stream": _stream.state()}


static func _integer(value: Variant) -> int:
	if value is int:
		return value
	return 0
