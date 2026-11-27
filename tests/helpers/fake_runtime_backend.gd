extends RefCounted
## Controllable single-operation transport.

var submit_busy: bool = false
var control_busy: bool = false
var poll_busy: bool = false
var submit_error: String = ""
var control_error: String = ""
var status: String = "running"
var epoch: int = 1
var paused: bool = false
var completed_frame: int = 0
var stopped: bool = false
var closed: bool = false
var attempts: Array[Dictionary] = []
var inputs: Array[Dictionary] = []
var controls: Array[Dictionary] = []
var poll_budgets: Array[int] = []
var results: Array[Dictionary] = []
var directory_entries: Array[Dictionary] = []
var _operation: int = 0


func set_directory_entries(entries: Array) -> void:
	directory_entries.assign(entries)


func submit_runtime(world_epoch: int, input: Dictionary) -> Dictionary:
	attempts.append({"epoch": world_epoch, "input": input.duplicate(true)})
	if not submit_error.is_empty():
		return {"ok": false, "error": submit_error}
	if submit_busy or _operation != 0:
		return {"ok": false, "error": "busy"}
	inputs.append(input.duplicate(true))
	_operation = int(input.request_id)
	return {"ok": true}


func poll_runtime(bytes: int) -> Dictionary:
	poll_budgets.append(bytes)
	if poll_busy:
		return {"ok": false, "error": "busy"}
	var page: Array[Dictionary] = []
	while not results.is_empty() and page.size() < mini(2, bytes / 96):
		var result: Dictionary = results.pop_front()
		if int(result.request_id) == _operation:
			_operation = 0
		page.append(result.duplicate(true))
	return {"ok": true, "world_epoch": epoch, "status": status, "results": page,
		"result_bytes": page.size() * 96,
		"timing": {"paused": paused, "completed_frame": completed_frame}}


func emit_command(request: int, outcome: String, extra: Dictionary = {}) -> void:
	if outcome == "paused":
		paused = bool(extra.get("paused", false))
	elif outcome == "frame_completed":
		completed_frame = int(extra.get("frame_seq", 0))
	var result: Dictionary = {"world_epoch": epoch, "request_id": request,
		"outcome": outcome, "tick": 0, "revision": 0}
	result.merge(extra, true)
	results.append(result)


func cancel_runtime(origin: int, job: int) -> Dictionary:
	if not control_error.is_empty():
		return {"ok": false, "error": control_error}
	if control_busy:
		return {"ok": false, "error": "busy"}
	controls.append({"kind": "cancel", "epoch": origin, "job": job})
	return {"ok": true, "cancelled": true}


func close_runtime() -> Dictionary:
	closed = true
	return {"ok": true}


func runtime_stopped() -> Dictionary:
	return {"ok": true, "stopped": stopped}


func poll_directory_runtime(_origin: int, _job: int, offset: int, count: int, _bytes: int) -> Dictionary:
	var entries: Array[Dictionary] = []
	for index: int in range(offset, mini(offset + count, directory_entries.size())):
		entries.append(directory_entries[index].duplicate(true))
	return {"ok": true, "entries": entries, "next_offset": offset + entries.size(),
		"total_entries": directory_entries.size(), "directory_sequence": 0}


func ack_directory_runtime(_origin: int, _job: int) -> Dictionary:
	return {"ok": true}
