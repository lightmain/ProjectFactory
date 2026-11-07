class_name VoxelHit
extends RefCounted

var cell: Vector3i
var normal: Vector3i
var distance: float
var position: Vector3


func _init(
	hit_cell: Vector3i, hit_normal: Vector3i, hit_distance: float,
	hit_position: Vector3 = Vector3.ZERO
) -> void:
	cell = hit_cell
	normal = hit_normal
	distance = hit_distance
	position = hit_position


func adjacent_cell() -> Vector3i:
	return cell + normal
