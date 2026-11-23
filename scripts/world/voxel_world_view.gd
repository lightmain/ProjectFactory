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
var _logistics: LogisticsData
var _chunks: Dictionary[Vector3i, StaticBody3D] = {}
var _pending: Dictionary[Vector3i, bool] = {}
var _material: ShaderMaterial
var _structure_arrows: MultiMeshInstance3D


func bind_logistics(logistics: LogisticsData) -> void:
	if _logistics != null:
		_logistics.machine_changed.disconnect(_on_cell_changed)
		_logistics.reset.disconnect(_on_logistics_reset)
	_logistics = logistics
	_logistics.machine_changed.connect(_on_cell_changed)
	_logistics.reset.connect(_on_logistics_reset)
	_on_logistics_reset()


func _on_logistics_reset() -> void:
	# Restoring directions invalidates the existing surfaces, not world geometry.
	# Defer rebuilding so a following bind_world does not build the old world twice.
	for chunk: Vector3i in _chunks:
		_pending[chunk] = true


func set_decoration_camera(camera: Camera3D, distance: float, enabled: bool) -> void:
	if _material == null:
		return
	var valid: bool = (
		enabled and is_instance_valid(camera) and is_finite(distance) and distance > 0.0
	)
	if valid:
		valid = camera.global_position.is_finite()
	_material.set_shader_parameter("decorations_enabled", valid)
	_material.set_shader_parameter("decoration_distance", distance if valid else 0.0)
	if valid:
		_material.set_shader_parameter("decoration_camera", camera.global_position)


func bind_world(world: VoxelWorldData) -> void:
	if _world != null:
		_world.cell_changed.disconnect(_on_cell_changed)
		_world.world_reset.disconnect(_on_world_reset)
	_world = world
	_material = ShaderMaterial.new()
	_material.shader = GRID_SHADER
	_material.set_shader_parameter("output_color", Color("#c9f0a1"))
	_material.set_shader_parameter("input_color", Color("#81cbdc"))
	_world.cell_changed.connect(_on_cell_changed)
	_world.world_reset.connect(_on_world_reset)
	_on_world_reset()


func _ready() -> void:
	# Run before default-priority player physics, including multiple ticks per render.
	process_physics_priority = -100


func _physics_process(_delta: float) -> void:
	rebuild_pending()


func rebuild_pending() -> void:
	if _pending.is_empty():
		return
	for chunk: Vector3i in _pending.keys():
		_rebuild_chunk(chunk)
	_pending.clear()
	_rebuild_structure_arrows()


func _rebuild_structure_arrows() -> void:
	if _structure_arrows == null:
		_structure_arrows = MultiMeshInstance3D.new()
		_structure_arrows.name = "StructureArrows"
		_structure_arrows.multimesh = MultiMesh.new()
		_structure_arrows.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		_structure_arrows.multimesh.mesh = LogisticsView._arrow_mesh()
		var material: StandardMaterial3D = StandardMaterial3D.new()
		material.albedo_color = Color("#222222")
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_structure_arrows.material_override = material
		_structure_arrows.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_structure_arrows)
	var rows: Array[Dictionary] = _world.structure_rows()
	_structure_arrows.multimesh.instance_count = rows.size()
	for index: int in range(rows.size()):
		var anchor: Vector3i = rows[index]["anchor"]
		var turns: int = rows[index]["rotation"]
		var bounds: AABB = VoxelWorldData.structure_bounds(anchor)
		var facing: Basis = Basis(Vector3.UP, PI - float(turns) * PI * 0.5)
		_structure_arrows.multimesh.set_instance_transform(index, Transform3D(
			facing.scaled(Vector3.ONE * 3.0), bounds.get_center() + Vector3.UP * (bounds.size.y * 0.5 + 0.01)
		))


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
	_rebuild_structure_arrows()


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
	surface.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
	var face_count: int = 0
	var start: Vector3i = chunk * CHUNK_SIZE
	for x: int in range(start.x, start.x + CHUNK_SIZE):
		for y: int in range(start.y, start.y + CHUNK_SIZE):
			for z: int in range(start.z, start.z + CHUNK_SIZE):
				var cell: Vector3i = Vector3i(x, y, z)
				var block: int = _world.get_block(cell)
				if block == VoxelWorldData.Block.AIR:
					continue
				var bounds: AABB = VoxelWorldData.block_bounds(cell, block)
				var direction: Vector3i = Vector3i.ZERO
				if _logistics != null and LogisticsData.is_machine(block):
					direction = _logistics.direction_at(cell)
				for normal: Vector3i in FACE_NORMALS:
					if not _face_covered(cell, normal, bounds):
						_add_face(surface, cell, normal, block, bounds, direction)
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


func _face_covered(cell: Vector3i, normal: Vector3i, bounds: AABB) -> bool:
	var neighbor_cell: Vector3i = cell + normal
	var neighbor: int = _world.get_block(neighbor_cell)
	if VoxelWorldData.is_slope(_world.get_block(cell)) or VoxelWorldData.is_slope(neighbor):
		return false
	if neighbor == VoxelWorldData.Block.AIR:
		return false
	var other: AABB = VoxelWorldData.block_bounds(neighbor_cell, neighbor)
	var axis: int = 0 if normal.x != 0 else (1 if normal.y != 0 else 2)
	var face: float = bounds.end[axis] if normal[axis] > 0 else bounds.position[axis]
	var other_face: float = other.position[axis] if normal[axis] > 0 else other.end[axis]
	if not is_equal_approx(face, other_face):
		return false
	for tangent: int in range(3):
		if tangent == axis:
			continue
		if other.position[tangent] > bounds.position[tangent] or other.end[tangent] < bounds.end[tangent]:
			return false
	return true


static func _add_face(
	surface: SurfaceTool, cell: Vector3i, normal: Vector3i, block: int, bounds: AABB,
	direction: Vector3i = Vector3i.ZERO
) -> void:
	if VoxelWorldData.is_slope(block):
		bounds = VoxelWorldData.block_bounds(cell, VoxelWorldData.Block.BELT)
	var u: Vector3 = Vector3(normal).cross(Vector3.UP)
	var v: Vector3 = Vector3.UP
	if normal.y != 0:
		u = Vector3.RIGHT
		v = Vector3.BACK if normal.y > 0 else Vector3.FORWARD
	var center: Vector3 = bounds.get_center() + Vector3(normal) * bounds.size * 0.5
	u *= bounds.size * 0.5
	v *= bounds.size * 0.5
	var corners: Array[Vector3] = [
		center - u - v, center + u - v,
		center + u + v, center - u + v,
	]
	var face_normal: Vector3 = Vector3(normal)
	if VoxelWorldData.is_slope(block):
		for index: int in range(corners.size()):
			corners[index].y += VoxelWorldData.slope_elevation(cell, block, corners[index])
		if normal.y != 0:
			face_normal = (Vector3.UP - Vector3(VoxelWorldData.slope_direction(block)) * VoxelWorldData.slope_rise(block)).normalized() * normal.y
	var color: Color = _face_color(block, normal)
	var mark: int = 0
	if direction != Vector3i.ZERO:
		if normal == Vector3i.UP:
			mark = 1
		elif normal == direction:
			mark = 2
		elif normal.y == 0 and (
			block == VoxelWorldData.Block.BELT
			or (block != VoxelWorldData.Block.MINER and normal == -direction)
		):
			mark = 3
	var cell_center: Vector3 = VoxelWorldData.cell_center(cell)
	var forward: Vector3 = Vector3(direction)
	var left: Vector3 = Vector3.UP.cross(forward)
	var port_width_axis: Vector3 = Vector3(normal).cross(Vector3.UP)
	var port_height: float = minf(0.12, bounds.size.y * 0.6)
	# A small deterministic variation makes individual voxels readable.
	var variation: float = 0.94 + float(posmod(cell.x * 31 + cell.y * 17 + cell.z * 13, 11)) * 0.01
	color = Color(color.r * variation, color.g * variation, color.b * variation)
	for index: int in [0, 1, 2, 0, 2, 3]:
		surface.set_normal(face_normal)
		surface.set_color(color)
		var offset: Vector3 = corners[index] - bounds.get_center()
		var uv: Vector2 = Vector2.ZERO
		if mark == 1:
			uv = Vector2(offset.dot(left), -offset.dot(forward))
		elif mark > 1:
			# Remove the slope elevation so the end ports remain vertical rectangles.
			if VoxelWorldData.is_slope(block):
				offset.y -= VoxelWorldData.slope_elevation(cell, block, corners[index])
			uv = Vector2(offset.dot(port_width_axis) / 0.16, offset.y / port_height)
		surface.set_uv(uv)
		surface.set_custom(0, Color(cell_center.x, cell_center.y, cell_center.z, float(mark)))
		surface.add_vertex(corners[index])


static func _face_color(block: int, normal: Vector3i) -> Color:
	if VoxelWorldData.is_slope(block):
		return Color("#444444") if normal.y > 0 else Color("#969696")
	match block:
		VoxelWorldData.Block.GRASS:
			return Color("#65965a") if normal.y > 0 else Color("#80634a")
		VoxelWorldData.Block.DIRT:
			return Color("#997457")
		VoxelWorldData.Block.STONE:
			return Color("#8d99a5")
		VoxelWorldData.Block.MINER:
			return Color("#d69238") if normal.y > 0 else Color("#9a652d")
		VoxelWorldData.Block.BELT:
			return Color("#344b58") if normal.y > 0 else Color("#657b85")
		VoxelWorldData.Block.CHEST:
			return Color("#b98a56") if normal.y > 0 else Color("#805e40")
		VoxelWorldData.Block.STRUCTURE:
			return Color("#d4d4d4") if normal.y > 0 else Color("#969696")
		_:
			return Color("#454e5b")
