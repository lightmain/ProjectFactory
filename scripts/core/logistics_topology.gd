class_name LogisticsTopology
extends RefCounted
## Dense active facilities, bounded direct cell lookup and settled adjacency.
## Edits touch at most three predecessors and one successor; rebuild is batched.

const CANDIDATE_PARTITION_SIZE: int = 8

var _extent: Vector3i = VoxelWorldData.MAX_CELL - VoxelWorldData.MIN_CELL
var _minimum: Vector3i = VoxelWorldData.MIN_CELL

var cells: Array[Vector3i] = []
var machines: Array[LogisticsMachine] = []
var outgoing: Array[int] = []
var inputs: Array[int] = []
var dirty: bool = true
var work: int = 0
var _slots: PackedInt32Array = PackedInt32Array()
var _sparse: bool = false
var _lookup: Dictionary[Vector3i, int] = {}
var _pending_cells: Dictionary[Vector3i, bool] = {}
var _candidate_partitions: Dictionary[Vector3i, Dictionary] = {}
var candidate_partition_visits: int = 0
var candidate_checks: int = 0
var candidate_copies: int = 0


func _init(sparse: bool = false) -> void:
	_sparse = sparse
	clear()


func clear(world: VoxelWorldData = null) -> void:
	if world != null:
		_minimum = world.minimum
		_extent = world.maximum - world.minimum
	cells.clear()
	machines.clear()
	outgoing.clear()
	inputs.clear()
	_candidate_partitions.clear()
	_lookup.clear()
	_pending_cells.clear()
	_reset_candidate_work()
	_slots.resize(0 if _sparse else _extent.x * _extent.y * _extent.z)
	_slots.fill(-1)
	dirty = true


func index_at(cell: Vector3i) -> int:
	if _sparse:
		return _lookup.get(cell, -1)
	var local: Vector3i = cell - _minimum
	if (
		local.x < 0 or local.y < 0 or local.z < 0
		or local.x >= _extent.x or local.y >= _extent.y or local.z >= _extent.z
	):
		return -1
	return _slots[_address(local)]


func add(cell: Vector3i, machine: LogisticsMachine) -> void:
	var partition: Vector3i = _candidate_partition(cell)
	if not _candidate_partitions.has(partition):
		_candidate_partitions[partition] = {}
	var entries: Dictionary = _candidate_partitions[partition]
	entries[cell] = true
	_set_index(cell, machines.size())
	cells.append(cell)
	machines.append(machine)
	outgoing.append(-1)
	for port: int in range(3):
		inputs.append(-1)
	dirty = true
	mark_changed(cell)


func remove(index: int) -> void:
	var cell: Vector3i = cells[index]
	var partition: Vector3i = _candidate_partition(cell)
	var entries: Dictionary = _candidate_partitions[partition]
	entries.erase(cell)
	if entries.is_empty():
		_candidate_partitions.erase(partition)
	# Disconnect old adjacency before compacting. Sampling sees no removed ores.
	var target: int = outgoing[index]
	if target >= 0:
		for port: int in range(3):
			if inputs[target * 3 + port] == index:
				inputs[target * 3 + port] = -1
	for port: int in range(3):
		var source: int = inputs[index * 3 + port]
		if source >= 0:
			outgoing[source] = -1
	_set_index(cells[index], -1)
	var last: int = machines.size() - 1
	if index != last:
		cells[index] = cells[last]
		machines[index] = machines[last]
		outgoing[index] = outgoing[last]
		for port: int in range(3):
			inputs[index * 3 + port] = inputs[last * 3 + port]
			var source: int = inputs[index * 3 + port]
			if source >= 0:
				outgoing[source] = index
		target = outgoing[index]
		if target >= 0:
			for port: int in range(3):
				if inputs[target * 3 + port] == last:
					inputs[target * 3 + port] = index
		_set_index(cells[index], index)
	cells.pop_back()
	machines.pop_back()
	outgoing.pop_back()
	inputs.resize(last * 3)
	dirty = true
	mark_changed(cell)


func _set_index(cell: Vector3i, index: int) -> void:
	if _sparse:
		if index < 0:
			_lookup.erase(cell)
		else:
			_lookup[cell] = index
	else:
		_slots[_address(cell - _minimum)] = index


static func edit_neighborhood(cell: Vector3i) -> Array[Vector3i]:
	var result: Array[Vector3i] = [cell]
	for facing: Vector3i in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]:
		for height: int in range(-1, 2):
			result.append(cell + facing + Vector3i.UP * height)
	return result


func mark_changed(cell: Vector3i) -> void:
	dirty = true
	for nearby: Vector3i in edit_neighborhood(cell):
		_pending_cells[nearby] = true


func accept_settled() -> void:
	## Borrowed regional adjacency has already been copied from its owner.
	_pending_cells.clear()
	dirty = false


func rebuild_pending() -> void:
	## Only edited facilities and possible inlet targets change their edges.
	work = 0
	var targets: Array[int] = []
	for cell: Vector3i in _pending_cells:
		work += 1
		var index: int = index_at(cell)
		if index >= 0:
			targets.append(index)
	targets.sort()
	for target: int in targets:
		for port: int in range(3):
			work += 1
			var source: int = inputs[target * 3 + port]
			if source >= 0:
				outgoing[source] = -1
			inputs[target * 3 + port] = -1
		_settle_direction(machines[target])
	for target: int in targets:
		_connect_inputs(target)
	_pending_cells.clear()
	dirty = false


func candidate_cells(minimum: Vector3i, maximum: Vector3i) -> Array[Vector3i]:
	_reset_candidate_work()
	var result: Array[Vector3i] = []
	var low: Vector3i = minimum.max(_minimum)
	var high: Vector3i = maximum.min(_minimum + _extent - Vector3i.ONE)
	if low.x > high.x or low.y > high.y or low.z > high.z:
		return result
	var first: Vector3i = _candidate_partition(low)
	var last: Vector3i = _candidate_partition(high)
	for y: int in range(first.y, last.y + 1):
		for z: int in range(first.z, last.z + 1):
			for x: int in range(first.x, last.x + 1):
				candidate_partition_visits += 1
				var partition: Vector3i = Vector3i(x, y, z)
				if not _candidate_partitions.has(partition):
					continue
				var entries: Dictionary = _candidate_partitions[partition]
				for cell: Vector3i in entries:
					candidate_checks += 1
					if (
						cell.x >= low.x and cell.x <= high.x
						and cell.y >= low.y and cell.y <= high.y
						and cell.z >= low.z and cell.z <= high.z
					):
						result.append(cell)
						candidate_copies += 1
	return result


func candidate_partition_count() -> int:
	return _candidate_partitions.size()


func _reset_candidate_work() -> void:
	candidate_partition_visits = 0
	candidate_checks = 0
	candidate_copies = 0


static func _candidate_partition(cell: Vector3i) -> Vector3i:
	return Vector3i(
		floori(float(cell.x) / CANDIDATE_PARTITION_SIZE),
		floori(float(cell.y) / CANDIDATE_PARTITION_SIZE),
		floori(float(cell.z) / CANDIDATE_PARTITION_SIZE)
	)


func rebuild() -> void:
	work = 0
	outgoing.fill(-1)
	inputs.fill(-1)
	for machine: LogisticsMachine in machines:
		work += 1
		_settle_direction(machine)
	for target: int in range(machines.size()):
		_connect_inputs(target)
	_pending_cells.clear()
	dirty = false


func _settle_direction(machine: LogisticsMachine) -> void:
	# Apply the final requested rotation once, at the same boundary as edges.
	var facing: Vector3i = machine.settled_direction
	while facing != machine.direction:
		facing = Vector3i(-facing.z, 0, facing.x)
		for ore: LogisticsOre in machine.belt_ores:
			work += 1
			ore.incoming_direction = Vector3i(-ore.incoming_direction.z, 0, ore.incoming_direction.x)
	machine.settled_direction = machine.direction


func _connect_inputs(target: int) -> void:
	work += 1
	var machine: LogisticsMachine = machines[target]
	if machine.block == VoxelWorldData.Block.MINER:
		return
	for port: int in range(input_count(machine.block)):
		var direction: Vector3i = port_direction(machine.settled_direction, port)
		var base: Vector3i = cells[target] - direction + Vector3i.UP * VoxelWorldData.inlet_step(machine.block)
		for height: int in range(2):
			work += 1
			var source: int = index_at(base + Vector3i.DOWN * height)
			if source >= 0 and connects(source, target, port):
				inputs[target * 3 + port] = source
				outgoing[source] = target
				break


static func input_count(block: int) -> int:
	return 0 if block == VoxelWorldData.Block.MINER else (3 if block == VoxelWorldData.Block.BELT else 1)


static func port_direction(facing: Vector3i, port: int) -> Vector3i:
	var side: Vector3i = Vector3i(-facing.z, 0, facing.x)
	return facing if port == 0 else (side if port == 1 else -side)


func connects(source: int, target: int, port: int) -> bool:
	var machine: LogisticsMachine = machines[target]
	if port >= input_count(machine.block):
		return false
	var direction: Vector3i = port_direction(machine.settled_direction, port)
	return machines[source].settled_direction == direction and (
		cells[source] + direction + Vector3i.UP * VoxelWorldData.outlet_step(machines[source].block)
		== cells[target] + Vector3i.UP * VoxelWorldData.inlet_step(machine.block)
	)


func _address(local: Vector3i) -> int:
	return (local.y * _extent.z + local.z) * _extent.x + local.x
