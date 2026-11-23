class_name BeltRingTransport
extends RefCounted
## Uniform full flat rings rotate identities once per exit batch. Ore objects
## stay in their original storage until an edit explicitly materializes them.

var active: bool = false
var ticks: int = 0
var exits: int = 0
var machine_visits: int = 0
var ore_visits: int = 0
var materialized_ores: int = 0
var work: int = 0
var _phase: float = 0.0
var _shift: int = 0
var _exit_count: int = 0
var _last_exit_tick: int = -1
var _advanced: bool = false
var _eligible: int = 2
var _indices: Array[int] = []
var _positions: Array[int] = []
var _ports: Array[int] = []
var _ores: Array[LogisticsOre] = []
var _incoming: Array[Vector3i] = []
var _inventories: Array[int] = []


func prepare(topology: LogisticsTopology) -> bool:
	if active:
		return true
	if topology.dirty or topology.machines.is_empty():
		return false
	clear()
	var first: int = -1
	var belt_count: int = 0
	for index: int in range(topology.machines.size()):
		machine_visits += 1
		var machine: LogisticsMachine = topology.machines[index]
		if VoxelWorldData.is_belt(machine.block):
			if machine.block != VoxelWorldData.Block.BELT or machine.quantity != 2:
				clear()
				return false
			if first < 0:
				first = index
				_phase = machine.belt_ores[1].progress
			ore_visits += 2
			# Exact admission avoids approximating distinct initial phases.
			if machine.belt_ores[1].progress != _phase or machine.belt_ores[0].progress != _phase + 0.5:
				clear()
				return false
			belt_count += 1
		else:
			_inventories.append(index)
	if first < 0:
		clear()
		return false
	_positions.resize(topology.machines.size())
	_positions.fill(-1)
	var cursor: int = first
	while cursor >= 0 and _positions[cursor] < 0:
		machine_visits += 1
		var machine: LogisticsMachine = topology.machines[cursor]
		if machine.block != VoxelWorldData.Block.BELT:
			break
		_positions[cursor] = _indices.size()
		_indices.append(cursor)
		_ores.append(machine.belt_ores[1])
		_ores.append(machine.belt_ores[0])
		_incoming.append(machine.belt_ores[1].incoming_direction)
		_incoming.append(machine.belt_ores[0].incoming_direction)
		ore_visits += 2
		cursor = topology.outgoing[cursor]
	if cursor != first or _indices.size() != belt_count:
		clear()
		return false
	for index: int in _inventories:
		machine_visits += 1
		var target: int = topology.outgoing[index]
		if (target >= 0 and _positions[target] < 0) or (
			topology.inputs[index * 3] >= 0 or topology.inputs[index * 3 + 1] >= 0
			or topology.inputs[index * 3 + 2] >= 0
		):
			clear()
			return false
	for position: int in range(_indices.size()):
		var index: int = _indices[position]
		var predecessor: int = _indices[posmod(position - 1, _indices.size())]
		var port: int = -1
		for input_port: int in range(3):
			if topology.inputs[index * 3 + input_port] == predecessor:
				port = input_port
		assert(port >= 0)
		_ports.append(port)
		machine_visits += 1
	active = true
	return true


func advance_tick(topology: LogisticsTopology, tick: int) -> void:
	work = 1
	ticks += 1
	_phase += LogisticsData.LOGIC_STEP / LogisticsData.BELT_TRAVEL_TIME
	_advanced = true
	_eligible = 2
	if _phase >= 0.5 - LogisticsData.TIME_EPSILON:
		_phase = 0.0
		_shift = (_shift + 1) % _ores.size()
		_exit_count += 1
		_last_exit_tick = tick
		_eligible = 1
		exits += 1
	# Full-cycle internal reservations forbid every external insertion.
	# Production and inventory eligibility still settle each formal tick.
	for index: int in _inventories:
		machine_visits += 1
		work += 1
		var machine: LogisticsMachine = topology.machines[index]
		machine.produce_until(float(tick) * LogisticsData.LOGIC_STEP)
		machine.eligible_quantity = machine.quantity


func contains(index: int) -> bool:
	return active and _positions[index] >= 0


func save_row(topology: LogisticsTopology, index: int) -> Dictionary:
	var row: Dictionary = topology.machines[index].save_state()
	var position: int = _positions[index]
	var ores: Array[Dictionary] = []
	for slot: int in range(2):
		ores.append({
			"id": _ore_at(position, slot).id,
			"incoming": _direction_at(topology, position, slot),
			"progress": _phase + (0.5 if slot == 0 else 0.0),
		})
	row["ores"] = ores
	if _advanced:
		row["eligible"] = _eligible
	if _exit_count > 0:
		row["last_output"] = _last_exit_tick
		row["cursor"] = (_ports[position] + 1) % 3
	return row


func write_row(bytes: PackedByteArray, topology: LogisticsTopology, index: int, destination: int = -1) -> void:
	var row_index: int = index if destination < 0 else destination
	LogisticsPacked.write_row(bytes, row_index, topology.cells[index], topology.machines[index])
	var position: int = _positions[index]
	var offset: int = row_index * LogisticsPacked.ROW_SIZE
	if _advanced:
		bytes.encode_s64(offset + 24, _eligible)
	if _exit_count > 0:
		bytes.encode_s64(offset + 32, _last_exit_tick)
		bytes[offset + 15] = (_ports[position] + 1) % 3
	for slot: int in range(2):
		var ore_offset: int = offset + 88 + slot * 24
		bytes.encode_s64(ore_offset, _ore_at(position, slot).id)
		bytes[ore_offset + 8] = LogisticsPacked.DIRECTIONS.find(_direction_at(topology, position, slot))
		bytes.encode_double(ore_offset + 16, _phase + (0.5 if slot == 0 else 0.0))


func refresh_prediction(queue: LogisticsOreQueue, topology: LogisticsTopology, index: int) -> int:
	var created: int = queue.refresh_prediction(topology.machines[index], topology.cells[index])
	var position: int = _positions[index]
	for slot: int in range(2):
		var cached: LogisticsOre = queue.ores[slot]
		cached.id = _ore_at(position, slot).id
		cached.incoming_direction = _direction_at(topology, position, slot)
		cached.progress = _phase + (0.5 if slot == 0 else 0.0)
	return created


func materialize(topology: LogisticsTopology) -> void:
	for position: int in range(_indices.size()):
		machine_visits += 1
		var machine: LogisticsMachine = topology.machines[_indices[position]]
		if _advanced:
			machine.eligible_quantity = _eligible
		if _exit_count > 0:
			machine.last_output_tick = _last_exit_tick
			machine.input_cursor = (_ports[position] + 1) % 3
		for slot: int in range(2):
			var ore: LogisticsOre = _ore_at(position, slot)
			ore.progress = _phase + (0.5 if slot == 0 else 0.0)
			ore.incoming_direction = _direction_at(topology, position, slot)
			machine.belt_ores[slot] = ore
			ore_visits += 1
			materialized_ores += 1


func clear() -> void:
	active = false
	_phase = 0.0
	_shift = 0
	_exit_count = 0
	_last_exit_tick = -1
	_advanced = false
	_indices.clear()
	_positions.clear()
	_ports.clear()
	_ores.clear()
	_incoming.clear()
	_inventories.clear()


func _ore_at(position: int, slot: int) -> LogisticsOre:
	return _ores[posmod(position * 2 + (1 if slot == 0 else 0) - _shift, _ores.size())]


func _direction_at(topology: LogisticsTopology, position: int, slot: int) -> Vector3i:
	if _exit_count == 0:
		return _incoming[position * 2 + (1 if slot == 0 else 0)]
	if _exit_count == 1 and slot == 0:
		return _incoming[position * 2]
	var predecessor: int = _indices[posmod(position - 1, _indices.size())]
	return topology.machines[predecessor].settled_direction
