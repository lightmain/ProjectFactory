class_name PressureSaveBuilder
extends RefCounted
## Dense serpentine layers. Two empty columns leave room for the player's box;
## a third perimeter column returns each ramp outlet to the next layer's start.

var last_error: String = ""
var _path: Array[Vector3i] = []
var _world: VoxelWorldData


func build(size: int = 128, height: int = 64, backend: String = "gdscript") -> SessionSnapshot:
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
	if backend == "rust" and not snapshot.logistics.enable_rust_transport():
		last_error = snapshot.logistics.transport_error()
		return null
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


func build_complex(backend: String = "gdscript") -> SessionSnapshot:
	## Fixed deterministic workload: two merges, three loop loads and a chest chain.
	last_error = ""
	var snapshot: SessionSnapshot = SessionSnapshot.new()
	snapshot.world.generate_flat(Vector3i(-16, -1, -16), Vector3i(16, 15, 16), 1)
	var directions: Dictionary[Vector3i, Vector3i] = {}
	for x: int in range(-8, 8):
		_complex_place(snapshot, directions, Vector3i(x, 0, -4), VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	_complex_place(snapshot, directions, Vector3i(8, 0, -4), VoxelWorldData.Block.CHEST, Vector3i.RIGHT)
	_complex_place(snapshot, directions, Vector3i(-9, 0, -4), VoxelWorldData.Block.MINER, Vector3i.RIGHT)
	for x: int in [-4, 3]:
		for z: int in range(-3, 0):
			_complex_place(snapshot, directions, Vector3i(x, 0, z), VoxelWorldData.Block.BELT, Vector3i.FORWARD)
		_complex_place(snapshot, directions, Vector3i(x, 0, 0), VoxelWorldData.Block.MINER, Vector3i.FORWARD)
	for x: int in range(-8, -5):
		_complex_place(snapshot, directions, Vector3i(x, 0, 4), VoxelWorldData.Block.CHEST, Vector3i.RIGHT)
	for anchor: Vector3i in [Vector3i(-3, 0, 4), Vector3i(3, 0, 4), Vector3i(8, 0, 4)]:
		var ring: Array[Vector3i] = [anchor, anchor + Vector3i.RIGHT,
			anchor + Vector3i.RIGHT + Vector3i.BACK, anchor + Vector3i.BACK]
		for index: int in range(ring.size()):
			_complex_place(snapshot, directions, ring[index], VoxelWorldData.Block.BELT,
				ring[(index + 1) % ring.size()] - ring[index])
	if not last_error.is_empty() or backend not in ["gdscript", "rust"]:
		return null
	snapshot.logistics.bind_world(snapshot.world, 0.17, 2)
	for cell: Vector3i in directions:
		snapshot.logistics.set_direction(cell, directions[cell])
	if not snapshot.logistics.prefill_belts():
		return null
	var state: Dictionary = snapshot.logistics.save_state()
	var rows: Array = state["machines"]
	for row: Dictionary in rows:
		var cell: Vector3i = row["cell"]
		if cell.z >= 4 and cell.x in [-3, -2, 3, 4]:
			var ores: Array = row["ores"]
			ores.clear()
			if cell == Vector3i(3, 0, 4):
				ores.append({"id": state["next_id"], "incoming": Vector3i.FORWARD, "progress": 0.1})
				state["next_id"] += 1
			row["quantity"] = ores.size()
			row["eligible"] = ores.size()
		if cell == Vector3i(-8, 0, 4):
			row["quantity"] = 7
			row["eligible"] = 7
	if not snapshot.logistics.restore_state(state) or (
		backend == "rust" and not snapshot.logistics.enable_rust_transport()
	):
		last_error = snapshot.logistics.transport_error()
		return null
	snapshot.position = Vector3(-6, 0.01, -5)
	snapshot.spawn = snapshot.position
	snapshot.view_rotation = Vector3(-0.25, -PI * 0.5, 0)
	snapshot.selected_block = VoxelWorldData.Block.BELT
	snapshot.world_id = "complex_factory_v1".md5_text()
	snapshot.world_name = "综合工厂 v1"
	return snapshot


func _complex_place(snapshot: SessionSnapshot, directions: Dictionary[Vector3i, Vector3i],
		cell: Vector3i, block: int, direction: Vector3i) -> void:
	if not snapshot.world.place_block(cell, block):
		last_error = "综合工厂无法放置：%s" % cell
	directions[cell] = direction


static func complex_certificate(snapshot: SessionSnapshot) -> Dictionary:
	var state: Dictionary = snapshot.logistics.save_packed_state()
	if state.is_empty() or state["dirty"]:
		return {}
	var bytes: PackedByteArray = state["machines"]
	var cells: Array[Vector3i] = snapshot.logistics.machine_cells()
	var inventory_cells: Array[Vector3i] = []
	var producers: Array[Vector3i] = []
	var belts: int = 0
	var incoming_counts: PackedInt32Array = PackedInt32Array()
	incoming_counts.resize(cells.size())
	incoming_counts.fill(0)
	var outgoing: PackedInt32Array = state["outgoing"]
	for target: int in outgoing:
		if target >= 0:
			incoming_counts[target] += 1
	for index: int in range(cells.size()):
		var block: int = bytes[index * LogisticsPacked.ROW_SIZE + 12]
		if VoxelWorldData.is_belt(block):
			belts += 1
		else:
			inventory_cells.append(cells[index])
			if block == VoxelWorldData.Block.MINER:
				producers.append(cells[index])
	var merges: int = 0
	for incoming: int in incoming_counts:
		merges += 1 if incoming > 1 else 0
	var walks: PackedInt32Array = PackedInt32Array()
	walks.resize(cells.size())
	walks.fill(0)
	var loops: int = 0
	for index: int in range(cells.size()):
		if walks[index] != 0:
			continue
		var cursor: int = index
		while cursor >= 0 and walks[cursor] == 0:
			walks[cursor] = index + 1
			cursor = outgoing[cursor]
		if cursor >= 0 and walks[cursor] == index + 1:
			loops += 1
	if loops != 3 or merges != 2 or belts != 34 or producers.size() != 3 or inventory_cells.size() != 7:
		return {}
	return {"fixture": "complex_v1", "seed": 0, "belts": belts,
		"miners": producers.size(), "chests": inventory_cells.size() - producers.size(),
		"producer_cells": producers, "inventory_cells": inventory_cells,
		"sink": Vector3i(8, 0, -4), "loops": loops, "merges": merges,
		"topology_sha256": SaveGameFiles.digest(var_to_bytes([bytes, state["outgoing"], state["inputs"]])).hex_encode()}


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
	if state.is_empty() or state["dirty"]:
		return {}
	var bytes: PackedByteArray = state["machines"]
	var outgoing: PackedInt32Array = state["outgoing"]
	var cells: Array[Vector3i] = snapshot.logistics.machine_cells()
	var predecessors: PackedInt32Array = PackedInt32Array()
	predecessors.resize(cells.size())
	predecessors.fill(0)
	var miners: int = 0
	var producer_cells: Array[Vector3i] = []
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
			producer_cells.append(cells[index])
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
		"producer_cells": producer_cells,
		"slopes": slopes, "head": cells[head], "sink": cells[sink]}
