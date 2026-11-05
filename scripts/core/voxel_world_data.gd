class_name VoxelWorldData
extends RefCounted
## Authoritative game rules. Coordinates are cell minima in metres.

signal cell_changed(cell: Vector3i)
signal world_reset

enum Block { AIR, GRASS, DIRT, STONE, BEDROCK, MINER, BELT, CHEST }

const CELL_SIZE: float = 0.5
const BELT_HEIGHT: float = 0.08
const MIN_CELL: Vector3i = Vector3i(-32, -4, -32)
const MAX_CELL: Vector3i = Vector3i(32, 60, 32)
const DATA_CHUNK_SIZE: int = 32
const CHUNK_VOLUME: int = DATA_CHUNK_SIZE * DATA_CHUNK_SIZE * DATA_CHUNK_SIZE

var _chunks: Dictionary[Vector3i, PackedByteArray] = {}
var _differences: Dictionary[Vector3i, int] = {}
var _flat: bool = false
var _block_count: int = 0


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
	_chunks.clear()
	_differences.clear()
	_flat = true
	_block_count = 64 * 64 * 4
	world_reset.emit()


func is_in_bounds(cell: Vector3i) -> bool:
	return (
		cell.x >= MIN_CELL.x and cell.x < MAX_CELL.x
		and cell.y >= MIN_CELL.y and cell.y < MAX_CELL.y
		and cell.z >= MIN_CELL.z and cell.z < MAX_CELL.z
	)


func get_block(cell: Vector3i) -> int:
	if not is_in_bounds(cell):
		return Block.AIR
	var chunk: Vector3i = chunk_for(cell)
	if _chunks.has(chunk):
		return _chunks[chunk][_local_index(cell)]
	return _baseline(cell)


func block_count() -> int:
	return _block_count


func solid_cells() -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	if _flat:
		for x: int in range(MIN_CELL.x, MAX_CELL.x):
			for z: int in range(MIN_CELL.z, MAX_CELL.z):
				for y: int in range(-4, 0):
					var cell: Vector3i = Vector3i(x, y, z)
					if get_block(cell) != Block.AIR:
						cells.append(cell)
	for chunk: Vector3i in _chunks:
		var data: PackedByteArray = _chunks[chunk]
		for index: int in range(CHUNK_VOLUME):
			if data[index] == Block.AIR:
				continue
			var cell: Vector3i = cell_in_chunk(chunk, index)
			if _baseline(cell) == Block.AIR:
				cells.append(cell)
	return cells


static func chunk_for(cell: Vector3i) -> Vector3i:
	var local: Vector3i = cell - MIN_CELL
	return Vector3i(local.x >> 5, local.y >> 5, local.z >> 5)


static func cell_in_chunk(chunk: Vector3i, index: int) -> Vector3i:
	return MIN_CELL + chunk * DATA_CHUNK_SIZE + Vector3i(index & 31, index >> 10, (index >> 5) & 31)


static func _local_index(cell: Vector3i) -> int:
	var local: Vector3i = cell - MIN_CELL
	return ((local.y & 31) << 10) + ((local.z & 31) << 5) + (local.x & 31)


func has_flat_baseline() -> bool:
	return _flat


func chunk_deltas() -> Dictionary[Vector3i, PackedByteArray]:
	var result: Dictionary[Vector3i, PackedByteArray] = {}
	for chunk: Vector3i in _chunks:
		var records: PackedByteArray = PackedByteArray()
		var data: PackedByteArray = _chunks[chunk]
		for index: int in range(CHUNK_VOLUME):
			if data[index] != _baseline(cell_in_chunk(chunk, index)):
				records.append(index & 255)
				records.append(index >> 8)
				records.append(data[index])
		result[chunk] = records
	return result


func restore_chunks(flat: bool, chunks: Dictionary[Vector3i, PackedByteArray]) -> bool:
	# Validate everything before mutating the live rules.
	for chunk: Vector3i in chunks:
		if chunk.x not in [0, 1] or chunk.y not in [0, 1] or chunk.z not in [0, 1]:
			return false
		var records: PackedByteArray = chunks[chunk]
		if records.is_empty() or records.size() % 3 != 0 or records.size() > CHUNK_VOLUME * 3:
			return false
		var previous: int = -1
		for offset: int in range(0, records.size(), 3):
			var index: int = records.decode_u16(offset)
			var block: int = records[offset + 2]
			var cell: Vector3i = cell_in_chunk(chunk, index)
			if index >= CHUNK_VOLUME or index <= previous or block > Block.CHEST:
				return false
			if block == Block.BEDROCK or (flat and cell.y == -4):
				return false
			previous = index
	_chunks.clear()
	_differences.clear()
	_flat = flat
	_block_count = 64 * 64 * 4 if flat else 0
	for chunk: Vector3i in chunks:
		var records: PackedByteArray = chunks[chunk]
		for offset: int in range(0, records.size(), 3):
			_set_block(cell_in_chunk(chunk, records.decode_u16(offset)), records[offset + 2])
	world_reset.emit()
	return true


func _baseline(cell: Vector3i) -> int:
	if not _flat:
		return Block.AIR
	match cell.y:
		-1: return Block.GRASS
		-2: return Block.DIRT
		-3: return Block.STONE
		-4: return Block.BEDROCK
		_: return Block.AIR


func _set_block(cell: Vector3i, block: int) -> void:
	var previous: int = get_block(cell)
	if previous == block:
		return
	var chunk: Vector3i = chunk_for(cell)
	if not _chunks.has(chunk):
		var initial: PackedByteArray = PackedByteArray()
		initial.resize(CHUNK_VOLUME)
		for index: int in range(CHUNK_VOLUME):
			initial[index] = _baseline(cell_in_chunk(chunk, index))
		_chunks[chunk] = initial
		_differences[chunk] = 0
	var baseline: int = _baseline(cell)
	_differences[chunk] += int(block != baseline) - int(previous != baseline)
	_block_count += int(block != Block.AIR) - int(previous != Block.AIR)
	_chunks[chunk][_local_index(cell)] = block
	if _differences[chunk] == 0:
		_chunks.erase(chunk)
		_differences.erase(chunk)


func spawn_above_world(preferred: Vector3, body_size: Vector3) -> Vector3:
	# Respawn above the highest occupied cell in the body's entire footprint.
	# Immutable bedrock guarantees support, including when the surface was mined.
	var spawn: Vector3 = preferred
	spawn.x = clampf(spawn.x, float(MIN_CELL.x) * CELL_SIZE + body_size.x,
		float(MAX_CELL.x) * CELL_SIZE - body_size.x)
	spawn.z = clampf(spawn.z, float(MIN_CELL.z) * CELL_SIZE + body_size.z,
		float(MAX_CELL.z) * CELL_SIZE - body_size.z)
	var highest_top: float = float(MIN_CELL.y) * CELL_SIZE
	for cell: Vector3i in solid_cells():
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
	_set_block(cell, Block.AIR)
	cell_changed.emit(cell)
	return true


func place_block(cell: Vector3i, block: int, occupied_bounds: AABB = AABB()) -> bool:
	if block not in [Block.GRASS, Block.DIRT, Block.STONE, Block.MINER, Block.BELT, Block.CHEST]:
		return false
	if not is_in_bounds(cell) or get_block(cell) != Block.AIR:
		return false
	if occupied_bounds.has_volume() and block_bounds(cell, block).intersects(occupied_bounds):
		return false
	_set_block(cell, block)
	cell_changed.emit(cell)
	return true
