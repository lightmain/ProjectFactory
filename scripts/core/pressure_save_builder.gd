class_name PressureSaveBuilder
extends RefCounted
## Dense serpentine layers. Two empty columns leave room for the player's box;
## a third perimeter column returns each ramp outlet to the next layer's start.

var last_error: String = ""
var _path: Array[Vector3i] = []
var _world: VoxelWorldData


func build(size: int = 128, height: int = 64) -> SessionSnapshot:
	last_error = ""
	if size < 8 or size > 128 or size % 2 != 0 or height < 6 or height > 128:
		last_error = "尺寸须为 8～128 的偶数，高度须为 6～128。"
		return null
	_path.clear()
	var low: int = -size / 2
	var high: int = low + size
	_world = VoxelWorldData.new()
	_world.generate_flat(Vector3i(low, -1, low), Vector3i(high, height - 1, high), 1)
	# Three merging feeder belts; a fourth is the head, accepting two inputs.
	for z: int in range(low + 3, low - 1, -1):
		_path.append(Vector3i(low + 1, 0, z))
	_path.append(Vector3i(low + 2, 0, low))
	for y: int in range(height - 1):
		if y > 0:
			for z: int in range(high - 1, low - 1, -1):
				_path.append(Vector3i(low, y, z))
			_path.append(Vector3i(low + 1, y, low))
			_path.append(Vector3i(low + 2, y, low))
		for row: int in range(size):
			for column: int in range(size - 3):
				var x: int = low + 3 + (column if row % 2 == 0 else size - 4 - column)
				_path.append(Vector3i(x, y, low + row))
		if y < height - 2:
			_path.append(Vector3i(low + 2, y, high - 1))
			_path.append(Vector3i(low + 1, y, high - 1))
	for index: int in range(_path.size()):
		var cell: Vector3i = _path[index]
		var block: int = VoxelWorldData.Block.BELT
		if index == _path.size() - 1:
			block = VoxelWorldData.Block.CHEST
		elif _path[index + 1].y > cell.y:
			block = VoxelWorldData.Block.BELT_UP_WEST
		if not _world.place_block(cell, block):
			last_error = "线路方块无法放置：%s" % cell
			return null
	for z: int in range(low, low + 4):
		if not _world.place_block(Vector3i(low, 0, z), VoxelWorldData.Block.MINER):
			last_error = "矿机无法放置。"
			return null
	var snapshot: SessionSnapshot = SessionSnapshot.new()
	snapshot.world = _world
	snapshot.logistics.bind_world(_world)
	for index: int in range(_path.size()):
		var direction: Vector3i = Vector3i.LEFT if index == _path.size() - 1 else _path[index + 1] - _path[index]
		direction.y = 0
		snapshot.logistics.set_direction(_path[index], direction)
	for z: int in range(low, low + 4):
		snapshot.logistics.set_direction(Vector3i(low, 0, z), Vector3i.RIGHT)
	if not snapshot.logistics.prefill_belts():
		last_error = "矿石预填失败。"
		return null
	snapshot.position = Vector3(float(low + 2) * 0.5, 0.01, float(low) * 0.5 + 2.75)
	snapshot.spawn = snapshot.position
	snapshot.velocity = Vector3.ZERO
	snapshot.view_rotation = Vector3(-0.15, -PI * 0.5, 0)
	snapshot.selected_block = VoxelWorldData.Block.BELT
	snapshot.build_rotation = 0
	snapshot.world_id = "pressure_%d_%d" % [size, height]
	snapshot.world_id = snapshot.world_id.md5_text()
	snapshot.world_name = "压力测试 %d×%d×%d" % [size, size, height]
	_path.clear()
	_world = null
	return snapshot


static func state_for(snapshot: SessionSnapshot) -> Dictionary:
	return {
		"version": SessionSnapshot.FORMAT_VERSION, "generator": SessionSnapshot.GENERATOR_VERSION,
		"minimum": snapshot.world.minimum, "maximum": snapshot.world.maximum,
		"floor_depth": snapshot.world.floor_depth, "flat": snapshot.world.has_flat_baseline(),
		"chunks": snapshot.world.chunk_deltas(), "structures": snapshot.world.structure_rows(),
		"logistics": snapshot.logistics.save_packed_state(), "inventory": snapshot.inventory.save_state(),
		"world_id": snapshot.world_id, "world_name": snapshot.world_name,
		"player": {"position": snapshot.position, "spawn": snapshot.spawn, "velocity": snapshot.velocity,
			"rotation": snapshot.view_rotation, "tool": snapshot.selected_block, "build_rotation": snapshot.build_rotation},
	}


static func route_certificate(snapshot: SessionSnapshot) -> Dictionary:
	## Linear audit of the settled graph, including the file restored at full size.
	var state: Dictionary = snapshot.logistics.save_packed_state()
	if state["dirty"]:
		return {}
	var bytes: PackedByteArray = state["machines"]
	var outgoing: PackedInt32Array = state["outgoing"]
	var cells: Array[Vector3i] = snapshot.logistics.machine_cells()
	var predecessors: PackedInt32Array = PackedInt32Array()
	predecessors.resize(cells.size())
	predecessors.fill(0)
	var miners: int = 0
	var belts: int = 0
	var slopes: int = 0
	var sink: int = -1
	for index: int in range(cells.size()):
		var block: int = bytes[index * LogisticsPacked.ROW_SIZE + 12]
		var target: int = outgoing[index]
		if block == VoxelWorldData.Block.CHEST:
			if sink >= 0 or target != -1:
				return {}
			sink = index
			continue
		if target < 0 or target >= cells.size():
			return {}
		var target_block: int = bytes[target * LogisticsPacked.ROW_SIZE + 12]
		var direction: Vector3i = LogisticsPacked.DIRECTIONS[bytes[index * LogisticsPacked.ROW_SIZE + 14]]
		if cells[index] + direction + Vector3i.UP * VoxelWorldData.outlet_step(block) != (
			cells[target] + Vector3i.UP * VoxelWorldData.inlet_step(target_block)
		):
			return {}
		if block == VoxelWorldData.Block.MINER:
			miners += 1
			if not VoxelWorldData.is_belt(target_block):
				return {}
		elif VoxelWorldData.is_belt(block):
			belts += 1
			if VoxelWorldData.is_slope(block):
				slopes += 1
			if not VoxelWorldData.is_belt(target_block) and target_block != VoxelWorldData.Block.CHEST:
				return {}
			predecessors[target] += 1
		else:
			return {}
	if miners != 4 or sink < 0 or predecessors[sink] != 1:
		return {}
	var head: int = -1
	for index: int in range(cells.size()):
		if not VoxelWorldData.is_belt(bytes[index * LogisticsPacked.ROW_SIZE + 12]):
			continue
		if predecessors[index] == 0:
			if head >= 0:
				return {}
			head = index
		elif predecessors[index] != 1:
			return {}
	var cursor: int = head
	var visited: int = 0
	while cursor >= 0 and cursor != sink and visited <= belts:
		cursor = outgoing[cursor]
		visited += 1
	if cursor != sink or visited != belts:
		return {}
	return {"belts": belts, "visited_belts": visited, "miners": miners, "chests": 1,
		"slopes": slopes, "head": cells[head], "sink": cells[sink]}
