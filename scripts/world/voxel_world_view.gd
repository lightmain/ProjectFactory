class_name VoxelWorldView
extends Node3D
## Chunked visible faces and collision. All geometry is in world coordinates.

const CHUNK_SIZE: int = 8
const FACE_NORMALS: Array[Vector3i] = [
	Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP,
	Vector3i.DOWN, Vector3i.BACK, Vector3i.FORWARD,
]
const GRID_SHADER: Shader = preload("res://scripts/world/voxel_grid.gdshader")

var _world: VoxelWorldData
var _chunks: Dictionary[Vector3i, StaticBody3D] = {}
var _pending: Dictionary[Vector3i, bool] = {}
var _material: ShaderMaterial


func bind_world(world: VoxelWorldData) -> void:
	if _world != null:
		_world.cell_changed.disconnect(_on_cell_changed)
		_world.world_reset.disconnect(_on_world_reset)
	_world = world
	_material = ShaderMaterial.new()
	_material.shader = GRID_SHADER
	_world.cell_changed.connect(_on_cell_changed)
	_world.world_reset.connect(_on_world_reset)
	_on_world_reset()


func _ready() -> void:
	# Run before default-priority player physics, including multiple ticks per render.
	process_physics_priority = -100


func _physics_process(_delta: float) -> void:
	rebuild_pending()


func rebuild_pending() -> void:
	for chunk: Vector3i in _pending.keys():
		_rebuild_chunk(chunk)
	_pending.clear()


static func _chunk_for(cell: Vector3i) -> Vector3i:
	return Vector3i((Vector3(cell) / float(CHUNK_SIZE)).floor())


func _on_world_reset() -> void:
	for chunk: StaticBody3D in _chunks.values():
		chunk.free()
	_chunks.clear()
	_pending.clear()
	for cell: Vector3i in _world.solid_cells():
		_pending[_chunk_for(cell)] = true
	rebuild_pending()


func _on_cell_changed(cell: Vector3i) -> void:
	_pending[_chunk_for(cell)] = true
	for normal: Vector3i in FACE_NORMALS:
		_pending[_chunk_for(cell + normal)] = true


func _rebuild_chunk(chunk: Vector3i) -> void:
	if _chunks.has(chunk):
		_chunks[chunk].free()
		_chunks.erase(chunk)
	var surface: SurfaceTool = SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var face_count: int = 0
	var start: Vector3i = chunk * CHUNK_SIZE
	for x: int in range(start.x, start.x + CHUNK_SIZE):
		for y: int in range(start.y, start.y + CHUNK_SIZE):
			for z: int in range(start.z, start.z + CHUNK_SIZE):
				var cell: Vector3i = Vector3i(x, y, z)
				var block: int = _world.get_block(cell)
				if block == VoxelWorldData.Block.AIR:
					continue
				for normal: Vector3i in FACE_NORMALS:
					if _world.get_block(cell + normal) == VoxelWorldData.Block.AIR:
						_add_face(surface, cell, normal, block)
						face_count += 1
	if face_count == 0:
		return
	var mesh: ArrayMesh = surface.commit()
	var body: StaticBody3D = StaticBody3D.new()
	body.name = "Chunk_%d_%d_%d" % [chunk.x, chunk.y, chunk.z]
	body.collision_layer = 1
	body.collision_mask = 0
	var visual: MeshInstance3D = MeshInstance3D.new()
	visual.name = "Mesh"
	visual.mesh = mesh
	visual.material_override = _material
	body.add_child(visual)
	var collision: CollisionShape3D = CollisionShape3D.new()
	collision.name = "Collision"
	collision.shape = mesh.create_trimesh_shape()
	body.add_child(collision)
	add_child(body)
	_chunks[chunk] = body


static func _add_face(surface: SurfaceTool, cell: Vector3i, normal: Vector3i, block: int) -> void:
	var u: Vector3 = Vector3(normal).cross(Vector3.UP)
	var v: Vector3 = Vector3.UP
	if normal.y != 0:
		u = Vector3.RIGHT
		v = Vector3.BACK if normal.y > 0 else Vector3.FORWARD
	var center: Vector3 = VoxelWorldData.cell_center(cell) + Vector3(normal) * 0.25
	var corners: Array[Vector3] = [
		center + (-u - v) * 0.25, center + (u - v) * 0.25,
		center + (u + v) * 0.25, center + (-u + v) * 0.25,
	]
	var color: Color = _face_color(block, normal)
	# A small deterministic variation makes individual voxels readable.
	var variation: float = 0.94 + float(posmod(cell.x * 31 + cell.y * 17 + cell.z * 13, 11)) * 0.01
	color = Color(color.r * variation, color.g * variation, color.b * variation)
	for index: int in [0, 1, 2, 0, 2, 3]:
		surface.set_normal(Vector3(normal))
		surface.set_color(color)
		surface.add_vertex(corners[index])


static func _face_color(block: int, normal: Vector3i) -> Color:
	match block:
		VoxelWorldData.Block.GRASS:
			return Color("#65965a") if normal.y > 0 else Color("#80634a")
		VoxelWorldData.Block.DIRT:
			return Color("#997457")
		VoxelWorldData.Block.STONE:
			return Color("#8d99a5")
		_:
			return Color("#454e5b")
