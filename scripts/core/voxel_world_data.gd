class_name VoxelWorldData
extends RefCounted
## Authoritative game rules. Coordinates are cell minima in metres.

signal cell_changed(cell: Vector3i)
signal world_reset

enum Block { AIR, GRASS, DIRT, STONE, BEDROCK, MINER, BELT, CHEST, STRUCTURE }

const CELL_SIZE: float = 0.5
const BELT_HEIGHT: float = 0.08
const MIN_CELL: Vector3i = Vector3i(-32, -4, -32)
const MAX_CELL: Vector3i = Vector3i(32, 60, 32)
const DATA_CHUNK_SIZE: int = 32
const CHUNK_VOLUME: int = DATA_CHUNK_SIZE * DATA_CHUNK_SIZE * DATA_CHUNK_SIZE
const MAX_STRUCTURE_ID: int = 2147483646

var _chunks: Dictionary[Vector3i, PackedByteArray] = {}
var _differences: Dictionary[Vector3i, int] = {}
var _flat: bool = false
var _block_count: int = 0
var _structure_cells: Dictionary[Vector3i, int] = {}
var _structures: Dictionary[int, Dictionary] = {}
var _next_structure_id: int = 1


static func structure_anchor(point: Vector3) -> Vector3i:
	return Vector3i(
		roundi(point.x / CELL_SIZE - 0.5), roundi(point.y / CELL_SIZE),
		roundi(point.z / CELL_SIZE - 0.5)
	)


static func structure_bounds(anchor: Vector3i) -> AABB:
	return AABB(Vector3(anchor + Vector3i(-1, 0, -1)) * CELL_SIZE, Vector3.ONE * CELL_SIZE * 3.0)


static func structure_footprint(anchor: Vector3i) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	for x: int in range(-1, 2):
		for y: int in range(3):
			for z: int in range(-1, 2):
				cells.append(anchor + Vector3i(x, y, z))
	return cells


func structure_at(cell: Vector3i) -> Dictionary:
	if not _structure_cells.has(cell):
		return {}
	# Callers cannot mutate the authoritative identity/geometry.
	return _structures[_structure_cells[cell]].duplicate()


func structure_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for id: int in _structures:
		rows.append(_structures[id].duplicate())
	return rows


func occupied_bounds_at(cell: Vector3i) -> AABB:
	var structure: Dictionary = structure_at(cell)
	if not structure.is_empty():
		var anchor: Vector3i = structure["anchor"]
		return structure_bounds(anchor)
	return block_bounds(cell, get_block(cell))


func structure_placement_error(anchor: Vector3i, occupied: AABB = AABB()) -> String:
	for cell: Vector3i in structure_footprint(anchor):
		if not is_in_bounds(cell):
			return "超出世界边界"
		if get_block(cell) != Block.AIR:
			return "该位置已被占用"
	if occupied.has_volume() and structure_bounds(anchor).intersects(occupied):
		return "不能放在玩家所在位置"
	return ""


func place_structure(anchor: Vector3i, rotation: int = 0, occupied: AABB = AABB()) -> bool:
	if rotation < 0 or rotation > 3 or not structure_placement_error(anchor, occupied).is_empty():
		return false
	# Loaded saves may use the largest legal ID; reuse a free ID on wrap.
	if _next_structure_id > MAX_STRUCTURE_ID:
		_next_structure_id = 1
	while _structures.has(_next_structure_id):
		_next_structure_id += 1
		if _next_structure_id > MAX_STRUCTURE_ID:
			_next_structure_id = 1
	var id: int = _next_structure_id
	_next_structure_id += 1
	_structures[id] = {"id": id, "anchor": anchor, "block": Block.STRUCTURE, "rotation": rotation}
	var cells: Array[Vector3i] = structure_footprint(anchor)
	for cell: Vector3i in cells:
		_structure_cells[cell] = id
		_set_block(cell, Block.STRUCTURE)
	# Publish only after the complete footprint and ownership are coherent.
	for cell: Vector3i in cells:
		cell_changed.emit(cell)
	return true


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
		Block.STRUCTURE:
			return "Test structure"
		_:
			return "Air"


func generate_flat() -> void:
	_chunks.clear()
	_differences.clear()
	_structure_cells.clear()
	_structures.clear()
	_next_structure_id = 1
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


func restore_chunks(
	flat: bool, chunks: Dictionary[Vector3i, PackedByteArray], structures: Array = []
) -> bool:
	# Validate everything before mutating the live rules.
	var placeholders: Dictionary[Vector3i, bool] = {}
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
			if index >= CHUNK_VOLUME or index <= previous or block > Block.STRUCTURE:
				return false
			if block == Block.BEDROCK or (flat and cell.y == -4):
				return false
			previous = index
			if block == Block.STRUCTURE:
				placeholders[cell] = true
	var owners: Dictionary[Vector3i, int] = {}
	var instances: Dictionary[int, Dictionary] = {}
	var next_id: int = 1
	if structures.size() > (64 * 64 * 64) / 27.0:
		return false
	for value: Variant in structures:
		if not value is Dictionary:
			return false
		var row: Dictionary = value
		if not SnapshotValues.integer(row.get("id"), 1, MAX_STRUCTURE_ID) or (
			row.get("block") != Block.STRUCTURE or not row.get("block") is int
			or not row.get("anchor") is Vector3i
			or not SnapshotValues.integer(row.get("rotation"), 0, 3)
		):
			return false
		var id: int = row["id"]
		var anchor: Vector3i = row["anchor"]
		if instances.has(id) or not is_in_bounds(anchor):
			return false
		for cell: Vector3i in structure_footprint(anchor):
			if not is_in_bounds(cell) or owners.has(cell) or not placeholders.has(cell):
				return false
			owners[cell] = id
		instances[id] = {"id": id, "anchor": anchor, "block": Block.STRUCTURE, "rotation": row["rotation"]}
		next_id = maxi(next_id, id + 1)
	if owners.size() != placeholders.size():
		return false
	_chunks.clear()
	_differences.clear()
	_structure_cells = owners
	_structures = instances
	_next_structure_id = next_id
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
	if _structure_cells.has(cell):
		var id: int = _structure_cells[cell]
		var anchor: Vector3i = _structures[id]["anchor"]
		var cells: Array[Vector3i] = structure_footprint(anchor)
		_structures.erase(id)
		for part: Vector3i in cells:
			_structure_cells.erase(part)
			_set_block(part, Block.AIR)
		for part: Vector3i in cells:
			cell_changed.emit(part)
		return true
	_set_block(cell, Block.AIR)
	cell_changed.emit(cell)
	return true


func place_block(cell: Vector3i, block: int, occupied_bounds: AABB = AABB()) -> bool:
	if block == Block.STRUCTURE:
		return place_structure(cell, 0, occupied_bounds)
	if block not in [Block.GRASS, Block.DIRT, Block.STONE, Block.MINER, Block.BELT, Block.CHEST]:
		return false
	if not is_in_bounds(cell) or get_block(cell) != Block.AIR:
		return false
	if occupied_bounds.has_volume() and block_bounds(cell, block).intersects(occupied_bounds):
		return false
	_set_block(cell, block)
	cell_changed.emit(cell)
	return true
