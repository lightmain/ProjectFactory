class_name FactoryPresentationStream
extends RefCounted
## One bounded static round; Busy preserves the original request and cursor.

const MAX_SEQUENCE: int = 9223372036854775807
var _backend: RefCounted
var _view: FactoryStaticView
var _epoch: int = 0
var _generation: int = 0
var _accepted_epoch: int = 0
var _accepted_generation: int = 0
var _job: int = 0
var _keys: Array[Vector3i] = []
var _round: Dictionary = {}
var _cursor: int = 0
var _installed_snapshot: int = 0
var _subscribing: bool = false
var _confirmed: bool = false
var _closing: bool = false
var _closed: bool = false
var _retired: bool = false
var _error: String = ""


func _init(backend: RefCounted, view: FactoryStaticView) -> void:
	_backend = backend
	_view = view
	if backend == null or view == null:
		_error = "invalid_configuration"


func request(epoch: int, job: int, keys: Array[Vector3i]) -> bool:
	if _closing or epoch <= 0 or job < 0 or keys.is_empty() \
			or keys.size() > FactoryStaticView.MAX_KEYS:
		return false
	var unique: Dictionary[Vector3i, bool] = {}
	for key: Vector3i in keys:
		if unique.has(key):
			return false
		unique[key] = true
	# A cancelled candidate may have failed locally while the old active world
	# remains healthy. Explicitly leaving that candidate retires its resources
	# and error, while preserving the accepted identity and generation barrier.
	if not _error.is_empty():
		if _job == 0 or job != 0 or _error in ["faulted", "missing_method", "invalid_configuration"]:
			return false
		_error = ""
	if epoch != _epoch:
		_generation = 0
	if _generation == MAX_SEQUENCE:
		_fail("generation_exhausted")
		return false
	_discard_round()
	_epoch = epoch
	_job = job
	_keys = keys.duplicate()
	_generation += 1
	_installed_snapshot = 0
	_subscribing = true
	_retired = false
	return true


func pump() -> void:
	if _closing:
		_unsubscribe()
		return
	if not _error.is_empty() or _generation == 0 or _retired:
		return
	if _subscribing:
		var subscribed: Dictionary = _call("subscribe_presentation_runtime", [_epoch, _generation, _job, _keys])
		if not subscribed.get("ok", false):
			if subscribed.get("error", "") == "stale_epoch":
				_retire_response(subscribed)
			elif subscribed.get("error", "") not in ["busy", "not_ready"]:
				_fail(str(subscribed.get("error", "subscription_failed")))
			return
		_subscribing = false
		_accepted_epoch = _epoch
		_accepted_generation = _generation
	var info: Dictionary = _current_info()
	if info.is_empty() or info.get("stage", "") != "ready":
		return
	if _integer(info.snapshot_id) == _installed_snapshot:
		return
	if _round.is_empty() or not _same_round(info):
		_discard_round()
		if not _view.begin_snapshot(info, _keys):
			_fail("invalid_snapshot")
			return
		_round = info.duplicate(true)
	if _view.prepared():
		return
	var page: Dictionary = _call("poll_presentation_page_runtime",
		[_epoch, _generation, _integer(_round.snapshot_id), _cursor, FactoryStaticView.PAGE_BYTES])
	if not page.get("ok", false):
		if _retire_response(page):
			return
		if page.get("error", "") == "invalid_argument":
			_discard_round()
		elif page.get("error", "") != "busy":
			_fail(str(page.get("error", "page_failed")))
		return
	if not _view.stage_page(page):
		_fail("invalid_page")
		return
	_cursor += 1


func confirm_prepared() -> bool:
	if _closing or not _error.is_empty() or not _view.prepared():
		return false
	var info: Dictionary = _current_info()
	if info.is_empty():
		return false
	if info.get("stage") != "ready" or not _same_round(info):
		_discard_round()
		return false
	if _confirmed:
		return true
	var response: Dictionary = _call("ack_presentation_runtime",
		[_epoch, _generation, _integer(_round.snapshot_id)])
	if response.get("ok", false):
		_confirmed = true
	elif _retire_response(response):
		return false
	elif response.get("error", "") in ["invalid_ack", "invalid_argument"]:
		_discard_round()
	elif response.get("error", "") != "busy":
		_fail(str(response.get("error", "ack_failed")))
	return _confirmed


func activate() -> bool:
	if not confirm_prepared():
		return false
	var snapshot: int = _integer(_round.snapshot_id)
	if not _view.activate(_epoch, snapshot):
		_fail("activation_failed")
		return false
	_installed_snapshot = snapshot
	_round = {}
	_cursor = 0
	_confirmed = false
	return true


func state() -> Dictionary:
	return {"epoch": _epoch, "generation": _generation, "job": _job, "page_index": _cursor,
		"snapshot": _integer(_round.get("snapshot_id", 0)), "prepared": is_instance_valid(_view) and _view.prepared(),
		"confirmed": _confirmed, "error": _error, "closing": _closing, "closed": _closed,
		"retired": _retired}


func close() -> void:
	if _closing:
		return
	_closing = true
	_discard_round()
	_unsubscribe()


func _unsubscribe() -> void:
	if _closed:
		return
	if _accepted_generation == 0:
		_closed = true
		return
	var response: Dictionary = _call("unsubscribe_presentation_runtime", [_accepted_epoch, _accepted_generation])
	if response.get("ok", false) or response.get("error", "") in ["closed", "stale_epoch"]:
		_closed = true
	elif response.get("error", "") != "busy":
		_error = str(response.get("error", "unsubscribe_failed"))
		_closed = true


func _current_info() -> Dictionary:
	var info: Dictionary = _call("poll_presentation_runtime", [_epoch])
	if not info.get("ok", false):
		if _retire_response(info):
			return {}
		elif info.get("error", "") != "busy":
			_fail(str(info.get("error", "poll_failed")))
		return {}
	if _integer(info.get("world_epoch", 0)) != _epoch \
			or _integer(info.get("view_generation", 0)) != _generation \
			or _integer(info.get("job_id", -1)) != _job:
		_fail("invalid_interest_identity")
		return {}
	if info.get("stage") == "aborted":
		var keys: Array[Vector3i] = _keys.duplicate()
		request(_epoch, _job, keys)
		return {}
	if info.get("stage") == "building":
		_discard_round()
	elif info.get("stage") != "ready":
		_fail("invalid_stage")
		return {}
	return info


func _retire_response(response: Dictionary) -> bool:
	if response.get("error", "") not in ["not_ready", "stale_epoch"]:
		return false
	_discard_round()
	_retired = true
	_subscribing = false
	return true


func _same_round(info: Dictionary) -> bool:
	for field: String in ["snapshot_id", "revision", "tick", "total_pages", "total_bytes"]:
		if _round.get(field) != info.get(field):
			return false
	return true


func _discard_round() -> void:
	if is_instance_valid(_view):
		_view.abort()
	_round = {}
	_cursor = 0
	_confirmed = false


func _fail(error: String) -> void:
	_error = error
	_discard_round()


func _call(method: String, args: Array) -> Dictionary:
	if _backend == null or not _backend.has_method(method):
		return {"ok": false, "error": "missing_method"}
	var result: Variant = _backend.callv(method, args)
	if result is Dictionary:
		return result
	return {"ok": false, "error": "invalid_response"}


static func _integer(value: Variant) -> int:
	if value is int:
		return value
	return 0
