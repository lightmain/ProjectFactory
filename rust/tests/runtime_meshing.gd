extends SceneTree
## Real packed-array bridge, independent of the later scene installer.


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var backend: RefCounted = ClassDB.instantiate(&"FactoryBackend") as RefCounted
	if backend == null or not backend.has_method("subscribe_presentation_runtime"):
		printerr("FACTORY_RUNTIME_MESHING_MISSING")
		quit(3)
		return
	assert(_call(backend, "open_backend", [{"api_version": 1}]).ok)
	for ruleset: String in ["legacy_discrete_v1", "conveyor_continuous_v1"]:
		assert(_call(backend, "open_runtime", [{"epoch": 1, "ruleset": ruleset,
			"minimum": Vector3i(-32, -4, -32), "maximum": Vector3i(32, 60, 32),
			"floor_depth": 4, "interval": 0.1, "amount": 1}]).ok)
		var cells: Array[Vector3i] = []
		var blocks: PackedInt32Array = []
		var directions: PackedInt32Array = []
		for x: int in range(8):
			for z: int in range(8):
				if (x + z) % 2 == 0:
					cells.append(Vector3i(x, 2, z))
					blocks.append(3)
					directions.append(3)
		var command: Dictionary = {"request_id": 1, "kind": "build", "cells": cells,
			"blocks": blocks, "directions": directions}
		assert((await _retry(backend, "submit_runtime", [1, command])).ok)
		await _completed(backend, 1)
		var keys: Array[Vector3i] = [Vector3i.ZERO, Vector3i(-1, 0, -1)]
		assert((await _retry(backend, "subscribe_presentation_runtime", [1, 1, 0, keys])).ok)
		assert((await _retry(backend, "subscribe_presentation_runtime", [1, 1, 0, keys])).ok)
		var info: Dictionary = await _ready(backend)
		assert(info.total_pages == 3 and info.tick == 0)
		var first: Dictionary = await _retry(backend, "poll_presentation_page_runtime",
			[1, 1, info.snapshot_id, 0, 65536])
		assert(first.ok and first.page_bytes <= 65536)
		assert((await _retry(backend, "poll_presentation_page_runtime",
			[1, 1, info.snapshot_id, 0, int(first.page_bytes) - 1])).error == "invalid_argument")
		assert((await _retry(backend, "ack_presentation_runtime",
			[1, 1, info.snapshot_id])).error == "invalid_ack")
		# The undelivered second page has 64 complete cube faces.
		assert((await _retry(backend, "poll_presentation_page_runtime",
			[1, 1, info.snapshot_id, 1, 4096 + 64 * 352 - 1])).error == "invalid_argument")
		assert((await _retry(backend, "ack_presentation_runtime",
			[1, 1, info.snapshot_id])).error == "invalid_ack")
		for arguments: Array in [[-1, 1, info.snapshot_id, 1, 65536],
				[1, -1, info.snapshot_id, 1, 65536], [1, 1, -1, 1, 65536],
				[1, 1, info.snapshot_id, -1, 65536], [1, 1, info.snapshot_id, 1, -1]]:
			assert(not (await _retry(backend, "poll_presentation_page_runtime", arguments)).ok)
		var triangles: int = 0
		for index: int in range(int(info.total_pages)):
			var page: Dictionary = await _retry(backend, "poll_presentation_page_runtime",
				[1, 1, info.snapshot_id, index, 65536])
			assert(page.ok and page.snapshot_id == info.snapshot_id and page.page_index == index)
			assert(page.keys is PackedInt32Array and page.keys == PackedInt32Array([0, 0, 0, -1, 0, -1]))
			assert(page.positions is PackedVector3Array and page.normals is PackedVector3Array)
			assert(page.colors is PackedColorArray and page.uv is PackedVector2Array)
			assert(page.custom is PackedFloat32Array and page.indices is PackedInt32Array)
			assert(page.collision is PackedVector3Array)
			var positions: PackedVector3Array = page.positions
			var normals: PackedVector3Array = page.normals
			var colors: PackedColorArray = page.colors
			var uv: PackedVector2Array = page.uv
			var custom: PackedFloat32Array = page.custom
			var indices: PackedInt32Array = page.indices
			var collision: PackedVector3Array = page.collision
			assert(normals.size() == positions.size() and colors.size() == positions.size())
			assert(uv.size() == positions.size() and custom.size() == positions.size() * 4)
			assert(collision.size() == indices.size() and indices.size() % 3 == 0)
			assert(var_to_bytes(page).size() <= int(page.page_bytes))
			assert((await _retry(backend, "poll_presentation_page_runtime",
				[1, 1, info.snapshot_id, index, page.page_bytes])) == page)
			for vertex: int in range(indices.size()):
				assert(indices[vertex] >= 0 and indices[vertex] < positions.size())
				assert(collision[vertex] == positions[indices[vertex]])
				assert(collision[vertex].is_finite())
			triangles += indices.size()
		assert(triangles == 32 * 36)
		assert((await _retry(backend, "ack_presentation_runtime", [1, 1, info.snapshot_id])).ok)
		assert((await _retry(backend, "ack_presentation_runtime", [1, 1, info.snapshot_id])).ok)
		command = {"request_id": 2, "kind": "build", "cells": [Vector3i(8, 2, 1)],
			"blocks": PackedInt32Array([3]), "directions": PackedInt32Array([3])}
		assert((await _retry(backend, "submit_runtime", [1, command])).ok)
		await _completed(backend, 2)
		assert(not (await _retry(backend, "ack_presentation_runtime", [1, 1, info.snapshot_id])).ok)
		var updated: Dictionary = await _ready(backend)
		assert(updated.snapshot_id > info.snapshot_id and updated.revision > info.revision)
		assert(updated.tick == 0)
		keys.clear()
		for x: int in range(4):
			for y: int in range(4):
				for z: int in range(4):
					keys.append(Vector3i(x, y, z))
		assert(keys.size() == 64)
		assert((await _retry(backend, "subscribe_presentation_runtime", [1, 2, 0, keys])).ok)
		info = await _ready(backend)
		first = await _retry(backend, "poll_presentation_page_runtime",
			[1, 2, info.snapshot_id, 0, 65536])
		assert(first.keys.size() == 192 and var_to_bytes(first).size() <= int(first.page_bytes))
		keys.append(Vector3i.ZERO)
		assert((await _retry(backend, "subscribe_presentation_runtime", [1, 3, 0, keys])).error == "invalid_argument")
		assert((await _retry(backend, "unsubscribe_presentation_runtime", [1, 2])).ok)
		assert((await _retry(backend, "poll_presentation_runtime", [1])).error == "not_ready")
		assert(_call(backend, "close_runtime", []).ok)
		var deadline: int = Time.get_ticks_msec() + 5000
		while not _call(backend, "runtime_stopped", []).stopped:
			assert(Time.get_ticks_msec() < deadline)
			await process_frame
	print("FACTORY_RUNTIME_MESHING_PASS")
	quit(0)


func _call(backend: RefCounted, method: String, args: Array) -> Dictionary:
	var result: Variant = backend.callv(method, args)
	assert(result is Dictionary)
	return result as Dictionary


func _retry(backend: RefCounted, method: String, args: Array) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + 5000
	while true:
		var result: Dictionary = _call(backend, method, args)
		if result.get("error", "") != "busy":
			return result
		assert(Time.get_ticks_msec() < deadline)
		await process_frame
	return {}


func _ready(backend: RefCounted) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + 5000
	while true:
		var info: Dictionary = await _retry(backend, "poll_presentation_runtime", [1])
		assert(info.ok and info.stage != "aborted", str(info))
		if info.stage == "ready":
			return info
		assert(Time.get_ticks_msec() < deadline)
		await process_frame
	return {}


func _completed(backend: RefCounted, seq: int) -> void:
	var deadline: int = Time.get_ticks_msec() + 5000
	while true:
		var page: Dictionary = await _retry(backend, "poll_runtime", [192])
		for result: Dictionary in page.results:
			if result.request_id == seq:
				assert(result.outcome == "committed")
				return
		assert(Time.get_ticks_msec() < deadline)
		await process_frame
