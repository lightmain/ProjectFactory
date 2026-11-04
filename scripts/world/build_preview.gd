class_name BuildPreview
extends Node3D
## Collision-free ghost geometry and one shared batch for locked waypoints.

var _bodies: MultiMeshInstance3D
var _arrows: MultiMeshInstance3D
var _lock_rings: MultiMeshInstance3D
var _body_material: StandardMaterial3D
var _arrow_material: StandardMaterial3D


func _ready() -> void:
	_body_material = _material(0.38)
	_arrow_material = _material(0.72)
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3.ONE
	_bodies = _batch("Bodies", box, _body_material)
	_arrows = _batch("Arrows", LogisticsView._arrow_mesh(), _arrow_material)
	var ring: TorusMesh = TorusMesh.new()
	ring.inner_radius = 0.16
	ring.outer_radius = 0.19
	ring.rings = 32
	ring.ring_segments = 8
	var ring_material: StandardMaterial3D = StandardMaterial3D.new()
	ring_material.albedo_color = Color("#ffe033")
	ring_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_lock_rings = _batch("LockRings", ring, ring_material)
	hide()


func show_cells(
	cells: Array[Vector3i], directions: Array[Vector3i], block: int,
	world: VoxelWorldData, invalid: bool, locked_points: Array[Vector3i] = []
) -> void:
	var body_transforms: Array[Transform3D] = []
	var arrow_transforms: Array[Transform3D] = []
	for index: int in range(cells.size()):
		var cell: Vector3i = cells[index]
		var existing: int = world.get_block(cell)
		if block == VoxelWorldData.Block.BELT and existing in [
			VoxelWorldData.Block.MINER, VoxelWorldData.Block.CHEST,
		]:
			continue
		var bounds: AABB = VoxelWorldData.block_bounds(cell, block)
		# Slight expansion avoids coplanar flicker on existing endpoint belts.
		var expansion: Vector3 = Vector3.ONE * 0.004 if existing != VoxelWorldData.Block.AIR else Vector3.ZERO
		body_transforms.append(Transform3D(
			Basis.IDENTITY.scaled(bounds.size + expansion), bounds.get_center()
		))
		var direction: Vector3i = directions[index]
		var facing: Basis = Basis(Vector3.UP, atan2(-float(direction.x), -float(direction.z)))
		arrow_transforms.append(Transform3D(
			facing, bounds.get_center() + Vector3.UP * (bounds.size.y * 0.5 + 0.006)
		))
	_set_transforms(_bodies.multimesh, body_transforms)
	_set_transforms(_arrows.multimesh, arrow_transforms)
	show_lock_points(locked_points)
	set_invalid(invalid)
	visible = not body_transforms.is_empty()


func show_lock_points(cells: Array[Vector3i]) -> void:
	var transforms: Array[Transform3D] = []
	for cell: Vector3i in cells:
		var bounds: AABB = VoxelWorldData.block_bounds(cell, VoxelWorldData.Block.BELT)
		transforms.append(Transform3D(
			Basis.IDENTITY, bounds.get_center() + Vector3.UP * (bounds.size.y * 0.5 + 0.18)
		))
	_set_transforms(_lock_rings.multimesh, transforms)


func set_invalid(invalid: bool, failure_flash: bool = false) -> void:
	var color: Color = Color("#ee665f") if invalid else Color("#64b7f5")
	var arrow_color: Color = Color("#8c302a") if invalid else Color("#23486c")
	if failure_flash:
		color = Color("#ffb0a2")
		arrow_color = Color("#fff1e9")
	_body_material.albedo_color = Color(color, 0.72 if failure_flash else 0.38)
	_arrow_material.albedo_color = Color(arrow_color, 1.0 if failure_flash else 0.95)


func _batch(label: String, mesh: Mesh, material: Material) -> MultiMeshInstance3D:
	var instance: MultiMeshInstance3D = MultiMeshInstance3D.new()
	instance.name = label
	instance.multimesh = MultiMesh.new()
	instance.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	instance.multimesh.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return instance


static func _set_transforms(multimesh: MultiMesh, transforms: Array[Transform3D]) -> void:
	multimesh.instance_count = transforms.size()
	for index: int in range(transforms.size()):
		multimesh.set_instance_transform(index, transforms[index])


static func _material(alpha: float) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
	material.albedo_color = Color(0.65, 0.9, 0.7, alpha)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material
