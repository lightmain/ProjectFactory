class_name VoxelHit
extends RefCounted

var cell: Vector3i
var normal: Vector3i
var distance: float


func _init(hit_cell: Vector3i, hit_normal: Vector3i, hit_distance: float) -> void:
	cell = hit_cell
	normal = hit_normal
	distance = hit_distance


func adjacent_cell() -> Vector3i:
	return cell + normal
