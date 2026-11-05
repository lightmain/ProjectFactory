class_name ItemRenderBatch
extends MultiMeshInstance3D
## A reusable draw batch. Transforms are the CPU staging data, not logistics state.

var visual_key: int = -1
var chunk: Vector3i
var frame: int = -1
var idle_index: int = -1
var transforms: Array[Transform3D] = []


func _init() -> void:
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.visible_instance_count = 0
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	hide()


func configure(key: int, region: Vector3i, mesh: Mesh, material: Material) -> void:
	visual_key = key
	chunk = region
	multimesh.mesh = mesh
	material_override = material


func upload() -> void:
	var count: int = transforms.size()
	if count > multimesh.instance_count:
		var capacity: int = maxi(8, multimesh.instance_count)
		while capacity < count:
			capacity *= 2
		# Resizing discards the old GPU buffer; upload the whole active prefix below.
		multimesh.instance_count = capacity
	var mesh_bounds: AABB = multimesh.mesh.get_aabb()
	var bounds: AABB
	for index: int in range(count):
		multimesh.set_instance_transform(index, transforms[index])
		var item_bounds: AABB = transforms[index] * mesh_bounds
		bounds = item_bounds if index == 0 else bounds.merge(item_bounds)
	# Reserved, unused slots must not enlarge the culling bounds.
	multimesh.custom_aabb = bounds
	multimesh.visible_instance_count = count
	visible = count > 0


func retire() -> void:
	transforms.clear()
	multimesh.visible_instance_count = 0
	hide()
