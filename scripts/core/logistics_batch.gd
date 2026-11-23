class_name LogisticsBatch
extends RefCounted
## One target candidate and one output per facility. Rejections follow only
## the single dependent incoming candidate; no array deletion or rescanning.

var work: int = 0
var transfers: int = 0
var next_ore_id: int = 1
var workspace_growths: int = 0
var defer_identity: bool = false
var created_ores: Dictionary[Vector3i, LogisticsOre] = {}
var _capacity: int = 0
var _sources: Array[int] = []
var _ports: Array[int] = []
var _amounts: Array[int] = []
var _valid: Array[bool] = []
var _output_targets: Array[int] = []
var _moved_ores: Array[LogisticsOre] = []
var _rejected: Array[int] = []
var _ready: Array[bool] = []
var _states: Array[int] = []
var _stack_indices: Array[int] = []
var _predecessors: Array[int] = []
var _stack: Array[int] = []


func capacity() -> int:
	return _capacity


func clear() -> void:
	_resize(0)


func _resize(size: int) -> void:
	if size == _capacity:
		return
	if size > _capacity:
		workspace_growths += 1
	_capacity = size
	_sources.resize(size)
	_ports.resize(size)
	_amounts.resize(size)
	_valid.resize(size)
	_output_targets.resize(size)
	_moved_ores.resize(size)
	_rejected.resize(size)
	_ready.resize(size)
	_states.resize(size)
	_stack_indices.resize(size)
	_predecessors.resize(size)
	_stack.resize(size)


func transfer(topology: LogisticsTopology, tick: int) -> void:
	work = 0
	transfers = 0
	created_ores.clear()
	var size: int = topology.machines.size()
	_resize(size)
	var sources: Array[int] = _sources
	var ports: Array[int] = _ports
	var amounts: Array[int] = _amounts
	var valid: Array[bool] = _valid
	var output_targets: Array[int] = _output_targets
	var moved_ores: Array[LogisticsOre] = _moved_ores
	sources.fill(-1)
	valid.fill(false)
	output_targets.fill(-1)
	moved_ores.fill(null)
	var cycle_inputs: Array[int] = _full_cycle_inputs(topology, tick)
	for target: int in range(size):
		work += 1
		var machine: LogisticsMachine = topology.machines[target]
		if machine.block == VoxelWorldData.Block.MINER:
			continue
		if machine.block == VoxelWorldData.Block.CHEST:
			var source: int = topology.inputs[target * 3]
			var amount: int = _available(topology, source, tick)
			if amount > 0:
				sources[target] = source
				amounts[target] = amount
				output_targets[source] = target
				valid[target] = true
			continue
		if not machine.belt_ores.is_empty() and machine.belt_ores[-1].progress < 0.5 - 1e-9:
			continue
		for offset: int in range(3):
			work += 1
			var port: int = (machine.input_cursor + offset) % 3
			var source: int = topology.inputs[target * 3 + port]
			if source < 0 or (cycle_inputs[target] >= 0 and source != cycle_inputs[target]):
				continue
			if _available(topology, source, tick) <= 0:
				if (
					VoxelWorldData.is_belt(topology.machines[source].block)
					and topology.machines[source].quantity > 0
				):
					break
				continue
			sources[target] = source
			ports[target] = port
			amounts[target] = 1
			output_targets[source] = target
			valid[target] = true
			break
	var rejected_count: int = 0
	for target: int in range(size):
		work += 1
		if valid[target] and _full(topology.machines[target]) and output_targets[target] < 0:
			valid[target] = false
			_rejected[rejected_count] = target
			rejected_count += 1
	var read: int = 0
	while read < rejected_count:
		work += 1
		var source: int = sources[_rejected[read]]
		read += 1
		# Candidate slots are indexed by target, so its dependent is slot[source].
		if valid[source] and _full(topology.machines[source]):
			valid[source] = false
			_rejected[rejected_count] = source
			rejected_count += 1
	for target: int in range(size):
		work += 1
		if not valid[target]:
			continue
		var source: LogisticsMachine = topology.machines[sources[target]]
		transfers += 1
		source.quantity -= amounts[target]
		source.eligible_quantity -= amounts[target]
		source.last_output_tick = tick
		if VoxelWorldData.is_belt(source.block):
			# A belt has at most two ores; this bounded shift is constant work.
			moved_ores[target] = source.belt_ores.pop_front()
	for target: int in range(size):
		work += 1
		if not valid[target]:
			continue
		var machine: LogisticsMachine = topology.machines[target]
		machine.quantity += amounts[target]
		var ore: LogisticsOre = moved_ores[target]
		# Inventory arrivals consume identity too; retire every scratch reference.
		moved_ores[target] = null
		if not VoxelWorldData.is_belt(machine.block):
			continue
		var incoming: Vector3i = topology.machines[sources[target]].settled_direction
		if ore == null:
			ore = LogisticsOre.new(0 if defer_identity else next_ore_id, incoming)
			if defer_identity:
				created_ores[topology.cells[target]] = ore
			else:
				next_ore_id += 1
		ore.incoming_direction = incoming
		ore.progress = 0.0
		machine.belt_ores.append(ore)
		machine.input_cursor = (ports[target] + 1) % 3


func _full_cycle_inputs(topology: LogisticsTopology, tick: int) -> Array[int]:
	var size: int = topology.machines.size()
	var ready: Array[bool] = _ready
	var states: Array[int] = _states
	var stack_indices: Array[int] = _stack_indices
	var predecessors: Array[int] = _predecessors
	states.fill(0)
	predecessors.fill(-1)
	for index: int in range(size):
		work += 1
		var machine: LogisticsMachine = topology.machines[index]
		ready[index] = (
			_full(machine) and _available(topology, index, tick) > 0
			and machine.belt_ores[-1].progress >= 0.5 - 1e-9
		)
	for start: int in range(size):
		work += 1
		if not ready[start] or states[start] != 0:
			continue
		var stack_size: int = 0
		var index: int = start
		while index >= 0 and ready[index] and states[index] == 0:
			work += 1
			states[index] = 1
			stack_indices[index] = stack_size
			_stack[stack_size] = index
			stack_size += 1
			index = topology.outgoing[index]
		if index >= 0 and states[index] == 1:
			for cursor: int in range(stack_indices[index], stack_size):
				work += 1
				var source: int = _stack[cursor]
				predecessors[topology.outgoing[source]] = source
		for cursor: int in range(stack_size):
			work += 1
			states[_stack[cursor]] = 2
	return predecessors


static func _available(topology: LogisticsTopology, index: int, tick: int) -> int:
	if index < 0:
		return 0
	var machine: LogisticsMachine = topology.machines[index]
	if machine.last_output_tick == tick:
		return 0
	if VoxelWorldData.is_belt(machine.block):
		if machine.belt_ores.is_empty() or machine.belt_ores[0].progress < 1.0 - 1e-9:
			return 0
		return mini(machine.eligible_quantity, 1)
	return machine.eligible_quantity


static func _full(machine: LogisticsMachine) -> bool:
	return VoxelWorldData.is_belt(machine.block) and machine.quantity == 2
