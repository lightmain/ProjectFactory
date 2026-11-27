class_name FactoryDynamicView
extends Node3D
## Complete dynamic rounds replace ores, local quantities and port decoration together.

const MAX_BYTES: int = 1048576
const PAGE_BYTES: int = 65536
var _info: Dictionary = {}
var _next: int = 0
var _bytes: int = 0
var _devices: Dictionary[Vector3i, Dictionary] = {}
var _ids: Dictionary[int, bool] = {}
var _transforms: PackedFloat32Array = PackedFloat32Array()
var _installed: Dictionary = {}
var _ores: MultiMeshInstance3D
var _decorations: Node3D


func _ready() -> void:
	_ores = MultiMeshInstance3D.new()
	_ores.multimesh = MultiMesh.new()
	_ores.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	var mesh: SphereMesh = SphereMesh.new()
	mesh.radius = 0.045
	mesh.height = 0.09
	mesh.radial_segments = 8
	mesh.rings = 4
	_ores.multimesh.mesh = mesh
	_ores.material_override = LogisticsView._material(Color("#e9b65d"))
	add_child(_ores)


func begin_snapshot(info: Dictionary) -> bool:
	abort()
	for field: String in ["world_epoch", "view_generation", "snapshot_id", "tick",
			"revision", "total_pages", "total_bytes"]:
		if not info.get(field) is int or int(info[field]) < 0:
			return false
	if int(info.world_epoch) <= 0 or int(info.view_generation) <= 0 or int(info.snapshot_id) <= 0 \
			or int(info.total_pages) < 1 or int(info.total_pages) > MAX_BYTES / 256 \
			or int(info.total_bytes) < int(info.total_pages) * 256 or int(info.total_bytes) > MAX_BYTES:
		return false
	_info = info.duplicate()
	return true


func stage_page(page: Dictionary) -> bool:
	if not _valid_page(page):
		abort()
		return false
	var cells: PackedInt32Array = page.cells
	var quantities: PackedInt64Array = page.quantities
	var blocks: PackedInt32Array = page.blocks
	var directions: PackedInt32Array = page.directions
	var inputs: PackedInt32Array = page.inputs
	var outputs: PackedInt32Array = page.outputs
	for i: int in range(quantities.size()):
		var cell: Vector3i = Vector3i(cells[i * 3], cells[i * 3 + 1], cells[i * 3 + 2])
		if _devices.has(cell) or quantities[i] < 0 or blocks[i] not in [5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 16] \
				or directions[i] < 0 or directions[i] > 3 or inputs[i] < 0 or inputs[i] > 15 \
				or outputs[i] < 0 or outputs[i] > 15:
			abort()
			return false
		_devices[cell] = {"cell": cell, "block": blocks[i], "direction": directions[i],
			"quantity": quantities[i], "inputs": inputs[i], "outputs": outputs[i]}
	var ids: PackedInt64Array = page.ore_ids
	for id: int in ids:
		if id <= 0 or _ids.has(id):
			abort()
			return false
		_ids[id] = true
	_transforms.append_array(page.transforms)
	_bytes += int(page.page_bytes)
	_next += 1
	if _next == int(_info.total_pages) and _bytes != int(_info.total_bytes):
		abort()
		return false
	return true


func _valid_page(page: Dictionary) -> bool:
	if _info.is_empty():
		return false
	for field: String in ["world_epoch", "view_generation", "snapshot_id", "tick", "revision",
			"total_pages", "total_bytes"]:
		if page.get(field) != _info.get(field):
			return false
	if not page.get("page_index") is int or int(page.page_index) != _next \
			or _next >= int(_info.total_pages) or not page.get("page_bytes") is int:
		return false
	for field: String in ["cells", "blocks", "directions", "inputs", "outputs"]:
		if not page.get(field) is PackedInt32Array:
			return false
	if not page.get("quantities") is PackedInt64Array or not page.get("ore_ids") is PackedInt64Array \
			or not page.get("transforms") is PackedFloat32Array:
		return false
	var quantities: PackedInt64Array = page.quantities
	var ids: PackedInt64Array = page.ore_ids
	var transforms: PackedFloat32Array = page.transforms
	var charged: int = 256 + quantities.size() * 40 + ids.size() * 56
	if int(page.page_bytes) != charged or charged > PAGE_BYTES or _bytes + charged > int(_info.total_bytes) \
			or page.cells.size() != quantities.size() * 3 or page.blocks.size() != quantities.size() \
			or page.directions.size() != quantities.size() or page.inputs.size() != quantities.size() \
			or page.outputs.size() != quantities.size() or transforms.size() != ids.size() * 12:
		return false
	for value: float in transforms:
		if not is_finite(value):
			return false
	return true


func prepared() -> bool:
	return not _info.is_empty() and _next == int(_info.total_pages) and _bytes == int(_info.total_bytes)


func activate(epoch: int, snapshot_id: int) -> bool:
	if not prepared() or int(_info.world_epoch) != epoch or int(_info.snapshot_id) != snapshot_id or _ores == null:
		return false
	var previous: Array = _installed.get("machines", [])
	var machines: Array[Dictionary] = []
	machines.assign(_devices.values())
	var ports_changed: bool = previous.size() != machines.size()
	if not ports_changed:
		for i: int in range(machines.size()):
			for key: String in ["cell", "block", "direction", "inputs", "outputs"]:
				if previous[i].get(key) != machines[i].get(key):
					ports_changed = true
	if ports_changed:
		_replace_decorations(machines)
	_ores.multimesh.instance_count = _ids.size()
	if not _ids.is_empty():
		_ores.multimesh.buffer = _transforms
	_installed = _info.duplicate()
	_installed["machines"] = machines
	_installed["ore_count"] = _ids.size()
	abort()
	return true


func _replace_decorations(machines: Array[Dictionary]) -> void:
	if _decorations != null:
		_decorations.free()
	_decorations = Node3D.new()
	add_child(_decorations)
	var arrow: Mesh = LogisticsView._arrow_mesh()
	for row: Dictionary in machines:
		var cell: Vector3i = row.cell
		var block: int = row.block
		var top: Vector3 = Vector3(cell) * 0.5 + Vector3(0.25, 0.5, 0.25)
		if VoxelWorldData.is_belt(block):
			top.y = float(cell.y) * 0.5 + 0.08 + (
				VoxelWorldData.slope_elevation(cell, block, top) if VoxelWorldData.is_slope(block) else 0.0)
		for side: int in range(4):
			if not VoxelWorldData.is_belt(block) and side != int(row.direction):
				continue
			var output: bool = int(row.outputs) & (1 << side) != 0
			var input_port: bool = int(row.inputs) & (1 << side) != 0
			if not output and not input_port:
				continue
			var visual: MeshInstance3D = MeshInstance3D.new()
			visual.mesh = arrow
			visual.material_override = LogisticsView._material(Color("#c9f0a1") if output else Color("#81cbdc"))
			var step: Vector3i = [Vector3i.BACK, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.RIGHT][side]
			visual.position = top + Vector3.UP * 0.004 + Vector3(step) * 0.12
			visual.scale = Vector3.ONE * 0.55
			visual.rotation.y = float(side if output else (side + 2) % 4) * PI * 0.5
			_decorations.add_child(visual)


func snapshot() -> Dictionary:
	return _installed.duplicate(true)


func abort() -> void:
	_info = {}
	_next = 0
	_bytes = 0
	_devices.clear()
	_ids.clear()
	_transforms.clear()
