class_name VoxelWorldData
extends RefCounted
## Authoritative game rules. Coordinates are cell minima in metres.

signal cell_changed(cell: Vector3i)
signal world_reset

enum Block { AIR, GRASS, DIRT, STONE, BEDROCK, MINER, BELT, CHEST }

const CELL_SIZE: float = 0.5
const BELT_HEIGHT: float = 0.08
const MIN_CELL: Vector3i = Vector3i(-16, -4, -16)
const MAX_CELL: Vector3i = Vector3i(16, 16, 16)

var _blocks: Dictionary[Vector3i, int] = {}


static func world_to_cell(position: Vector3) -> Vector3i:
	return Vector3i((position / CELL_SIZE).floor())


static func cell_center(cell: Vector3i) -> Vector3:
	return (Vector3(cell) + Vector3.ONE * 0.5) * CELL_SIZE


static func cell_bounds(cell: Vector3i) -> AABB:
	return AABB(Vector3(cell) * CELL_SIZE, Vector3.ONE * CELL_SIZE)


static func block_bounds(cell: Vector3i, block: int) -> AABB:
	## Physical occupied volume; cell_bounds remains the reserved grid volume.
	var bounds: AABB = cell_bounds(cell)
	if block == Block.BELT:
		bounds.size.y = BELT_HEIGHT
	return bounds


static func block_name(block: int) -> String:
	match block:
		Block.GRASS:
			return "Grass"
		Block.DIRT:
			return "Dirt"
		Block.STONE:
			return "Stone"
		Block.BEDROCK:
			return "Bedrock"
		Block.MINER:
			return "Miner"
		Block.BELT:
			return "Belt"
		Block.CHEST:
			return "Chest"
		_:
			return "Air"


func generate_flat() -> void:
	_blocks.clear()
	for x: int in range(MIN_CELL.x, MAX_CELL.x):
		for z: int in range(MIN_CELL.z, MAX_CELL.z):
			_blocks[Vector3i(x, -1, z)] = Block.GRASS
			_blocks[Vector3i(x, -2, z)] = Block.DIRT
			_blocks[Vector3i(x, -3, z)] = Block.STONE
			_blocks[Vector3i(x, -4, z)] = Block.BEDROCK
	world_reset.emit()


func is_in_bounds(cell: Vector3i) -> bool:
	return (
		cell.x >= MIN_CELL.x and cell.x < MAX_CELL.x
		and cell.y >= MIN_CELL.y and cell.y < MAX_CELL.y
		and cell.z >= MIN_CELL.z and cell.z < MAX_CELL.z
	)


func get_block(cell: Vector3i) -> int:
	return _blocks.get(cell, Block.AIR)


func block_count() -> int:
	return _blocks.size()


func solid_cells() -> Array[Vector3i]:
	return _blocks.keys()


func spawn_above_world(preferred: Vector3, body_size: Vector3) -> Vector3:
	# Respawn above the highest occupied cell in the body's entire footprint.
	# Immutable bedrock guarantees support, including when the surface was mined.
	var spawn: Vector3 = preferred
	spawn.x = clampf(spawn.x, float(MIN_CELL.x) * CELL_SIZE + body_size.x,
		float(MAX_CELL.x) * CELL_SIZE - body_size.x)
	spawn.z = clampf(spawn.z, float(MIN_CELL.z) * CELL_SIZE + body_size.z,
		float(MAX_CELL.z) * CELL_SIZE - body_size.z)
	var highest_top: float = float(MIN_CELL.y) * CELL_SIZE
	for cell: Vector3i in _blocks:
		var bounds: AABB = block_bounds(cell, get_block(cell))
		if (
			bounds.position.x < spawn.x + body_size.x * 0.5
			and bounds.end.x > spawn.x - body_size.x * 0.5
			and bounds.position.z < spawn.z + body_size.z * 0.5
			and bounds.end.z > spawn.z - body_size.z * 0.5
		):
			highest_top = maxf(highest_top, bounds.end.y)
	spawn.y = highest_top + 0.01
	return spawn


func break_block(cell: Vector3i) -> bool:
	var block: int = get_block(cell)
	if not is_in_bounds(cell) or block == Block.AIR or block == Block.BEDROCK:
		return false
	_blocks.erase(cell)
	cell_changed.emit(cell)
	return true


func place_block(cell: Vector3i, block: int, occupied_bounds: AABB = AABB()) -> bool:
	if block not in [Block.GRASS, Block.DIRT, Block.STONE, Block.MINER, Block.BELT, Block.CHEST]:
		return false
	if not is_in_bounds(cell) or get_block(cell) != Block.AIR:
		return false
	if occupied_bounds.has_volume() and block_bounds(cell, block).intersects(occupied_bounds):
		return false
	_blocks[cell] = block
	cell_changed.emit(cell)
	return true
