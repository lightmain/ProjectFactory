extends SceneTree
## Query payload survives completion take and is replaced only by the next query.


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var backend: RefCounted = ClassDB.instantiate(&"FactoryBackend") as RefCounted
	assert(backend != null and backend.has_method("poll_query_runtime"))
	assert(_call(backend, "open_backend", [{"api_version": 1}]).ok)
	for ruleset: String in ["legacy_discrete_v1", "conveyor_continuous_v1"]:
		assert(_call(backend, "open_runtime", [{"epoch": 1, "ruleset": ruleset,
			"minimum": Vector3i(-8, -3, -8), "maximum": Vector3i(9, 12, 9),
			"floor_depth": 3, "interval": 0.1, "amount": 1}]).ok)
		await _run(backend, {"request_id": 1, "kind": "build", "cells": [Vector3i.ZERO],
			"blocks": PackedInt32Array([7]), "directions": PackedInt32Array([3])})
		assert((await _retry(backend, "submit_runtime", [1, _ray(2, 23)])).ok)
		assert((await _retry(backend, "submit_runtime", [1, _ray(3, 24)], false)).error == "busy")
		var terminal: Dictionary = await _completion(backend, 2)
		assert(terminal.outcome == "query_ready" and terminal.query_id == 23)
		assert(terminal.view_generation == 5 and terminal.payload_bytes == 160)
		var hit: Dictionary = await _retry(backend, "poll_query_runtime", [1, 2, 23, 160])
		assert(hit.ok and hit.kind == "ray" and hit.found and hit.cell == Vector3i.ZERO, str(hit))
		# Block 7 is a full-height chest, not the thin belt shape.
		assert(hit.normal == Vector3i.UP and is_equal_approx(hit.position.y, 0.5), str(hit))
		assert(hit.block == 7 and hit.direction == 3 and hit.route_target == Vector3i.ZERO)
		assert(hit.request_id == 2 and hit.query_id == 23 and hit.revision == 1)
		assert((await _retry(backend, "poll_query_runtime", [1, 2, 23, 160])) == hit)
		assert((await _retry(backend, "poll_query_runtime", [1, 2, 23, 159])).error == "invalid_argument")
		assert((await _retry(backend, "poll_query_runtime", [2, 2, 23, 160])).error == "stale_epoch")
		var route: Dictionary = _route(3, "query_route")
		route.query_id = 24
		route.view_generation = 6
		assert((await _run(backend, route)).outcome == "query_ready")
		assert((await _retry(backend, "poll_query_runtime", [1, 2, 23, 160])).error == "invalid_argument")
		var preview: Dictionary = await _retry(backend, "poll_query_runtime", [1, 3, 24, 8192])
		assert(preview.ok and preview.kind == "preview")
		assert(preview.cells is PackedInt32Array and preview.blocks is PackedInt32Array)
		assert(preview.cells == PackedInt32Array([1, 0, 0, 2, 0, 0, 3, 0, 0, 4, 0, 0]))
		assert(preview.blocks == PackedInt32Array([6, 6, 6, 6]))
		assert(preview.directions == PackedInt32Array([3, 3, 3, 3]))
		assert(preview.payload_bytes == 176 and preview.revision == 1)
		var invalid: Dictionary = _route(4, "build_route")
		invalid.orders = PackedInt32Array([2])
		assert((await _retry(backend, "submit_runtime", [1, invalid])).error == "invalid_route_order")
		# Rejected input leaves both the world and the last query payload intact.
		assert((await _run(backend, {"request_id": 4, "kind": "cell", "cell": Vector3i.ZERO})).block == 7)
		assert((await _retry(backend, "poll_query_runtime", [1, 3, 24, 8192])) == preview)
		assert((await _run(backend, _route(5, "build_route"))).outcome == "committed")
		assert((await _run(backend, {"request_id": 6, "kind": "cell", "cell": Vector3i(4, 0, 0)})).block == 6)
		assert(_call(backend, "close_runtime").ok)
		assert(_call(backend, "poll_query_runtime", [1, 3, 24, 8192]).error == "closed")
		var deadline: int = Time.get_ticks_msec() + 5000
		while not _call(backend, "runtime_stopped").stopped:
			assert(Time.get_ticks_msec() < deadline)
			await process_frame
	assert(_call(backend, "close_backend").ok)
	print("FACTORY_RUNTIME_QUERIES_PASS")
	quit()


func _ray(request: int, id: int) -> Dictionary:
	return {"request_id": request, "kind": "query_ray", "query_id": id, "view_generation": 5,
		"origin": Vector3(0.25, 2, 0.25), "ray": Vector3.DOWN, "distance": 4.0}


func _route(request: int, kind: String) -> Dictionary:
	return {"request_id": request, "kind": kind, "start": Vector3i(1, 0, 0),
		"direction": 3, "targets": [Vector3i(4, 0, 0)],
		"orders": PackedInt32Array([1]), "max_cells": 32}


func _call(backend: RefCounted, method: String, args: Array = []) -> Dictionary:
	var value: Variant = backend.callv(method, args)
	assert(value is Dictionary)
	return value as Dictionary


func _retry(backend: RefCounted, method: String, args: Array, retry_busy: bool = true) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + 5000
	while true:
		var value: Dictionary = _call(backend, method, args)
		if value.get("error", "") != "busy" or not retry_busy:
			return value
		assert(Time.get_ticks_msec() < deadline, method)
		await process_frame
	return {}


func _completion(backend: RefCounted, request: int) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + 5000
	while true:
		var page: Dictionary = await _retry(backend, "poll_runtime", [192])
		assert(page.ok)
		if not page.results.is_empty():
			assert(page.results.size() == 1 and page.results[0].request_id == request)
			return page.results[0]
		assert(Time.get_ticks_msec() < deadline)
		await process_frame
	return {}


func _run(backend: RefCounted, command: Dictionary) -> Dictionary:
	assert((await _retry(backend, "submit_runtime", [1, command])).ok)
	return await _completion(backend, int(command.request_id))
