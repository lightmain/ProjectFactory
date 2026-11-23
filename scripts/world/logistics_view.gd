class_name LogisticsView
extends Node3D
## Disposable nearby decorations. Removing this view never changes factory state.

const ORE_SURFACE_OFFSET: float = 0.04

## Injected by FactoryGame from GameConfig; zero disables nearby decorations.
var render_distance: float = 0.0
var ore_render_max_height_above_camera: float = GameConfig.DEFAULT_ORE_RENDER_MAX_HEIGHT_ABOVE_CAMERA

var item_render_pool: ItemRenderPool

var _logistics: LogisticsData
var _world: VoxelWorldData
var _camera: Camera3D
var _surface_view: VoxelWorldView
var _visuals: Dictionary[Vector3i, Node3D] = {}
var _ore_mesh: SphereMesh
var _ore_material: StandardMaterial3D
var _stage_stats: Dictionary[String, int] = {}
var _item_ids: PackedInt64Array = PackedInt64Array()
var _item_cells: Array[Vector3i] = []
var _item_transforms: Array[Transform3D] = []
var _display_error: String = ""


func bind_logistics(logistics: LogisticsData, world: VoxelWorldData, camera: Camera3D) -> void:
	if _logistics != null:
		_logistics.machine_changed.disconnect(_invalidate_cell)
		_logistics.reset.disconnect(_clear)
	_logistics = logistics
	_world = world
	_camera = camera
	_logistics.machine_changed.connect(_invalidate_cell)
	_logistics.reset.connect(_clear)
	if item_render_pool == null:
		item_render_pool = ItemRenderPool.new()
		item_render_pool.name = "ItemRenderPool"
		add_child(item_render_pool)
		_ore_material = _material(Color("#d37747"))
		_ore_mesh = SphereMesh.new()
		_ore_mesh.radius = 0.042
		_ore_mesh.height = 0.075
		_ore_mesh.radial_segments = 8
		_ore_mesh.rings = 4
		item_render_pool.register_visual(&"iron_ore", _ore_mesh, _ore_material)
	_clear()


func bind_surface_view(view: VoxelWorldView) -> void:
	if _surface_view != view and is_instance_valid(_surface_view):
		_surface_view.set_decoration_camera(null, 0.0, false)
	_surface_view = view
	if not visibility_changed.is_connected(_update_surface_camera):
		visibility_changed.connect(_update_surface_camera)
	_update_surface_camera()


func _enter_tree() -> void:
	_update_surface_camera()


func _exit_tree() -> void:
	if is_instance_valid(_surface_view):
		_surface_view.set_decoration_camera(null, 0.0, false)


func _update_surface_camera() -> void:
	if is_instance_valid(_surface_view):
		_surface_view.set_decoration_camera(_camera, render_distance, is_visible_in_tree())


func set_camera(camera: Camera3D) -> void:
	_camera = camera
	_update_surface_camera()


func _process(_delta: float) -> void:
	var frame_offset: float = Engine.get_physics_interpolation_fraction() / float(
		Engine.physics_ticks_per_second
	)
	refresh_from_data(frame_offset)


func refresh_from_data(frame_offset: float = 0.0) -> void:
	_display_error = ""
	_stage_stats.clear()
	if _logistics != null:
		_logistics.begin_display_frame()
	_update_surface_camera()
	if _logistics == null or not is_visible_in_tree():
		return
	item_render_pool.begin_frame()
	var stage_start: int = Time.get_ticks_usec()
	var cells: Array[Vector3i] = _nearby_cells()
	_stage_stats["candidate_usec"] = Time.get_ticks_usec() - stage_start
	_stage_stats["candidates"] = cells.size()
	stage_start = Time.get_ticks_usec()
	var nearby: Dictionary[Vector3i, bool] = {}
	for cell: Vector3i in cells:
		nearby[cell] = true
	# Only the previously visible decorations are visited for retirement.
	for cell: Vector3i in _visuals.keys():
		if not nearby.has(cell):
			_invalidate_cell(cell)
	var maximum_ore_y: float = (
		_camera.global_position.y + GameConfig.validated_ore_render_height(ore_render_max_height_above_camera)
	) if is_instance_valid(_camera) else -INF
	var ore_cells: Array[Vector3i] = []
	for cell: Vector3i in cells:
		if not _visuals.has(cell):
			_visuals[cell] = _create_visual(cell)
		var visual: Node3D = _visuals[cell]
		var block: int = _world.get_block(cell)
		if VoxelWorldData.is_belt(block):
			# Flat and sloped belt paths never descend below the cell's thin surface.
			# A crossing slope remains a candidate and is tested per final ore centre.
			# Use the same Vector3 precision and addition order as the rendered centre.
			var minimum_ore_y: float = (
				Vector3(0.0, float(cell.y) * VoxelWorldData.CELL_SIZE + VoxelWorldData.BELT_HEIGHT, 0.0)
				+ Vector3.UP * ORE_SURFACE_OFFSET
			).y
			if minimum_ore_y <= maximum_ore_y:
				ore_cells.append(cell)
			continue
		var count: int = _logistics.ore_count(cell)
		var first: MeshInstance3D = visual.get_node("Ore1") as MeshInstance3D
		var second: MeshInstance3D = visual.get_node("Ore2") as MeshInstance3D
		first.visible = count > 0
		second.visible = count > 1
	_stage_stats["decoration_usec"] = Time.get_ticks_usec() - stage_start
	_item_ids.clear()
	_item_cells.clear()
	_item_transforms.clear()
	stage_start = Time.get_ticks_usec()
	var samples: Array[LogisticsOreQueue] = []
	var packed: Dictionary = {}
	_stage_stats["display_requested_rows"] = ore_cells.size()
	_stage_stats["display_errors"] = 0
	if not ore_cells.is_empty():
		if _logistics.transport_backend() == "rust":
			packed = _logistics.sample_display_cells(ore_cells, Vector3.UP * ORE_SURFACE_OFFSET)
			if not packed.get("ok", false):
				_display_error = str(packed.get("error", "Invalid Rust display response."))
				_stage_stats["display_errors"] = 1
		else:
			samples = _logistics.sample_cells(ore_cells, frame_offset)
	_stage_stats["sample_usec"] = Time.get_ticks_usec() - stage_start
	stage_start = Time.get_ticks_usec()
	if not ore_cells.is_empty():
		if packed.get("ok", false):
			var ids: PackedInt64Array = packed["ids"]
			var positions: PackedVector3Array = packed["positions"]
			var owners: PackedInt64Array = packed["row_indices"]
			var requested: Array[Vector3i] = packed["cells"]
			for index: int in range(ids.size()):
				if positions[index].y <= maximum_ore_y:
					_item_ids.append(ids[index])
					_item_cells.append(requested[owners[index]])
					_item_transforms.append(Transform3D(Basis.IDENTITY, positions[index]))
		for sample: LogisticsOreQueue in samples:
			for ore: LogisticsOre in sample.ores:
				var position: Vector3 = ore.surface_position(sample.cell, sample.direction, sample.block) + Vector3.UP * ORE_SURFACE_OFFSET
				if position.y <= maximum_ore_y:
					_item_ids.append(ore.id)
					_item_cells.append(sample.cell)
					_item_transforms.append(Transform3D(Basis.IDENTITY, position))
	_stage_stats["mapping_usec"] = Time.get_ticks_usec() - stage_start
	stage_start = Time.get_ticks_usec()
	for index: int in range(_item_ids.size()):
		item_render_pool.submit(_item_ids[index], &"iron_ore", _item_cells[index], _item_transforms[index])
	item_render_pool.end_frame()
	_stage_stats["submission_usec"] = Time.get_ticks_usec() - stage_start
	_stage_stats["visible_items"] = _item_ids.size()


func display_error() -> String:
	return _display_error


func stage_stats() -> Dictionary[String, int]:
	return _stage_stats.duplicate()


func _nearby_cells() -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	if (
		not is_finite(render_distance) or render_distance <= 0.0
		or not is_instance_valid(_camera) or not _camera.global_position.is_finite()
	):
		return cells
	var position: Vector3 = _camera.global_position
	var radius: Vector3 = Vector3.ONE * render_distance
	# Clamp in floating point before converting even very distant cameras to cells.
	var low: Vector3 = ((position - radius) / VoxelWorldData.CELL_SIZE - Vector3.ONE * 0.5).max(
		Vector3(_world.minimum)
	)
	var high: Vector3 = ((position + radius) / VoxelWorldData.CELL_SIZE - Vector3.ONE * 0.5).min(
		Vector3(_world.maximum - Vector3i.ONE)
	)
	if low.x > high.x or low.y > high.y or low.z > high.z:
		return cells
	var minimum: Vector3i = Vector3i(floori(low.x), floori(low.y), floori(low.z))
	var maximum: Vector3i = Vector3i(floori(high.x), floori(high.y), floori(high.z))
	for cell: Vector3i in _logistics.candidate_cells(minimum, maximum):
		if position.distance_squared_to(VoxelWorldData.cell_center(cell)) <= render_distance * render_distance:
			cells.append(cell)
	return cells


func _clear() -> void:
	for visual: Node3D in _visuals.values():
		visual.free()
	_visuals.clear()
	if item_render_pool != null:
		item_render_pool.clear()


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
	if not VoxelWorldData.is_belt(block):
		for index: int in range(2):
			var ore: MeshInstance3D = _create_ore("Ore%d" % (index + 1))
			ore.position = Vector3(-0.12, bounds.size.y * 0.5 + ORE_SURFACE_OFFSET, -0.10 + float(index) * 0.19)
			ore.visible = false
			root.add_child(ore)
	return root


static func arrow_facing(direction: Vector3i, block: int) -> Basis:
	var facing: Basis = Basis(Vector3.UP, atan2(-float(direction.x), -float(direction.z)))
	var shape: Basis = Basis.IDENTITY
	shape.z.y = -float(VoxelWorldData.slope_rise(block))
	return facing * shape


func _create_ore(label: String) -> MeshInstance3D:
	var ore: MeshInstance3D = MeshInstance3D.new()
	ore.name = label
	ore.mesh = _ore_mesh
	ore.material_override = _ore_material
	return ore


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


static func _material(color: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material
