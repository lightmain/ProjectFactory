extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var backend: RefCounted = ClassDB.instantiate(&"FactoryBackend") as RefCounted
	assert(backend != null and backend.has_method("request_display_runtime"))
	assert(_call(backend, "open_backend", [{"api_version": 1}]).ok)
	for rules: String in ["legacy_discrete_v1", "conveyor_continuous_v1"]:
		assert(_call(backend, "open_runtime", [{"epoch": 1, "ruleset": rules,
			"minimum": Vector3i(-8, -3, -8), "maximum": Vector3i(9, 12, 9),
			"floor_depth": 3, "interval": 0.1, "amount": 1}]).ok)
		await _run(backend, {"request_id": 1, "kind": "build",
			"cells": [Vector3i.ZERO, Vector3i.RIGHT, Vector3i(2, 0, 0)],
			"blocks": PackedInt32Array([5, 6, 7]), "directions": PackedInt32Array([3, 3, 3])})
		for frame: int in range(1, 25):
			await _run(backend, {"request_id": frame + 1, "kind": "frame", "frame_seq": frame, "delta": 0.05})
		assert((await _retry(backend, "request_display_runtime", [1, 1, [Vector3i.ZERO]])).ok)
		var info: Dictionary = await _retry(backend, "poll_display_runtime", [1, 1])
		var page: Dictionary = await _retry(backend, "poll_display_page_runtime", [1, 1, info.snapshot_id, 0, 65536])
		assert(page.cells is PackedInt32Array and page.quantities is PackedInt64Array)
		assert(page.transforms is PackedFloat32Array and page.ore_ids is PackedInt64Array)
		assert(page.cells.size() == 9 and page.ore_ids.size() > 0)
		assert(page.transforms.size() == page.ore_ids.size() * 12)
		assert(page.page_bytes == 256 + page.quantities.size() * 40 + page.ore_ids.size() * 56)
		assert(_call(backend, "request_display_runtime", [1, 2, [Vector3i.ZERO]]).error == "busy")
		assert((await _retry(backend, "poll_display_page_runtime", [1, 1, info.snapshot_id, 0, page.page_bytes - 1])).error == "invalid_argument")
		assert((await _retry(backend, "release_display_runtime", [1, 1])).ok)
		var pose: Dictionary = {"frame": 1, "player_min": Vector3(3, 0.05, 3),
			"player_max": Vector3(3.3, 1.85, 3.3), "margin": 0.001, "free_view": false}
		var prepared: Dictionary = await _run(backend, {"request_id": 26, "kind": "prepare_build",
			"cells": [Vector3i(0, 0, 2)], "blocks": PackedInt32Array([7]),
			"directions": PackedInt32Array([3]), "pose": pose})
		assert(prepared.outcome == "build_prepared" and prepared.token == 26)
		assert((await _run(backend, {"request_id": 27, "kind": "confirm_build",
			"token": prepared.token, "pose": pose, "engine_clear": true})).outcome == "build_committed")
		_call(backend, "close_runtime")
		while not _call(backend, "runtime_stopped").stopped:
			await process_frame
		await _check_multipage(backend, rules)
		await _check_slopes(backend, rules)
	_call(backend, "close_backend")
	print("FACTORY_RUNTIME_DISPLAY_PASS")
	quit()


func _check_multipage(backend: RefCounted, rules: String) -> void:
	assert(_call(backend, "open_runtime", [{"epoch": 1, "ruleset": rules,
		"minimum": Vector3i(0, -3, 0), "maximum": Vector3i(8, 8, 32),
		"floor_depth": 3, "interval": 0.1, "amount": 1}]).ok)
	var expected: Dictionary[Vector3i, bool] = {}
	var request_id: int = 1
	for x: int in range(8):
		for chunk_z: int in range(4):
			var cells: Array[Vector3i] = []
			var blocks: PackedInt32Array = PackedInt32Array()
			var directions: PackedInt32Array = PackedInt32Array()
			for y: int in range(8):
				for local_z: int in range(8):
					var cell: Vector3i = Vector3i(x, y, chunk_z * 8 + local_z)
					cells.append(cell)
					blocks.append(7)
					directions.append(0)
					expected[cell] = true
			assert((await _run(backend, {"request_id": request_id, "kind": "build",
				"cells": cells, "blocks": blocks, "directions": directions})).outcome == "committed")
			request_id += 1
	var keys: Array[Vector3i] = [Vector3i.ZERO, Vector3i(0, 0, 1),
		Vector3i(0, 0, 2), Vector3i(0, 0, 3)]
	assert((await _retry(backend, "request_display_runtime", [1, 1, keys])).ok)
	var info: Dictionary = await _retry(backend, "poll_display_runtime", [1, 1])
	assert(info.ok and info.world_epoch == 1 and info.view_generation == 1)
	assert(info.snapshot_id > 0 and info.total_pages == 2)
	assert(info.total_bytes == 2 * 256 + 2048 * 40 and info.total_bytes <= 1024 * 1024)
	var first: Dictionary = await _retry(backend, "poll_display_page_runtime",
		[1, 1, info.snapshot_id, 0, 65536])
	# Later pages must still describe the round captured before this edit and tick.
	assert((await _run(backend, {"request_id": request_id, "kind": "remove",
		"cell": Vector3i.ZERO})).outcome == "committed")
	request_id += 1
	assert((await _run(backend, {"request_id": request_id, "kind": "frame",
		"frame_seq": 1, "delta": 0.05})).outcome == "frame_completed")
	var members: Dictionary[Vector3i, bool] = {}
	var total_bytes: int = 0
	for index: int in range(info.total_pages):
		var page: Dictionary = await _retry(backend, "poll_display_page_runtime",
			[1, 1, info.snapshot_id, index, 65536])
		_check_page(page, info, index)
		if index == 0:
			assert(page == first)
		assert(page.ore_ids.is_empty())
		total_bytes += int(page.page_bytes)
		for row: int in range(page.quantities.size()):
			var cell: Vector3i = Vector3i(page.cells[row * 3],
				page.cells[row * 3 + 1], page.cells[row * 3 + 2])
			assert(expected.has(cell) and not members.has(cell))
			assert(page.blocks[row] == 7 and page.directions[row] == 0 and page.quantities[row] == 0)
			members[cell] = true
	assert(members.size() == expected.size() and total_bytes == info.total_bytes)
	assert((await _retry(backend, "release_display_runtime", [1, 1])).ok)
	assert((await _retry(backend, "request_display_runtime", [1, 2, keys])).ok)
	var next: Dictionary = await _retry(backend, "poll_display_runtime", [1, 2])
	assert(next.ok and next.snapshot_id != info.snapshot_id)
	assert(next.tick > info.tick and next.revision > info.revision)
	assert(next.total_bytes == 2 * 256 + 2047 * 40)
	assert((await _retry(backend, "poll_display_page_runtime",
		[1, 2, info.snapshot_id, 0, 65536])).error == "invalid_argument")
	assert((await _retry(backend, "release_display_runtime", [1, 2])).ok)
	await _stop_runtime(backend)


func _check_slopes(backend: RefCounted, rules: String) -> void:
	assert(_call(backend, "open_runtime", [{"epoch": 1, "ruleset": rules,
		"minimum": Vector3i(-8, -3, -8), "maximum": Vector3i(8, 8, 8),
		"floor_depth": 3, "interval": 0.1, "amount": 1}]).ok)
	assert((await _run(backend, {"request_id": 1, "kind": "build",
		"cells": [Vector3i.ZERO, Vector3i(1, 0, 0), Vector3i(2, 1, 0),
			Vector3i(3, 0, 0), Vector3i(4, 0, 0)],
		"blocks": PackedInt32Array([5, 12, 6, 16, 7]),
		"directions": PackedInt32Array([3, 3, 3, 3, 3])})).outcome == "committed")
	var saw_uphill: bool = false
	var saw_downhill: bool = false
	var saw_delivery: bool = false
	for frame: int in range(1, 49):
		assert((await _run(backend, {"request_id": frame + 1, "kind": "frame",
			"frame_seq": frame, "delta": 4.0 / 60.0})).outcome == "frame_completed")
		if frame % 4 != 0:
			continue
		assert((await _retry(backend, "request_display_runtime", [1, frame, [Vector3i.ZERO]])).ok)
		var info: Dictionary = await _retry(backend, "poll_display_runtime", [1, frame])
		assert(info.ok and info.total_pages == 1)
		var page: Dictionary = await _retry(backend, "poll_display_page_runtime",
			[1, frame, info.snapshot_id, 0, 65536])
		_check_page(page, info, 0)
		assert(page.quantities.size() == 5)
		var ids: Dictionary[int, bool] = {}
		for ore: int in range(page.ore_ids.size()):
			var id: int = page.ore_ids[ore]
			assert(id > 0 and not ids.has(id))
			ids[id] = true
			var offset: int = ore * 12
			var x: float = page.transforms[offset + 3]
			var y: float = page.transforms[offset + 7]
			var z: float = page.transforms[offset + 11]
			assert(absf(z - 0.25) < 0.00001)
			for component: int in [0, 5, 10]:
				assert(page.transforms[offset + component] == 1.0)
			for component: int in [1, 2, 4, 6, 8, 9]:
				assert(page.transforms[offset + component] == 0.0)
			if x > 0.50001 and x < 0.99999:
				assert(absf(y - (x - 0.5 + 0.125)) < 0.00001)
				saw_uphill = true
			elif x > 1.50001 and x < 1.99999:
				assert(absf(y - (2.0 - x + 0.125)) < 0.00001)
				saw_downhill = true
		for row: int in range(page.quantities.size()):
			if page.cells[row * 3] == 4:
				saw_delivery = saw_delivery or page.quantities[row] > 0
		assert((await _retry(backend, "release_display_runtime", [1, frame])).ok)
	assert(saw_uphill and saw_downhill and saw_delivery)
	await _stop_runtime(backend)


func _check_page(page: Dictionary, info: Dictionary, index: int) -> void:
	assert(page.ok and page.page_index == index)
	for field: String in ["world_epoch", "view_generation", "snapshot_id", "tick",
			"revision", "total_pages", "total_bytes"]:
		assert(page[field] == info[field])
	for field: String in ["cells", "blocks", "directions", "inputs", "outputs"]:
		assert(page[field] is PackedInt32Array)
	assert(page.quantities is PackedInt64Array and page.ore_ids is PackedInt64Array)
	assert(page.transforms is PackedFloat32Array)
	var count: int = page.quantities.size()
	assert(page.cells.size() == count * 3)
	for field: String in ["blocks", "directions", "inputs", "outputs"]:
		assert(page[field].size() == count)
	assert(page.transforms.size() == page.ore_ids.size() * 12)
	assert(page.page_bytes == 256 + count * 40 + page.ore_ids.size() * 56)
	assert(page.page_bytes <= 65536)
	for row: int in range(count):
		assert(page.quantities[row] >= 0)
		assert(page.inputs[row] >= 0 and page.inputs[row] < 16)
		assert(page.outputs[row] >= 0 and page.outputs[row] < 16)


func _stop_runtime(backend: RefCounted) -> void:
	_call(backend, "close_runtime")
	var deadline: int = Time.get_ticks_msec() + 5000
	while not _call(backend, "runtime_stopped").stopped:
		assert(Time.get_ticks_msec() < deadline)
		await process_frame


func _call(backend: RefCounted, method: String, args: Array = []) -> Dictionary:
	return backend.callv(method, args) as Dictionary


func _retry(backend: RefCounted, method: String, args: Array) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + 5000
	while true:
		var response: Dictionary = _call(backend, method, args)
		if response.get("error", "") not in ["busy", "not_ready"]:
			return response
		assert(Time.get_ticks_msec() < deadline)
		await process_frame
	return {}


func _run(backend: RefCounted, command: Dictionary) -> Dictionary:
	assert((await _retry(backend, "submit_runtime", [1, command])).ok)
	var deadline: int = Time.get_ticks_msec() + 5000
	while true:
		var page: Dictionary = await _retry(backend, "poll_runtime", [192])
		if not page.results.is_empty():
			return page.results[0]
		assert(Time.get_ticks_msec() < deadline)
		await process_frame
	return {}
