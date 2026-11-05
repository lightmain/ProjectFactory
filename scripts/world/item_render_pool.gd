class_name ItemRenderPool
extends Node3D
## Shared item visuals partitioned by spatial region and Mesh/material resources.
## Call begin_frame, submit current visible items, then end_frame synchronously.

const CHUNK_CELLS: int = 8
const MAX_IDLE_BATCHES: int = 32

class Visual:
	extends RefCounted
	var mesh: Mesh
	var material: Material
	var batches: Dictionary[Vector3i, ItemRenderBatch] = {}

var _visuals: Array[Visual] = []
var _item_visuals: Dictionary[StringName, int] = {}
var _active_batches: Array[ItemRenderBatch] = []
var _current_batches: Array[ItemRenderBatch] = []
var _idle_batches: Array[ItemRenderBatch] = []
var _item_batches: Dictionary[int, ItemRenderBatch] = {}
var _item_slots: Dictionary[int, int] = {}
var _frame: int = 0
var _frame_open: bool = false
var _next_batch_id: int = 0


func register_visual(item_id: StringName, mesh: Mesh, material: Material) -> void:
	assert(not _frame_open and not item_id.is_empty() and mesh != null)
	# Registration is outside the frame hot path. Aliases share the same resources.
	for index: int in range(_visuals.size()):
		if _visuals[index].mesh == mesh and _visuals[index].material == material:
			_item_visuals[item_id] = index
			return
	var visual: Visual = Visual.new()
	visual.mesh = mesh
	visual.material = material
	_item_visuals[item_id] = _visuals.size()
	_visuals.append(visual)


func begin_frame() -> void:
	assert(not _frame_open)
	_frame_open = true
	_frame += 1
	_item_batches.clear()
	_item_slots.clear()
	_current_batches.clear()
	for batch: ItemRenderBatch in _active_batches:
		batch.transforms.clear()


func submit(
	id: int, item_id: StringName, cell: Vector3i, world_transform: Transform3D
) -> bool:
	assert(_frame_open)
	if not _item_visuals.has(item_id) or _item_batches.has(id):
		return false
	var key: int = _item_visuals[item_id]
	var chunk: Vector3i = Vector3i((Vector3(cell) / float(CHUNK_CELLS)).floor())
	var visual: Visual = _visuals[key]
	var batch: ItemRenderBatch = visual.batches.get(chunk)
	if batch == null:
		if _idle_batches.is_empty():
			batch = ItemRenderBatch.new()
			batch.name = "ItemBatch%d" % _next_batch_id
			_next_batch_id += 1
			add_child(batch)
		else:
			batch = _idle_batches[-1]
			_remove_idle(batch)
			_visuals[batch.visual_key].batches.erase(batch.chunk)
		batch.configure(key, chunk, visual.mesh, visual.material)
		visual.batches[chunk] = batch
	if batch.frame != _frame:
		if batch.idle_index >= 0:
			_remove_idle(batch)
		batch.frame = _frame
		# Keep world positions correct even under a translated/rotated/scaled view.
		batch.global_transform = Transform3D(
			Basis.IDENTITY, Vector3(chunk) * float(CHUNK_CELLS) * VoxelWorldData.CELL_SIZE
		)
		_current_batches.append(batch)
	_item_batches[id] = batch
	_item_slots[id] = batch.transforms.size()
	batch.transforms.append(batch.global_transform.affine_inverse() * world_transform)
	return true


func end_frame() -> void:
	assert(_frame_open)
	for batch: ItemRenderBatch in _active_batches:
		if batch.frame != _frame:
			batch.retire()
			batch.idle_index = _idle_batches.size()
			_idle_batches.append(batch)
	for batch: ItemRenderBatch in _current_batches:
		batch.upload()
	while _idle_batches.size() > MAX_IDLE_BATCHES:
		var batch: ItemRenderBatch = _idle_batches.pop_back()
		_visuals[batch.visual_key].batches.erase(batch.chunk)
		batch.free()
	# Reuse the two frame arrays rather than retaining past active regions.
	var previous: Array[ItemRenderBatch] = _active_batches
	_active_batches = _current_batches
	_current_batches = previous
	_current_batches.clear()
	_frame_open = false


func has_item(id: int) -> bool:
	return _item_batches.has(id)


func item_batch(id: int) -> ItemRenderBatch:
	## Rendering inspection only; this is never an authoritative item identity.
	return _item_batches.get(id)


func item_transform(id: int) -> Transform3D:
	var batch: ItemRenderBatch = _item_batches.get(id)
	assert(batch != null, "Item is outside the current rendered snapshot")
	return batch.global_transform * batch.transforms[_item_slots[id]]


func stats() -> Dictionary[String, int]:
	var capacity: int = 0
	for batch: ItemRenderBatch in _active_batches:
		capacity += batch.multimesh.instance_count
	for batch: ItemRenderBatch in _idle_batches:
		capacity += batch.multimesh.instance_count
	return {
		"visible_items": _item_batches.size(),
		"active_batches": _active_batches.size(),
		"cached_batches": _idle_batches.size(),
		"capacity": capacity,
	}


func clear() -> void:
	assert(not _frame_open)
	for batch: ItemRenderBatch in _active_batches:
		batch.free()
	for batch: ItemRenderBatch in _idle_batches:
		batch.free()
	for visual: Visual in _visuals:
		visual.batches.clear()
	_active_batches.clear()
	_current_batches.clear()
	_idle_batches.clear()
	_item_batches.clear()
	_item_slots.clear()


func _remove_idle(batch: ItemRenderBatch) -> void:
	var index: int = batch.idle_index
	var last: ItemRenderBatch = _idle_batches[-1]
	_idle_batches[index] = last
	last.idle_index = index
	_idle_batches.pop_back()
	batch.idle_index = -1
