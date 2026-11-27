class_name FactoryRuntimeCoordinator
extends RefCounted
## One immutable operation, one disk job, and completions taken once.

signal result_ready(result: Dictionary)
signal freeze_changed(frozen: bool)
signal protocol_error(error: String)

const MAX_SEQUENCE: int = 9223372036854775807
const COMMAND_KINDS: Array[String] = ["cell", "remove", "direction", "build", "build_route",
	"query_ray", "query_build", "query_route", "frame", "pause", "resume", "save",
	"list_directory", "prepare_load", "delete", "ready", "switch"]
const DISK_KINDS: Array[String] = ["save", "list_directory", "prepare_load", "delete"]

var _backend: RefCounted
var _epoch: int
var _next_request: int = 1
var _last_frame: int = 0
var _command_budget: int = 65536
var _operation: Dictionary = {}
var _accepted: bool = false
var _disk_job: Dictionary = {}
var _results: Array[Dictionary] = []
var _desired_paused: bool = false
var _confirmed_paused: bool = false
var _status: String = "starting"
var _timing: Dictionary = {}
var _frozen: bool = true
var _error: String = ""
var _closed: bool = false
var _stopped: bool = false
var _pumping: bool = false
var _prepared_job: int = 0
var _handoff: bool = false
var _decided_epoch: int = 0


func _init(backend: RefCounted, epoch: int = 1, limits: Dictionary = {}) -> void:
	_backend = backend
	_epoch = epoch
	_command_budget = _integer(limits.get("command_bytes", _command_budget))
	if backend == null or epoch <= 0 or _command_budget < 32 or _command_budget > 65536:
		_fail("invalid_configuration")


func enqueue(input: Dictionary) -> Dictionary:
	if _closed or not _error.is_empty():
		return _rejected("closed" if _closed else _error)
	if not _operation.is_empty() or not _results.is_empty():
		return _rejected("busy")
	var kind: String = str(input.get("kind", ""))
	if kind not in COMMAND_KINDS or not accepts_payload(input):
		return _rejected("invalid_input")
	if _handoff and kind not in ["ready", "switch"]:
		return _rejected("handoff")
	if kind in DISK_KINDS and not _disk_job.is_empty():
		return _rejected("busy")
	if kind == "frame":
		var frame: int = _integer(input.get("frame_seq", 0))
		var delta: float = _number(input.get("delta", -1.0))
		if frame <= _last_frame or not is_finite(delta) or delta < 0 or delta > 4.0 / 60.0:
			return _rejected("invalid_frame")
		if _desired_paused and delta > 0:
			return _rejected("paused")
	if kind == "save" and not _confirmed_paused:
		return _rejected("not_paused")
	if _next_request >= MAX_SEQUENCE:
		return _rejected("sequence_exhausted")
	_operation = input.duplicate(true)
	_operation["request_id"] = _next_request
	_next_request += 1
	_accepted = false
	if kind in ["pause", "resume"]:
		_desired_paused = kind == "pause"
	_refresh_freeze()
	return {"ok": true, "request_id": _integer(_operation.request_id)}


func queue_frame(frame: int, delta: float) -> Dictionary:
	return enqueue({"kind": "frame", "frame_seq": frame, "delta": delta})


func queue_control(kind: String, job: int, next_epoch: int = 0) -> Dictionary:
	if kind == "cancel":
		return _call("cancel_runtime", [_epoch, job])
	if job != _prepared_job or not _handoff:
		return _rejected("not_ready")
	if kind == "ready":
		return enqueue({"kind": "ready", "job_id": job})
	if kind == "switch" and next_epoch == _decided_epoch:
		return enqueue({"kind": "switch", "job_id": job, "next_epoch": next_epoch})
	return _rejected("invalid_control")


func begin_handoff(job: int) -> bool:
	if _prepared_job != job or not _operation.is_empty() or not _results.is_empty() \
			or not _confirmed_paused:
		return false
	_handoff = true
	_refresh_freeze()
	return true


func adopt_epoch(request_id: int) -> bool:
	for result: Dictionary in _results:
		if _integer(result.request_id) == request_id and result.outcome == "load_completed" \
				and _integer(result.get("next_epoch", 0)) == _decided_epoch:
			_epoch = _decided_epoch
			_last_frame = _integer(_timing.get("completed_frame", 0))
			_prepared_job = 0
			_handoff = false
			_desired_paused = true
			_confirmed_paused = true
			_refresh_freeze()
			return true
	return false


func pump() -> void:
	if _pumping:
		return
	_pumping = true
	if _closed:
		_stopped = _boolean(_call("runtime_stopped", []).get("stopped", false))
	else:
		_poll()
		if _error.is_empty() and not _operation.is_empty() and not _accepted:
			var response: Dictionary = _call("submit_runtime", [_epoch, _operation])
			if response.get("ok", false):
				_accepted = true
				if _operation.kind == "frame":
					_last_frame = _integer(_operation.frame_seq)
				if _operation.kind in DISK_KINDS:
					_disk_job = _operation.duplicate(true)
			elif response.get("error", "") != "busy":
				_fail(str(response.get("error", "invalid_response")))
	_refresh_freeze()
	_pumping = false


func _poll() -> void:
	# Local completions must be handled before taking more. There are at most two.
	var bytes: int = 0 if not _results.is_empty() else 192
	var page: Dictionary = _call("poll_runtime", [bytes])
	if not page.get("ok", false):
		if page.get("error", "") != "busy":
			_fail(str(page.get("error", "invalid_response")))
		return
	_status = str(page.get("status", "faulted"))
	_timing = _dictionary(page.get("timing")).duplicate(true)
	var values: Variant = page.get("results")
	if not values is Array or values.size() > 2:
		_fail("invalid_results")
		return
	for value: Variant in values:
		var result: Dictionary = _dictionary(value)
		var request: int = _integer(result.get("request_id", 0))
		var world_operation: bool = _accepted and request == _integer(_operation.get("request_id", 0))
		var disk_operation: bool = request > 0 and (request == _integer(_disk_job.get("request_id", 0)) \
			or request == _prepared_job)
		var switching: bool = world_operation and _operation.get("kind", "") == "switch"
		var outcome: String = str(result.get("outcome", ""))
		var expected_epoch: int = _integer(_operation.get("next_epoch", 0)) \
			if switching and outcome == "load_completed" else _epoch
		if request <= 0 or (not world_operation and not disk_operation) \
				or _integer(result.get("world_epoch", 0)) != expected_epoch:
			_fail("invalid_result_identity")
			return
		if outcome.is_empty():
			_fail("invalid_result")
			return
		_results.append(result.duplicate(true))
		if world_operation:
			_operation = {}
			_accepted = false
		if disk_operation and outcome != "save_started":
			_disk_job = {}
		if outcome == "paused":
			_confirmed_paused = _boolean(result.get("paused", false))
		elif outcome == "load_prepared":
			_prepared_job = _integer(result.get("job_id", 0))
		elif outcome == "commit_decided":
			_decided_epoch = _integer(result.get("next_epoch", 0))
		elif outcome == "load_failed":
			var failed_job: int = _integer(result.get("job_id", 0))
			# Cancellation may retire the candidate before an unaccepted Ready
			# reaches Rust. That local request can no longer be submitted.
			if not _accepted and _operation.get("kind", "") == "ready" \
					and _integer(_operation.get("job_id", 0)) == failed_job:
				_operation = {}
			_prepared_job = 0
			_handoff = false
		result_ready.emit(result.duplicate(true))
	if _status == "faulted":
		_fail("faulted")


func take_result(request_id: int) -> bool:
	for index: int in range(_results.size()):
		var result: Dictionary = _results[index]
		if _integer(result.request_id) != request_id:
			continue
		if result.outcome == "load_completed" and _epoch != _integer(result.get("next_epoch", 0)):
			return false
		_results.remove_at(index)
		_refresh_freeze()
		return true
	return false


func pending_results() -> Array[Dictionary]:
	return _results.duplicate(true)


func motion_frozen() -> bool:
	return _frozen


func state() -> Dictionary:
	return {"epoch": _epoch, "last_frame_seq": _last_frame, "paused": _desired_paused,
		"pause_confirmed": _confirmed_paused and _operation.is_empty(),
		"operation_pending": not _operation.is_empty(), "disk_pending": not _disk_job.is_empty(),
		"handoff": _handoff, "status": _status, "frozen": _frozen, "error": _error,
		"closed": _closed, "stopped": _stopped, "timing": _timing.duplicate(true)}


func close() -> void:
	_closed = true
	_call("close_runtime", [])
	_refresh_freeze()


func poll_directory(job: int, offset: int, count: int = 16, bytes: int = 16384) -> Dictionary:
	return _call("poll_directory_runtime", [_epoch, job, offset, count, bytes])


func acknowledge_directory(job: int) -> Dictionary:
	return _call("ack_directory_runtime", [_epoch, job])


func poll_candidate(job: int) -> Dictionary:
	return _call("poll_candidate_runtime", [_epoch, job, 704])


func _refresh_freeze() -> void:
	var frozen: bool = _closed or not _error.is_empty() or _status != "running" or _handoff \
		or _desired_paused or not _operation.is_empty() or not _results.is_empty()
	if frozen != _frozen:
		_frozen = frozen
		freeze_changed.emit(frozen)


func _fail(error: String) -> void:
	if _error.is_empty():
		_error = error
		protocol_error.emit(error)
	_refresh_freeze()


func _call(method: String, arguments: Array) -> Dictionary:
	if _backend == null or not _backend.has_method(method):
		return _rejected("missing_method")
	return _dictionary(_backend.callv(method, arguments))


func accepts_payload(payload: Dictionary) -> bool:
	var visits: Array[int] = [1024]
	return _bounded(payload, 0, visits) and var_to_bytes(payload).size() <= _command_budget


static func _rejected(error: String) -> Dictionary:
	return {"ok": false, "error": error}


static func _dictionary(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


static func _integer(value: Variant) -> int:
	return value if value is int else 0


static func _number(value: Variant) -> float:
	return float(value) if value is float or value is int else NAN


static func _boolean(value: Variant) -> bool:
	return value if value is bool else false


static func _bounded(value: Variant, depth: int, visits: Array[int]) -> bool:
	visits[0] -= 1
	if depth > 4 or visits[0] < 0:
		return false
	if value is Dictionary:
		var dictionary: Dictionary = value
		if dictionary.size() > 32:
			return false
		for key: Variant in dictionary:
			if not key is String or not _bounded(key, depth + 1, visits) \
					or not _bounded(dictionary[key], depth + 1, visits):
				return false
		return true
	if value is Array:
		var array: Array = value
		if array.size() > 256:
			return false
		for item: Variant in array:
			if not _bounded(item, depth + 1, visits):
				return false
		return true
	if value is String:
		var text: String = value
		return text.to_utf8_buffer().size() <= 4096
	if value is PackedInt32Array:
		var packed: PackedInt32Array = value
		return packed.size() <= 256
	if value is Vector3:
		var vector: Vector3 = value
		return vector.is_finite()
	if value is float:
		var number: float = value
		return is_finite(number)
	return value is bool or value is int or value is Vector3i
