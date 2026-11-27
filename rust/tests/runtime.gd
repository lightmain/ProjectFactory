extends SceneTree
## Actual extension: one operation, take-once completions, independent disk payloads.


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var backend: RefCounted = ClassDB.instantiate(&"FactoryBackend") as RefCounted
	assert(backend != null and backend.has_method("open_runtime"))
	assert(_result(backend, "open_backend", [{"api_version": 1}]).ok)
	for ruleset: String in ["legacy_discrete_v1", "conveyor_continuous_v1"]:
		assert(_result(backend, "open_runtime", [_options(ruleset)]).ok)
		assert(not _result(backend, "create_factory", [ruleset]).ok)
		assert(not _result(backend, "open_runtime", [{}]).ok)
		var build: Dictionary = {"request_id": 1, "kind": "build", "cells": [Vector3i.ZERO],
			"blocks": PackedInt32Array([7]), "directions": PackedInt32Array([3])}
		assert((await _retry(backend, "submit_runtime", [1, build])).ok)
		# A successful submit must never be repeated, even with the same identity.
		assert((await _retry(backend, "submit_runtime", [1, build], false)).error == "busy")
		var withheld: Dictionary = await _retry(backend, "poll_runtime", [0])
		assert(withheld.results.is_empty())
		assert((await _retry(backend, "submit_runtime", [1, build], false)).error == "busy")
		var committed: Dictionary = await _completion(backend, 1)
		assert(committed.outcome == "committed" and committed.world_epoch == 1)
		assert((await _retry(backend, "poll_runtime", [192])).results.is_empty())
		var cell: Dictionary = await _run(backend, 1, {"request_id": 2, "kind": "cell", "cell": Vector3i.ZERO})
		assert(cell.outcome == "cell" and cell.block == 7)
		var pause: Dictionary = {"request_id": 3, "kind": "pause"}
		assert((await _retry(backend, "submit_runtime", [2, pause])).error == "stale_epoch")
		assert((await _run(backend, 1, pause)).paused)
		var invalid: Dictionary = {"request_id": 4, "kind": "build", "cells": ["invalid"],
			"blocks": PackedInt32Array([7]), "directions": PackedInt32Array([3])}
		assert((await _retry(backend, "submit_runtime", [1, invalid])).error == "invalid_cell")
		await _run(backend, 1, {"request_id": 4, "kind": "resume"})
		var frame: Dictionary = await _run(backend, 1,
			{"request_id": 5, "kind": "frame", "frame_seq": 1, "delta": 0.02})
		assert(frame.outcome == "frame_completed" and frame.frame_seq == 1)
		var page: Dictionary = await _retry(backend, "poll_runtime", [0])
		assert(not page.timing.paused and page.timing.completed_frame == 1)
		assert(is_equal_approx(float(page.timing.time), 0.02))
		assert(_result(backend, "close_runtime").ok)
		assert(_result(backend, "close_runtime").ok)
		assert(_result(backend, "submit_runtime", [1, pause]).error == "closed")
		await _stop(backend)
		await _check_persistence(backend, ruleset)
	await _check_epoch_limit(backend)
	await _check_budgets(backend)
	assert(_result(backend, "close_backend").ok)
	print("FACTORY_RUNTIME_BRIDGE_PASS")
	quit()


func _options(ruleset: String) -> Dictionary:
	return {"epoch": 1, "ruleset": ruleset, "minimum": Vector3i(-8, -3, -8),
		"maximum": Vector3i(9, 12, 9), "floor_depth": 3, "interval": 0.1, "amount": 1}


func _save(request: int, name: String, sequence: int) -> Dictionary:
	return {"request_id": request, "kind": "save", "player": _player(),
		"world_id": "07070707070707070707070707070707", "world_name": "桥接存档世界",
		"autosave_minutes": 5.0, "retention": 3, "name": name,
		"overwrite": false, "save_kind": "manual", "sequence": sequence}


func _check_persistence(backend: RefCounted, ruleset: String) -> void:
	var path: String = ProjectSettings.globalize_path("user://runtime_" + str(Time.get_ticks_usec()))
	var options: Dictionary = _options(ruleset)
	options["save_root"] = path
	assert(_result(backend, "open_runtime", [options]).ok)
	assert(_result(backend, "open_runtime", [options]).error == "runtime_busy")
	await _run(backend, 1, {"request_id": 1, "kind": "build", "cells": [Vector3i.ZERO],
		"blocks": PackedInt32Array([7]), "directions": PackedInt32Array([3])})
	await _run(backend, 1, {"request_id": 2, "kind": "frame", "frame_seq": 1, "delta": 0.02})
	assert((await _retry(backend, "submit_runtime", [1, _save(3, "未暂停", 0)])).error == "not_paused")
	await _run(backend, 1, {"request_id": 3, "kind": "pause"})
	var started: Dictionary = await _run(backend, 1, _save(4, "命名保存", 0))
	assert(started.outcome == "save_started" and started.job_id == 4)
	var saved: Dictionary = await _completion(backend, 4)
	assert(saved.outcome == "save_completed" and saved.directory_sequence == 1)
	var save_id: String = saved.save_id
	var listed: Dictionary = await _run(backend, 1, {"request_id": 5, "kind": "list_directory"})
	assert(listed.outcome == "directory_ready")
	var directory: Dictionary = await _retry(backend, "poll_directory_runtime", [1, 5, 0, 1, 2048])
	assert(directory.ok and directory.entries.size() == 1 and directory.next_offset == 1)
	assert(directory.entries[0].id == save_id and directory.directory_sequence == 1)
	assert((await _retry(backend, "poll_directory_runtime", [1, 5, 0, 1, 1])).error == "invalid_argument")
	assert((await _retry(backend, "ack_directory_runtime", [1, 6])).error == "invalid_argument")
	assert((await _retry(backend, "poll_directory_runtime", [1, 5, 0, 1, 2048])) == directory)
	assert((await _retry(backend, "ack_directory_runtime", [1, 5])).ok)
	await _run(backend, 1, {"request_id": 6, "kind": "remove", "cell": Vector3i.ZERO})
	var prepared: Dictionary = await _run(backend, 1, {"request_id": 7, "kind": "prepare_load", "save_id": save_id})
	assert(prepared.outcome == "load_prepared")
	var candidate: Dictionary = await _retry(backend, "poll_candidate_runtime", [1, 7, 704])
	assert(candidate.ok and candidate.session.player == _player())
	assert(candidate.ruleset == ruleset and candidate.revision == 1)
	assert(is_equal_approx(float(candidate.time), 0.02))
	assert((await _retry(backend, "poll_candidate_runtime", [1, 7, 1])).error == "invalid_argument")
	assert((await _retry(backend, "poll_candidate_runtime", [1, 7, 704])) == candidate)
	assert((await _retry(backend, "cancel_runtime", [1, 7])).cancelled)
	var cancelled: Dictionary = await _completion(backend, 7)
	assert(cancelled.outcome == "load_failed" and cancelled.error == "cancelled")
	assert((await _retry(backend, "poll_candidate_runtime", [1, 7, 704])).error == "invalid_argument")
	assert((await _run(backend, 1, {"request_id": 8, "kind": "cell", "cell": Vector3i.ZERO})).block == 0)
	assert((await _run(backend, 1, {"request_id": 9, "kind": "prepare_load", "save_id": save_id})).outcome == "load_prepared")
	var decision: Dictionary = await _run(backend, 1, {"request_id": 10, "kind": "ready", "job_id": 9})
	assert(decision.outcome == "commit_decided" and decision.next_epoch == 2)
	assert(not (await _retry(backend, "cancel_runtime", [1, 9])).cancelled)
	var switched: Dictionary = await _run(backend, 1,
		{"request_id": 11, "kind": "switch", "job_id": 9, "next_epoch": 2})
	assert(switched.world_epoch == 2 and switched.outcome == "load_completed")
	var page: Dictionary = await _retry(backend, "poll_runtime", [0])
	assert(page.timing.paused and page.timing.completed_frame == 1)
	var cell: Dictionary = {"request_id": 12, "kind": "cell", "cell": Vector3i.ZERO}
	assert((await _retry(backend, "submit_runtime", [1, cell])).error == "stale_epoch")
	assert((await _run(backend, 2, cell)).block == 7)
	var deleted: Dictionary = await _run(backend, 2, {"request_id": 13, "kind": "delete",
		"save_id": save_id, "sequence": 0})
	assert(deleted.outcome == "delete_failed" and deleted.error == "stale_directory")
	deleted = await _run(backend, 2, {"request_id": 14, "kind": "delete", "save_id": save_id, "sequence": 1})
	assert(deleted.outcome == "delete_completed" and deleted.directory_sequence == 2)
	assert((await _run(backend, 2, _save(15, "损坏候选", 2))).outcome == "save_started")
	save_id = (await _completion(backend, 15)).save_id
	var disk: DirAccess = DirAccess.open(path)
	assert(disk != null)
	for name: String in disk.get_files():
		if name.ends_with(".pfs"):
			var file: FileAccess = FileAccess.open(path.path_join(name), FileAccess.WRITE)
			assert(file != null)
			file.store_string("broken checkpoint")
			file.close()
	var failed: Dictionary = await _run(backend, 2, {"request_id": 16, "kind": "prepare_load", "save_id": save_id})
	assert(failed.outcome == "load_failed" and failed.world_epoch == 2)
	assert((await _run(backend, 2, {"request_id": 17, "kind": "cell", "cell": Vector3i.ZERO})).block == 7)
	await _stop(backend)
	_remove_root(path)


func _check_epoch_limit(backend: RefCounted) -> void:
	var path: String = ProjectSettings.globalize_path("user://epoch_" + str(Time.get_ticks_usec()))
	var options: Dictionary = _options("legacy_discrete_v1")
	var epoch: int = 9223372036854775807
	options.merge({"epoch": epoch, "save_root": path}, true)
	assert(_result(backend, "open_runtime", [options]).ok)
	await _run(backend, epoch, {"request_id": 1, "kind": "frame", "frame_seq": 1, "delta": 0.0})
	await _run(backend, epoch, {"request_id": 2, "kind": "pause"})
	assert((await _run(backend, epoch, _save(3, "epoch 边界", 0))).outcome == "save_started")
	var save_id: String = (await _completion(backend, 3)).save_id
	assert((await _run(backend, epoch, {"request_id": 4, "kind": "prepare_load", "save_id": save_id})).outcome == "load_prepared")
	var ready: Dictionary = await _retry(backend, "submit_runtime",
		[epoch, {"request_id": 5, "kind": "ready", "job_id": 4}])
	assert(not ready.ok and ready.error == "invalid_argument")
	assert((await _retry(backend, "poll_candidate_runtime", [epoch, 4, 704])).ok)
	assert((await _retry(backend, "cancel_runtime", [epoch, 4])).cancelled)
	assert((await _completion(backend, 4)).outcome == "load_failed")
	await _stop(backend)
	_remove_root(path)


func _check_budgets(backend: RefCounted) -> void:
	for limits: Dictionary in [{"input_bytes": 0}, {"candidate_bytes": -1}]:
		var invalid: Dictionary = _options("legacy_discrete_v1")
		invalid["limits"] = limits
		assert(not _result(backend, "open_runtime", [invalid]).ok)
	var options: Dictionary = _options("legacy_discrete_v1")
	options["save_root"] = "relative/path"
	assert(_result(backend, "open_runtime", [options]).error == "invalid_argument")
	options.erase("save_root")
	options["limits"] = {"input_bytes": 32}
	assert(_result(backend, "open_runtime", [options]).ok)
	assert((await _retry(backend, "submit_runtime", [1, {"request_id": 1, "kind": "cell", "cell": Vector3i.ZERO}])).ok)
	assert((await _retry(backend, "poll_runtime", [95])).results.is_empty())
	var completion: Dictionary = await _completion(backend, 1)
	assert(completion.outcome == "cell")
	var bad_player: Dictionary = _player()
	bad_player["free_rotation"] = Vector3(NAN, 0, 0)
	var invalid_save: Dictionary = _save(2, "非法玩家", 0)
	invalid_save.player = bad_player
	assert((await _retry(backend, "submit_runtime", [1, invalid_save])).error == "invalid_argument")
	await _stop(backend)


func _player() -> Dictionary:
	return {"frame": 1, "position": Vector3(2, 1, 3), "velocity": Vector3(0.1, 0.2, 0.3),
		"spawn": Vector3(2, 0.1, 3), "body_rotation": Vector3(0, 0.3, 0),
		"rotation": Vector3(0.2, 0, 0), "tool": 13, "build_rotation": 3,
		"free_view": true, "free_position": Vector3(7, 8, 9), "free_rotation": Vector3(0.2, 0.3, 0.4)}


func _result(backend: RefCounted, method: String, arguments: Array = []) -> Dictionary:
	var value: Variant = backend.callv(method, arguments)
	assert(value is Dictionary)
	return value as Dictionary


func _retry(backend: RefCounted, method: String, arguments: Array, retry_busy: bool = true) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + 5000
	while true:
		var value: Dictionary = _result(backend, method, arguments)
		if value.get("error", "") != "busy" or not retry_busy:
			return value
		assert(Time.get_ticks_msec() < deadline, method)
		await process_frame
	return {}


func _completion(backend: RefCounted, request: int) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + 5000
	while true:
		# One completion per poll keeps SaveStarted and its terminal separately observable.
		var page: Dictionary = await _retry(backend, "poll_runtime", [96])
		assert(page.ok)
		if not page.results.is_empty():
			assert(page.results.size() == 1 and page.result_bytes == 96)
			assert(page.results[0].request_id == request)
			return page.results[0]
		assert(Time.get_ticks_msec() < deadline, "missing completion")
		await process_frame
	return {}


func _run(backend: RefCounted, epoch: int, command: Dictionary) -> Dictionary:
	assert((await _retry(backend, "submit_runtime", [epoch, command])).ok)
	return await _completion(backend, int(command.request_id))


func _stop(backend: RefCounted) -> void:
	assert(_result(backend, "close_runtime").ok)
	var deadline: int = Time.get_ticks_msec() + 5000
	while not _result(backend, "runtime_stopped").stopped:
		assert(Time.get_ticks_msec() < deadline)
		await process_frame


func _remove_root(path: String) -> void:
	var disk: DirAccess = DirAccess.open(path)
	assert(disk != null)
	for name: String in disk.get_files():
		assert(disk.remove(name) == OK)
	disk = null
	assert(DirAccess.remove_absolute(path) == OK)
