class_name LogisticsOreQueue
extends RefCounted
## An indexed snapshot row, or an internal borrowed authoritative queue.

var cell: Vector3i
var direction: Vector3i
var block: int = VoxelWorldData.Block.BELT
var ores: Array[LogisticsOre] = []

# Only prediction rows use this storage; public/borrowed rows keep it empty.
var _cached_ores: Array[LogisticsOre] = []


func refresh_prediction(
	machine: LogisticsMachine, source_cell: Vector3i, progress_offset: float = 0.0
) -> int:
	var created: int = resize_prediction(machine.belt_ores.size())
	cell = source_cell
	direction = machine.settled_direction
	block = machine.block
	for index: int in range(machine.belt_ores.size()):
		var source: LogisticsOre = machine.belt_ores[index]
		var cached: LogisticsOre = _cached_ores[index]
		cached.id = source.id
		cached.incoming_direction = source.incoming_direction
		cached.progress = source.progress + progress_offset
		ores[index] = cached
	return created


func resize_prediction(count: int) -> int:
	var created: int = 0
	while _cached_ores.size() < count:
		_cached_ores.append(LogisticsOre.new(0, Vector3i.FORWARD))
		created += 1
	ores.resize(count)
	for index: int in range(count):
		ores[index] = _cached_ores[index]
	return created


func cached_ore_slots() -> int:
	return _cached_ores.size()
