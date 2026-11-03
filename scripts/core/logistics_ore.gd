class_name LogisticsOre
extends RefCounted
## Per-ore belt state; public snapshots own independent copies.

var id: int
var incoming_direction: Vector3i
var progress: float = 0.0


func _init(ore_id: int, incoming: Vector3i) -> void:
	id = ore_id
	incoming_direction = incoming


func copy() -> LogisticsOre:
	var snapshot: LogisticsOre = LogisticsOre.new(id, incoming_direction)
	snapshot.progress = progress
	return snapshot


func surface_position(cell: Vector3i, outgoing: Vector3i) -> Vector3:
	var center: Vector3 = VoxelWorldData.cell_center(cell)
	center.y = float(cell.y) * VoxelWorldData.CELL_SIZE + VoxelWorldData.BELT_HEIGHT
	if incoming_direction == outgoing:
		return center + Vector3(outgoing) * ((progress - 0.5) * VoxelWorldData.CELL_SIZE)
	if progress < 0.5:
		return center + Vector3(incoming_direction) * ((progress - 0.5) * VoxelWorldData.CELL_SIZE)
	return center + Vector3(outgoing) * ((progress - 0.5) * VoxelWorldData.CELL_SIZE)
