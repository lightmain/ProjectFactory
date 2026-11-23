class_name ItemRenderBatch
extends MultiMeshInstance3D
## A reusable draw batch. Transforms are the CPU staging data, not logistics state.

var visual_key: int = -1
var chunk: Vector3i
var frame: int = -1
var idle_index: int = -1
var transforms: Array[Transform3D] = []
var world_inverse: Transform3D = Transform3D.IDENTITY
var _native_upload: RefCounted


func _init() -> void:
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.visible_instance_count = 0
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	hide()
	if ClassDB.class_exists("RustConveyorNetwork"):
		var helper: Object = ClassDB.instantiate("RustConveyorNetwork")
		if helper is RefCounted and helper.has_method("upload_multimesh"):
			_native_upload = helper as RefCounted


func configure(key: int, region: Vector3i, mesh: Mesh, material: Material) -> void:
	visual_key = key
	chunk = region
	multimesh.mesh = mesh
	material_override = material


func upload() -> bool:
	var count: int = transforms.size()
	if count > multimesh.instance_count:
		var capacity: int = maxi(8, multimesh.instance_count)
		while capacity < count:
			capacity *= 2
		# Resizing discards the old GPU buffer; upload the whole active prefix below.
		multimesh.instance_count = capacity
	if _native_upload != null:
		var uploaded: Variant = _native_upload.call("upload_multimesh", multimesh, transforms)
		if uploaded is bool and uploaded:
			visible = count > 0
			return true
	var mesh_bounds: AABB = multimesh.mesh.get_aabb()
	var bounds: AABB
	for index: int in range(count):
		var transform: Transform3D = transforms[index]
		# Keep the default backend usable without an installed native extension.
		multimesh.set_instance_transform(index, transform)
		var item_bounds: AABB = transform * mesh_bounds
		bounds = item_bounds if index == 0 else bounds.merge(item_bounds)
	# Reserved, unused slots must not enlarge the culling bounds.
	multimesh.custom_aabb = bounds
	multimesh.visible_instance_count = count
	visible = count > 0
	return false


func retire() -> void:
	transforms.clear()
	multimesh.visible_instance_count = 0
	hide()
