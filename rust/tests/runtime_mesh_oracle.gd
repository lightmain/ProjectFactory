extends SceneTree
## Real bridge values compared with the current independent Godot face builder.

const DIRECTIONS: Array[Vector3i] = [Vector3i.BACK, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.RIGHT]
var _backend: RefCounted


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	_backend = ClassDB.instantiate(&"FactoryBackend") as RefCounted
	assert(_backend != null and _backend.has_method("subscribe_presentation_runtime"))
	assert(_call("open_backend", [{"api_version": 1}]).ok)
	for ruleset: String in ["legacy_discrete_v1", "conveyor_continuous_v1"]:
		await _geometry(ruleset)
		await _candidate(ruleset)
	assert(_call("close_backend", []).ok)
	print("FACTORY_RUNTIME_MESH_ORACLE_PASS")
	quit(0)


func _options(ruleset: String) -> Dictionary:
	return {"epoch": 1, "ruleset": ruleset, "minimum": Vector3i(-32, -4, -32),
		"maximum": Vector3i(48, 60, 32), "floor_depth": 4, "interval": 0.1, "amount": 1}


func _geometry(ruleset: String) -> void:
	assert(_call("open_runtime", [_options(ruleset)]).ok)
	var world: VoxelWorldData = VoxelWorldData.new()
	assert(world.generate_flat(Vector3i(-32, -4, -32), Vector3i(48, 60, 32), 4))
	var cells: Array[Vector3i] = []
	var blocks: PackedInt32Array = PackedInt32Array()
	var directions: PackedInt32Array = PackedInt32Array()
	var facing: Dictionary[Vector3i, Vector3i] = {}
	for index: int in range(14):
		var block: int = [1, 2, 3, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 16][index]
		var cell: Vector3i = Vector3i(-7 + index * 2, 2, -1 if index % 2 == 0 else 2)
		var direction: Vector3i = VoxelWorldData.slope_direction(block) \
			if VoxelWorldData.is_slope(block) else Vector3i.RIGHT
		assert(world.place_block(cell, block))
		cells.append(cell)
		blocks.append(block)
		directions.append(DIRECTIONS.find(direction))
		facing[cell] = direction
	# A real neighboring edit must remove the cross-chunk stone face.
	cells.append(Vector3i(7, 2, 5))
	blocks.append(3)
	directions.append(3)
	assert(world.place_block(cells[-1], 3))
	cells.append(Vector3i(7, 4, 9))
	blocks.append(8)
	directions.append(3)
	assert(world.place_structure(Vector3i(7, 4, 9), 3))
	await _run(1, {"request_id": 1, "kind": "build",
		"cells": cells, "blocks": blocks, "directions": directions})
	var keys: Array[Vector3i] = [Vector3i(-1, 0, -1), Vector3i(-1, 0, 0),
		Vector3i(0, 0, 0), Vector3i(1, 0, -1), Vector3i(1, 0, 0),
		Vector3i(2, 0, -1), Vector3i(2, 0, 0), Vector3i(0, 0, 1),
		Vector3i(1, 0, 1), Vector3i(-2, 0, -2)]
	var first: Dictionary = await _compare_round(1, 1, 0, keys, world, facing)
	var edit: Dictionary = {"request_id": 2, "kind": "build", "cells": [Vector3i(8, 2, 5)],
		"blocks": PackedInt32Array([3]), "directions": PackedInt32Array([3])}
	await _run(1, edit)
	assert(world.place_block(Vector3i(8, 2, 5), 3))
	var updated: Dictionary = await _compare_round(1, 1, 0, keys, world, facing)
	assert(updated.snapshot_id > first.snapshot_id and updated.revision > first.revision)
	# Miner at index 3 is isolated; all four port directions must cross intact.
	var machine: Vector3i = cells[3]
	for direction: int in range(4):
		await _run(1, {"request_id": direction + 3, "kind": "direction",
			"cell": machine, "direction": direction})
		facing[machine] = DIRECTIONS[direction]
		await _compare_round(1, 1, 0, keys, world, facing)
	await _stop()


func _compare_round(epoch: int, generation: int, job: int, keys: Array[Vector3i],
		world: VoxelWorldData, facing: Dictionary[Vector3i, Vector3i]) -> Dictionary:
	assert((await _retry("subscribe_presentation_runtime", [epoch, generation, job, keys])).ok)
	var info: Dictionary = await _ready(epoch)
	assert(info.world_epoch == epoch and info.view_generation == generation and info.job_id == job)
	var packed_keys: PackedInt32Array = PackedInt32Array()
	var expected: Dictionary[Vector3i, Array] = {}
	var offsets: Dictionary[Vector3i, int] = {}
	for key: Vector3i in keys:
		packed_keys.append_array(PackedInt32Array([key.x, key.y, key.z]))
		expected[key] = _reference(world, key, facing)
		offsets[key] = 0
	var installer: FactoryStaticView = FactoryStaticView.new()
	root.add_child(installer)
	assert(installer.begin_snapshot(info, keys))
	var bytes: int = 0
	var key_index: int = 0
	var chunk_page: int = 0
	for index: int in range(int(info.total_pages)):
		var page: Dictionary = await _retry("poll_presentation_page_runtime",
			[epoch, generation, info.snapshot_id, index, 65536])
		assert(page.ok and page.keys == packed_keys and page.key == keys[key_index])
		assert(page.world_epoch == epoch and page.view_generation == generation and page.job_id == job)
		assert(page.snapshot_id == info.snapshot_id and page.revision == info.revision \
			and page.world_revision == info.revision and page.tick == info.tick)
		assert(page.page_index == index and page.total_pages == info.total_pages and page.chunk_page == chunk_page)
		var key: Vector3i = page.key
		var arrays: Array = expected[key]
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var expected_pages: int = maxi(1, ceili(float(vertices.size()) / (128 * 6)))
		assert(page.chunk_pages == expected_pages)
		var origin: Vector3 = Vector3(key) * 4
		assert(page.origin == origin)
		var low: Vector3 = Vector3.ZERO if vertices.is_empty() else vertices[0] - origin
		var high: Vector3 = low
		for vertex: Vector3 in vertices:
			low = low.min(vertex - origin)
			high = high.max(vertex - origin)
		assert((page.bounds_min as Vector3).is_equal_approx(low))
		assert((page.bounds_max as Vector3).is_equal_approx(high))
		var indices: PackedInt32Array = page.indices
		var positions: PackedVector3Array = page.positions
		var normals: PackedVector3Array = page.normals
		var colors: PackedColorArray = page.colors
		var uv: PackedVector2Array = page.uv
		var custom: PackedFloat32Array = page.custom
		var collision: PackedVector3Array = page.collision
		var reference_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var reference_colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var reference_uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var reference_custom: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
		for triangle: int in range(indices.size()):
			var vertex: int = indices[triangle]
			var reference: int = offsets[key] + triangle
			assert(reference < vertices.size())
			assert((positions[vertex] + origin).is_equal_approx(vertices[reference]))
			assert(normals[vertex].is_equal_approx(reference_normals[reference]))
			assert(colors[vertex].is_equal_approx(reference_colors[reference]))
			assert(uv[vertex].is_equal_approx(reference_uv[reference]),
				"key=%s triangle=%d uv=%s expected=%s" % [key, reference, uv[vertex], reference_uv[reference]])
			for component: int in range(4):
				assert(absf(custom[vertex * 4 + component] - reference_custom[reference * 4 + component]) < 0.00002)
			assert(collision[triangle] == positions[vertex])
		if vertices.is_empty():
			assert(positions.is_empty() and indices.is_empty() and collision.is_empty() and page.page_bytes == 4096)
		offsets[key] += indices.size()
		bytes += int(page.page_bytes)
		assert(installer.stage_page(page))
		chunk_page += 1
		if chunk_page == expected_pages:
			assert(offsets[key] == vertices.size())
			key_index += 1
			chunk_page = 0
	assert(key_index == keys.size() and bytes == info.total_bytes and installer.prepared())
	assert((await _retry("ack_presentation_runtime", [epoch, generation, info.snapshot_id])).ok)
	assert(installer.activate(epoch, int(info.snapshot_id)))
	installer.free()
	return info


func _reference(world: VoxelWorldData, key: Vector3i, facing: Dictionary[Vector3i, Vector3i]) -> Array:
	var view: VoxelWorldView = VoxelWorldView.new()
	view.set("_world", world)
	var surface: SurfaceTool = SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
	var start: Vector3i = key * 8
	var faces: int = 0
	for x: int in range(start.x, start.x + 8):
		for y: int in range(start.y, start.y + 8):
			for z: int in range(start.z, start.z + 8):
				var cell: Vector3i = Vector3i(x, y, z)
				var block: int = world.get_block(cell)
				if block == 0:
					continue
				var bounds: AABB = VoxelWorldData.block_bounds(cell, block)
				for normal: Vector3i in VoxelWorldView.FACE_NORMALS:
					if not view._face_covered(cell, normal, bounds):
						VoxelWorldView._add_face(surface, cell, normal, block, bounds,
							facing.get(cell, Vector3i.ZERO) if LogisticsData.is_machine(block) else Vector3i.ZERO)
						faces += 1
	view.free()
	if faces == 0:
		var empty: Array = []
		empty.resize(Mesh.ARRAY_MAX)
		empty[Mesh.ARRAY_VERTEX] = PackedVector3Array()
		empty[Mesh.ARRAY_NORMAL] = PackedVector3Array()
		empty[Mesh.ARRAY_COLOR] = PackedColorArray()
		empty[Mesh.ARRAY_TEX_UV] = PackedVector2Array()
		empty[Mesh.ARRAY_CUSTOM0] = PackedFloat32Array()
		return empty
	return surface.commit_to_arrays()


func _candidate(ruleset: String) -> void:
	var path: String = ProjectSettings.globalize_path("user://mesh_candidate_" + str(Time.get_ticks_usec()))
	var options: Dictionary = _options(ruleset)
	options["save_root"] = path
	assert(_call("open_runtime", [options]).ok)
	var player: Dictionary = {"frame": 1, "position": Vector3(20.25, 1, 0.25), "velocity": Vector3.ZERO,
		"spawn": Vector3(20.25, 1, 0.25), "body_rotation": Vector3.ZERO, "rotation": Vector3.ZERO,
		"tool": 7, "build_rotation": 3, "free_view": false,
		"free_position": Vector3.ZERO, "free_rotation": Vector3.ZERO}
	await _run(1, {"request_id": 1, "kind": "build", "cells": [Vector3i(40, 0, 0)],
		"blocks": PackedInt32Array([7]), "directions": PackedInt32Array([3])})
	await _run(1, {"request_id": 2, "kind": "frame", "frame_seq": 1, "delta": 0.035})
	await _run(1, {"request_id": 3, "kind": "pause"})
	assert((await _run(1,
		{"request_id": 4, "kind": "save", "player": player, "world_id": "09090909090909090909090909090909",
			"world_name": "候选几何", "autosave_minutes": 5.0, "retention": 3,
			"name": "候选", "overwrite": false, "save_kind": "manual", "sequence": 0})).outcome == "save_started")
	var saved: Dictionary = await _completion(4)
	var save_id: String = saved.save_id
	await _stop()
	options["maximum"] = Vector3i(32, 60, 32)
	assert(_call("open_runtime", [options]).ok)
	await _run(1, {"request_id": 1, "kind": "pause"})
	var prepared: Dictionary = await _run(1, {"request_id": 2, "kind": "prepare_load", "save_id": save_id})
	assert(prepared.outcome == "load_prepared")
	var description: Dictionary = await _retry("poll_candidate_runtime", [1, 2, 704])
	var world: VoxelWorldData = VoxelWorldData.new()
	assert(world.generate_flat(Vector3i(-32, -4, -32), Vector3i(48, 60, 32), 4))
	assert(world.place_block(Vector3i(40, 0, 0), 7))
	var keys: Array[Vector3i] = [Vector3i(5, 0, 0)]
	assert((await _retry("subscribe_presentation_runtime", [1, 1, 0, keys])).error == "invalid_argument")
	var info: Dictionary = await _compare_round(1, 1, 2, keys, world, {Vector3i(40, 0, 0): Vector3i.RIGHT})
	assert(info.revision == description.revision and info.tick == description.tick)
	assert((await _retry("cancel_runtime", [1, 2])).cancelled)
	var cancelled: Dictionary = await _completion(2)
	assert(cancelled.outcome == "load_failed" and cancelled.error == "cancelled")
	assert((await _retry("poll_presentation_page_runtime", [1, 1, info.snapshot_id, 0, 65536])).error == "not_ready")
	assert((await _retry("ack_presentation_runtime", [1, 1, info.snapshot_id])).error == "not_ready")
	prepared = await _run(1, {"request_id": 3, "kind": "prepare_load", "save_id": save_id})
	info = await _compare_round(1, 2, 3, keys, world, {Vector3i(40, 0, 0): Vector3i.RIGHT})
	var decided: Dictionary = await _run(1, {"request_id": 4, "kind": "ready", "job_id": 3})
	assert(decided.outcome == "commit_decided")
	var switched: Dictionary = await _run(1, {"request_id": 5, "kind": "switch", "job_id": 3, "next_epoch": 2})
	assert(switched.world_epoch == 2 and switched.outcome == "load_completed")
	assert((await _retry("poll_presentation_page_runtime", [1, 2, info.snapshot_id, 0, 65536])).error == "stale_epoch")
	assert((await _retry("ack_presentation_runtime", [1, 2, info.snapshot_id])).error == "stale_epoch")
	assert((await _retry("poll_presentation_runtime", [2])).error == "not_ready")
	var active: Dictionary = await _compare_round(2, 1, 0, keys, world, {Vector3i(40, 0, 0): Vector3i.RIGHT})
	assert(active.revision == info.revision and active.tick == info.tick)
	await _stop()
	var directory: DirAccess = DirAccess.open(path)
	assert(directory != null)
	for file: String in directory.get_files():
		assert(directory.remove(file) == OK)
	directory = null
	assert(DirAccess.remove_absolute(path) == OK)


func _call(method: String, args: Array) -> Dictionary:
	var result: Variant = _backend.callv(method, args)
	assert(result is Dictionary)
	return result as Dictionary


func _retry(method: String, args: Array) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + 5000
	while true:
		var result: Dictionary = _call(method, args)
		if result.get("error", "") != "busy":
			return result
		assert(Time.get_ticks_msec() < deadline, method)
		await process_frame
	return {}


func _ready(epoch: int) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + 5000
	while true:
		var info: Dictionary = await _retry("poll_presentation_runtime", [epoch])
		assert(info.ok and info.stage != "aborted", str(info))
		if info.stage == "ready":
			return info
		assert(Time.get_ticks_msec() < deadline)
		await process_frame
	return {}


func _completion(request: int) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + 5000
	while true:
		var page: Dictionary = await _retry("poll_runtime", [96])
		assert(page.ok)
		if not page.results.is_empty():
			assert(page.results.size() == 1 and page.results[0].request_id == request)
			return page.results[0]
		assert(Time.get_ticks_msec() < deadline)
		await process_frame
	return {}


func _run(epoch: int, command: Dictionary) -> Dictionary:
	assert((await _retry("submit_runtime", [epoch, command])).ok)
	return await _completion(int(command.request_id))


func _stop() -> void:
	assert(_call("close_runtime", []).ok)
	var deadline: int = Time.get_ticks_msec() + 5000
	while not _call("runtime_stopped", []).stopped:
		assert(Time.get_ticks_msec() < deadline)
		await process_frame
