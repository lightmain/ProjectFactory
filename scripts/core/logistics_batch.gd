class_name LogisticsBatch
extends RefCounted
## One target candidate and one output per facility. Rejections follow only
## the single dependent incoming candidate; no array deletion or rescanning.

var work: int = 0
var next_ore_id: int = 1


func transfer(topology: LogisticsTopology, tick: int) -> void:
	work = 0
	var size: int = topology.machines.size()
	var sources: Array[int] = []
	var ports: Array[int] = []
	var amounts: Array[int] = []
	var valid: Array[bool] = []
	var output_targets: Array[int] = []
	var moved_ores: Array[LogisticsOre] = []
	sources.resize(size)
	sources.fill(-1)
	ports.resize(size)
	amounts.resize(size)
	valid.resize(size)
	valid.fill(false)
	output_targets.resize(size)
	output_targets.fill(-1)
	moved_ores.resize(size)
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
					topology.machines[source].block == VoxelWorldData.Block.BELT
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
	var rejected: Array[int] = []
	for target: int in range(size):
		work += 1
		if valid[target] and _full(topology.machines[target]) and output_targets[target] < 0:
			valid[target] = false
			rejected.append(target)
	var read: int = 0
	while read < rejected.size():
		work += 1
		var source: int = sources[rejected[read]]
		read += 1
		# Candidate slots are indexed by target, so its dependent is slot[source].
		if valid[source] and _full(topology.machines[source]):
			valid[source] = false
			rejected.append(source)
	for target: int in range(size):
		work += 1
		if not valid[target]:
			continue
		var source: LogisticsMachine = topology.machines[sources[target]]
		source.quantity -= amounts[target]
		source.eligible_quantity -= amounts[target]
		source.last_output_tick = tick
		if source.block == VoxelWorldData.Block.BELT:
			# A belt has at most two ores; this bounded shift is constant work.
			moved_ores[target] = source.belt_ores.pop_front()
	for target: int in range(size):
		work += 1
		if not valid[target]:
			continue
		var machine: LogisticsMachine = topology.machines[target]
		machine.quantity += amounts[target]
		if machine.block != VoxelWorldData.Block.BELT:
			continue
		var incoming: Vector3i = topology.machines[sources[target]].settled_direction
		var ore: LogisticsOre = moved_ores[target]
		if ore == null:
			ore = LogisticsOre.new(next_ore_id, incoming)
			next_ore_id += 1
		ore.incoming_direction = incoming
		ore.progress = 0.0
		machine.belt_ores.append(ore)
		machine.input_cursor = (ports[target] + 1) % 3


func _full_cycle_inputs(topology: LogisticsTopology, tick: int) -> Array[int]:
	var size: int = topology.machines.size()
	var ready: Array[bool] = []
	var states: Array[int] = []
	var stack_indices: Array[int] = []
	var predecessors: Array[int] = []
	ready.resize(size)
	states.resize(size)
	states.fill(0)
	stack_indices.resize(size)
	predecessors.resize(size)
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
		var stack: Array[int] = []
		var index: int = start
		while index >= 0 and ready[index] and states[index] == 0:
			work += 1
			states[index] = 1
			stack_indices[index] = stack.size()
			stack.append(index)
			index = topology.outgoing[index]
		if index >= 0 and states[index] == 1:
			for cursor: int in range(stack_indices[index], stack.size()):
				work += 1
				var source: int = stack[cursor]
				predecessors[topology.outgoing[source]] = source
		for walked: int in stack:
			work += 1
			states[walked] = 2
	return predecessors


static func _available(topology: LogisticsTopology, index: int, tick: int) -> int:
	if index < 0:
		return 0
	var machine: LogisticsMachine = topology.machines[index]
	if machine.last_output_tick == tick:
		return 0
	if machine.block == VoxelWorldData.Block.BELT:
		if machine.belt_ores.is_empty() or machine.belt_ores[0].progress < 1.0 - 1e-9:
			return 0
		return mini(machine.eligible_quantity, 1)
	return machine.eligible_quantity


static func _full(machine: LogisticsMachine) -> bool:
	return machine.block == VoxelWorldData.Block.BELT and machine.quantity == 2
