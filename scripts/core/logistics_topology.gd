class_name LogisticsTopology
extends RefCounted
## Dense active facilities, bounded direct cell lookup and settled adjacency.
## Edits touch at most three predecessors and one successor; rebuild is batched.

var _extent: Vector3i = VoxelWorldData.MAX_CELL - VoxelWorldData.MIN_CELL
var _minimum: Vector3i = VoxelWorldData.MIN_CELL

var cells: Array[Vector3i] = []
var machines: Array[LogisticsMachine] = []
var outgoing: Array[int] = []
var inputs: Array[int] = []
var dirty: bool = true
var work: int = 0
var _slots: PackedInt32Array = PackedInt32Array()


func _init() -> void:
	clear()


func clear(world: VoxelWorldData = null) -> void:
	if world != null:
		_minimum = world.minimum
		_extent = world.maximum - world.minimum
	cells.clear()
	machines.clear()
	outgoing.clear()
	inputs.clear()
	_slots.resize(_extent.x * _extent.y * _extent.z)
	_slots.fill(-1)
	dirty = true


func index_at(cell: Vector3i) -> int:
	var local: Vector3i = cell - _minimum
	if (
		local.x < 0 or local.y < 0 or local.z < 0
		or local.x >= _extent.x or local.y >= _extent.y or local.z >= _extent.z
	):
		return -1
	return _slots[_address(local)]


func add(cell: Vector3i, machine: LogisticsMachine) -> void:
	_slots[_address(cell - _minimum)] = machines.size()
	cells.append(cell)
	machines.append(machine)
	outgoing.append(-1)
	for port: int in range(3):
		inputs.append(-1)
	dirty = true


func remove(index: int) -> void:
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
	_slots[_address(cells[index] - _minimum)] = -1
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
		_slots[_address(cells[index] - _minimum)] = index
	cells.pop_back()
	machines.pop_back()
	outgoing.pop_back()
	inputs.resize(last * 3)
	dirty = true


func rebuild() -> void:
	work = 0
	outgoing.fill(-1)
	inputs.fill(-1)
	for machine: LogisticsMachine in machines:
		work += 1
		# Apply the final requested rotation once, at the same boundary as edges.
		var facing: Vector3i = machine.settled_direction
		while facing != machine.direction:
			facing = Vector3i(-facing.z, 0, facing.x)
			for ore: LogisticsOre in machine.belt_ores:
				ore.incoming_direction = Vector3i(
					-ore.incoming_direction.z, 0, ore.incoming_direction.x
				)
		machine.settled_direction = machine.direction
	for target: int in range(machines.size()):
		work += 1
		var machine: LogisticsMachine = machines[target]
		if machine.block == VoxelWorldData.Block.MINER:
			continue
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
	dirty = false


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
