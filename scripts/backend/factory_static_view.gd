class_name FactoryStaticView
extends Node3D
## Installs complete local Rust pages. The caller owns polling and physics timing.

const GRID_SHADER: Shader = preload("res://scripts/world/voxel_grid.gdshader")
const MAX_KEYS: int = 64
const MAX_BYTES: int = 8 * 1024 * 1024
const PAGE_BYTES: int = 65536
const MAX_CHUNK_PAGES: int = 256

class Chunk:
	extends RefCounted
	var body: StaticBody3D
	var mesh: ArrayMesh
	var collision: PackedVector3Array = PackedVector3Array()
	var pages: int
	var next: int = 0
	var bounds_min: Vector3
	var bounds_max: Vector3

var _info: Dictionary = {}
var _keys: Array[Vector3i] = []
var _packed_keys: PackedInt32Array = PackedInt32Array()
var _staging: Node3D
var _active: Node3D
var _chunks: Dictionary[Vector3i, Chunk] = {}
var _next_page: int = 0
var _bytes: int = 0
var _installed: Dictionary = {}
var _installed_keys: Dictionary[Vector3i, bool] = {}


func begin_snapshot(info: Dictionary, keys: Array[Vector3i]) -> bool:
	abort()
	for field: String in ["world_epoch", "view_generation", "snapshot_id", "job_id",
			"revision", "tick", "total_pages", "total_bytes"]:
		if not info.get(field) is int or _integer(info[field]) < 0:
			return false
	if info.get("stage") != "ready" or _integer(info.world_epoch) == 0 \
			or _integer(info.view_generation) == 0 or _integer(info.snapshot_id) == 0 \
			or keys.is_empty() or keys.size() > MAX_KEYS \
			or _integer(info.total_pages) < keys.size() or _integer(info.total_pages) > MAX_BYTES / 4096 \
			or _integer(info.total_bytes) < 4096 * _integer(info.total_pages) \
			or _integer(info.total_bytes) > MAX_BYTES:
		return false
	var unique: Dictionary[Vector3i, bool] = {}
	for key: Vector3i in keys:
		if unique.has(key):
			return false
		unique[key] = true
	_info = info.duplicate(true)
	_keys = keys.duplicate()
	for key: Vector3i in keys:
		_packed_keys.append_array(PackedInt32Array([key.x, key.y, key.z]))
	_staging = Node3D.new()
	_staging.name = "StaticSnapshot"
	return true


func stage_page(page: Dictionary) -> bool:
	if _staging == null or not _valid_page(page):
		abort()
		return false
	var key: Vector3i = page.key
	if not _chunks.has(key):
		if _integer(page.chunk_page) != 0 or _chunks.size() >= _keys.size() \
				or _keys[_chunks.size()] != key:
			abort()
			return false
		var body: StaticBody3D = StaticBody3D.new()
		body.name = "Chunk_%d_%d_%d" % [key.x, key.y, key.z]
		body.position = page.origin
		body.collision_layer = 0
		body.collision_mask = 0
		var visual: MeshInstance3D = MeshInstance3D.new()
		visual.name = "Mesh"
		var mesh: ArrayMesh = ArrayMesh.new()
		visual.mesh = mesh
		var material: ShaderMaterial = ShaderMaterial.new()
		material.shader = GRID_SHADER
		material.set_shader_parameter("transform_decoration_centers", true)
		material.set_shader_parameter("decoration_origin", body.position)
		material.set_shader_parameter("output_color", Color("#c9f0a1"))
		material.set_shader_parameter("input_color", Color("#81cbdc"))
		visual.material_override = material
		body.add_child(visual)
		_staging.add_child(body)
		var chunk: Chunk = Chunk.new()
		chunk.body = body
		chunk.mesh = mesh
		chunk.pages = _integer(page.chunk_pages)
		chunk.bounds_min = page.bounds_min
		chunk.bounds_max = page.bounds_max
		_chunks[key] = chunk
	var chunk: Chunk = _chunks[key]
	if chunk.next != _integer(page.chunk_page) \
			or chunk.pages != _integer(page.chunk_pages) \
			or chunk.bounds_min != page.bounds_min or chunk.bounds_max != page.bounds_max:
		abort()
		return false
	var mesh: ArrayMesh = chunk.mesh
	var positions: PackedVector3Array = page.positions
	if not positions.is_empty():
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = positions
		arrays[Mesh.ARRAY_NORMAL] = page.normals
		arrays[Mesh.ARRAY_COLOR] = page.colors
		arrays[Mesh.ARRAY_TEX_UV] = page.uv
		arrays[Mesh.ARRAY_CUSTOM0] = page.custom
		arrays[Mesh.ARRAY_INDEX] = page.indices
		var surfaces: int = mesh.get_surface_count()
		if surfaces >= MAX_CHUNK_PAGES:
			abort()
			return false
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
			Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		if mesh.get_surface_count() != surfaces + 1:
			abort()
			return false
	var collision: PackedVector3Array = chunk.collision
	var faces: PackedVector3Array = page.collision
	collision.append_array(faces)
	chunk.collision = collision
	chunk.next += 1
	if chunk.next == chunk.pages:
		var body: StaticBody3D = chunk.body
		if not collision.is_empty():
			var shape: ConcavePolygonShape3D = ConcavePolygonShape3D.new()
			shape.set_faces(collision)
			var node: CollisionShape3D = CollisionShape3D.new()
			node.name = "Collision"
			node.shape = shape
			body.add_child(node)
		else:
			body.free()
	_bytes += _integer(page.page_bytes)
	_next_page += 1
	if _next_page == _integer(_info.total_pages) and not prepared():
		abort()
		return false
	return true


func _valid_page(page: Dictionary) -> bool:
	for field: String in ["world_epoch", "view_generation", "snapshot_id", "job_id",
			"revision", "tick", "total_pages"]:
		if page.get(field) != _info.get(field):
			return false
	for field: String in ["page_index", "chunk_page", "chunk_pages", "page_bytes", "world_revision"]:
		if not page.get(field) is int:
			return false
	if _integer(page.page_index) != _next_page or _integer(page.chunk_page) < 0 \
			or _integer(page.chunk_pages) < 1 or _integer(page.chunk_page) >= _integer(page.chunk_pages) \
			or _integer(page.chunk_pages) > MAX_CHUNK_PAGES \
			or _integer(page.world_revision) != _integer(_info.revision) \
			or _integer(page.page_bytes) < 4096 or _integer(page.page_bytes) > PAGE_BYTES \
			or _bytes + _integer(page.page_bytes) > _integer(_info.total_bytes):
		return false
	if not page.get("key") is Vector3i or not page.get("keys") is PackedInt32Array \
			or page.keys != _packed_keys:
		return false
	for field: String in ["origin", "bounds_min", "bounds_max"]:
		var value: Variant = page.get(field)
		if not value is Vector3:
			return false
		var vector: Vector3 = value
		if not vector.is_finite():
			return false
	var key: Vector3i = page.key
	if not _keys.has(key) or page.origin != Vector3(key) * 4.0:
		return false
	if not page.get("positions") is PackedVector3Array or not page.get("normals") is PackedVector3Array \
			or not page.get("colors") is PackedColorArray or not page.get("uv") is PackedVector2Array \
			or not page.get("custom") is PackedFloat32Array or not page.get("indices") is PackedInt32Array \
			or not page.get("collision") is PackedVector3Array:
		return false
	var positions: PackedVector3Array = page.positions
	var normals: PackedVector3Array = page.normals
	var colors: PackedColorArray = page.colors
	var uv: PackedVector2Array = page.uv
	var custom: PackedFloat32Array = page.custom
	var indices: PackedInt32Array = page.indices
	var collision: PackedVector3Array = page.collision
	if positions.size() > 512 or positions.size() % 4 != 0 or indices.size() > 768 \
			or indices.size() != positions.size() / 4 * 6 or collision.size() != indices.size() \
			or normals.size() != positions.size() or colors.size() != positions.size() \
			or uv.size() != positions.size() or custom.size() != positions.size() * 4 \
			or _integer(page.page_bytes) != 4096 + positions.size() / 4 * 352:
		return false
	if positions.is_empty() and (_integer(page.chunk_pages) != 1 or _integer(page.chunk_page) != 0):
		return false
	var low: Vector3 = page.bounds_min
	var high: Vector3 = page.bounds_max
	if low.x > high.x or low.y > high.y or low.z > high.z:
		return false
	for index: int in range(positions.size()):
		var p: Vector3 = positions[index]
		var c: Color = colors[index]
		if not p.is_finite() or not normals[index].is_finite() or not uv[index].is_finite() \
				or not is_finite(c.r) or not is_finite(c.g) or not is_finite(c.b) or not is_finite(c.a) \
				or p.x < low.x or p.y < low.y or p.z < low.z \
				or p.x > high.x or p.y > high.y or p.z > high.z:
			return false
	for value: float in custom:
		if not is_finite(value):
			return false
	for index: int in range(indices.size()):
		if indices[index] < 0 or indices[index] >= positions.size() \
				or collision[index] != positions[indices[index]]:
			return false
	return true


func prepared() -> bool:
	if _staging == null or _next_page != _integer(_info.total_pages) or _chunks.size() != _keys.size() \
			or _bytes != _integer(_info.total_bytes):
		return false
	for chunk: Chunk in _chunks.values():
		if chunk.next != chunk.pages:
			return false
	return true


func activate(epoch: int, snapshot: int) -> bool:
	if not prepared() or epoch != _integer(_info.world_epoch) or snapshot != _integer(_info.snapshot_id):
		return false
	if _active != null:
		_active.free()
	_active = _staging
	_staging = null
	for child: Node in _active.get_children():
		var body: StaticBody3D = child as StaticBody3D
		body.collision_layer = 1
	add_child(_active)
	_installed = _info.duplicate(true)
	_installed_keys.clear()
	for key: Vector3i in _keys:
		_installed_keys[key] = true
	_clear_staging_state()
	return true


func covers_sweep(start: Vector3, end: Vector3, radius: Vector3,
		epoch: int, revision: int) -> bool:
	if epoch != _integer(_installed.get("world_epoch", 0)) \
			or revision != _integer(_installed.get("revision", -1)) \
			or not start.is_finite() or not end.is_finite() or not radius.is_finite() \
			or radius.x < 0 or radius.y < 0 or radius.z < 0 \
			or not global_transform.origin.is_finite() \
			or not global_transform.basis.x.is_finite() or not global_transform.basis.y.is_finite() \
			or not global_transform.basis.z.is_finite() \
			or absf(global_transform.basis.determinant()) < 0.00001:
		return false
	var box: AABB = AABB(start.min(end) - radius, start.max(end) - start.min(end) + radius * 2)
	var local: AABB = global_transform.affine_inverse() * box
	if not local.position.is_finite() or not local.size.is_finite() or not local.end.is_finite():
		return false
	var grid_low: Vector3 = (local.position / 4.0).floor()
	var grid_high: Vector3 = (local.end / 4.0).floor()
	if not _valid_grid_point(grid_low) or not _valid_grid_point(grid_high):
		return false
	var low: Vector3i = Vector3i(grid_low)
	var high: Vector3i = Vector3i(grid_high)
	var size: Vector3i = high - low + Vector3i.ONE
	if size.x < 1 or size.y < 1 or size.z < 1 \
			or size.x > MAX_KEYS or size.y > MAX_KEYS or size.z > MAX_KEYS \
			or size.x * size.y * size.z > MAX_KEYS:
		return false
	for x: int in range(low.x, high.x + 1):
		for y: int in range(low.y, high.y + 1):
			for z: int in range(low.z, high.z + 1):
				if not _installed_keys.has(Vector3i(x, y, z)):
					return false
	return true


func abort() -> void:
	if _staging != null:
		_staging.free()
		_staging = null
	_clear_staging_state()


func _clear_staging_state() -> void:
	_info = {}
	_keys.clear()
	_packed_keys.clear()
	_chunks.clear()
	_next_page = 0
	_bytes = 0


func _exit_tree() -> void:
	abort()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		abort()


static func _valid_grid_point(point: Vector3) -> bool:
	return point.is_finite() and point.x >= -2147483648.0 and point.x <= 2147483647.0 \
		and point.y >= -2147483648.0 and point.y <= 2147483647.0 \
		and point.z >= -2147483648.0 and point.z <= 2147483647.0


static func _integer(value: Variant) -> int:
	if value is int:
		return value
	return 0
