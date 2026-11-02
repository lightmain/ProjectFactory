class_name LogisticsView
extends Node3D
## Disposable nearby decorations. Removing this view never changes factory state.

@export var render_distance: float = 12.0

var _logistics: LogisticsData
var _world: VoxelWorldData
var _camera: Camera3D
var _visuals: Dictionary[Vector3i, Node3D] = {}
var _ore_mesh: SphereMesh
var _ore_material: StandardMaterial3D
var _output_material: StandardMaterial3D
var _input_material: StandardMaterial3D


func bind_logistics(logistics: LogisticsData, world: VoxelWorldData, camera: Camera3D) -> void:
	if _logistics != null:
		_logistics.machine_changed.disconnect(_invalidate_cell)
		_logistics.reset.disconnect(_clear)
	_logistics = logistics
	_world = world
	_camera = camera
	_logistics.machine_changed.connect(_invalidate_cell)
	_logistics.reset.connect(_clear)
	_output_material = _material(Color("#c9f0a1"))
	_input_material = _material(Color("#81cbdc"))
	_ore_material = _material(Color("#d37747"))
	_ore_mesh = SphereMesh.new()
	_ore_mesh.radius = 0.042
	_ore_mesh.height = 0.075
	_ore_mesh.radial_segments = 8
	_ore_mesh.rings = 4
	_clear()


func _process(_delta: float) -> void:
	if _logistics == null or not is_visible_in_tree():
		return
	for cell: Vector3i in _logistics.machine_cells():
		var nearby: bool = _camera.global_position.distance_squared_to(
			VoxelWorldData.cell_center(cell)
		) <= render_distance * render_distance
		if not nearby:
			_invalidate_cell(cell)
			continue
		if not _visuals.has(cell):
			_visuals[cell] = _create_visual(cell)
		var visual: Node3D = _visuals[cell]
		var count: int = _logistics.ore_count(cell)
		var first: MeshInstance3D = visual.get_node("Ore1") as MeshInstance3D
		var second: MeshInstance3D = visual.get_node("Ore2") as MeshInstance3D
		first.visible = count > 0
		second.visible = count > 1


func _clear() -> void:
	for visual: Node3D in _visuals.values():
		visual.free()
	_visuals.clear()


func _invalidate_cell(cell: Vector3i) -> void:
	if _visuals.has(cell):
		_visuals[cell].free()
		_visuals.erase(cell)


func _create_visual(cell: Vector3i) -> Node3D:
	var root: Node3D = Node3D.new()
	root.name = "Machine_%d_%d_%d" % [cell.x, cell.y, cell.z]
	var block: int = _world.get_block(cell)
	var bounds: AABB = VoxelWorldData.block_bounds(cell, block)
	root.position = bounds.get_center()
	var direction: Vector3i = _logistics.direction_at(cell)
	root.rotation.y = atan2(-float(direction.x), -float(direction.z))
	add_child(root)
	var arrow: MeshInstance3D = MeshInstance3D.new()
	arrow.name = "OutputArrow"
	arrow.mesh = _arrow_mesh()
	arrow.position.y = bounds.size.y * 0.5 + 0.003
	arrow.material_override = _output_material
	root.add_child(arrow)
	_add_port(root, "Output", Vector3.FORWARD, _output_material, bounds.size.y)
	if block != VoxelWorldData.Block.MINER:
		_add_port(root, "Input", Vector3.BACK, _input_material, bounds.size.y)
	if block == VoxelWorldData.Block.BELT:
		_add_port(root, "InputLeft", Vector3.LEFT, _input_material, bounds.size.y)
		_add_port(root, "InputRight", Vector3.RIGHT, _input_material, bounds.size.y)
	for index: int in range(2):
		var ore: MeshInstance3D = MeshInstance3D.new()
		ore.name = "Ore%d" % (index + 1)
		ore.mesh = _ore_mesh
		ore.material_override = _ore_material
		ore.position = Vector3(-0.12, bounds.size.y * 0.5 + 0.04, -0.10 + float(index) * 0.19)
		ore.visible = false
		root.add_child(ore)
	return root


static func _arrow_mesh() -> ArrayMesh:
	var surface: SurfaceTool = SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var points: Array[Vector3] = [
		Vector3(-0.025, 0, 0.17), Vector3(0.025, 0, -0.05),
		Vector3(-0.025, 0, -0.05),
		Vector3(-0.025, 0, 0.17), Vector3(0.025, 0, 0.17),
		Vector3(0.025, 0, -0.05),
		Vector3(-0.105, 0, -0.05), Vector3(0.105, 0, -0.05),
		Vector3(0, 0, -0.20),
	]
	for point: Vector3 in points:
		surface.set_normal(Vector3.UP)
		surface.add_vertex(point)
	return surface.commit()


static func _add_port(
	root: Node3D, label: String, normal: Vector3, material: Material, height: float
) -> void:
	var port: MeshInstance3D = MeshInstance3D.new()
	port.name = label
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(0.16, minf(0.12, height * 0.6), 0.006)
	port.mesh = box
	port.material_override = material
	port.position = normal * 0.253
	port.rotation.y = atan2(normal.x, normal.z)
	root.add_child(port)


static func _material(color: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material
