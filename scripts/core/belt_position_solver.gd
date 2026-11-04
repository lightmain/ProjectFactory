class_name BeltPositionSolver
extends RefCounted
## Greatest feasible positions on a functional graph. No global relaxation.
## Every node enters/leaves the walk once; cycle deque indices enter/leave once.

var work: int = 0


func advance(
	topology: LogisticsTopology, queues: Array[LogisticsOreQueue], delta: float
) -> void:
	work = 0
	var ores: Array[LogisticsOre] = []
	var heads: Array[int] = []
	var tails: Array[int] = []
	var desired: Array[float] = []
	var leaders: Array[int] = []
	var weights: Array[float] = []
	for index: int in range(topology.machines.size()):
		work += 1
		heads.append(-1)
		tails.append(-1)
		var queue: LogisticsOreQueue = queues[index]
		var limit: float = 1.0
		for ore: LogisticsOre in queue.ores:
			work += 1
			var node: int = ores.size()
			ores.append(ore)
			desired.append(minf(ore.progress + delta / 0.5, limit))
			limit = desired[node] - 0.5
			leaders.append(node - 1 if heads[index] >= 0 else -1)
			weights.append(-0.5)
			if heads[index] < 0:
				heads[index] = node
			tails[index] = node
	for index: int in range(heads.size()):
		work += 1
		var target: int = topology.outgoing[index]
		if heads[index] < 0 or target < 0 or tails[target] < 0:
			continue
		if ores[tails[target]].incoming_direction == topology.machines[index].settled_direction:
			# An edited connection may join two occupied ends. Wait for its
			# initial gap to open rather than pulling the upstream ore back.
			# Transfer already requires the downstream tail to reach 0.5.
			if ores[heads[index]].progress > ores[tails[target]].progress + 0.5 + 1e-9:
				continue
			leaders[heads[index]] = tails[target]
			weights[heads[index]] = 0.5
	var positions: Array[float] = solve(desired, leaders, weights)
	for index: int in range(ores.size()):
		work += 1
		assert(positions[index] >= ores[index].progress - 1e-9, "Infeasible belt state")
		ores[index].progress = positions[index]


func solve(
	desired: Array[float], leaders: Array[int], weights: Array[float]
) -> Array[float]:
	var size: int = desired.size()
	var states: Array[int] = []
	var stack_indices: Array[int] = []
	states.resize(size)
	states.fill(0)
	stack_indices.resize(size)
	var positions: Array[float] = desired.duplicate()
	for start: int in range(size):
		work += 1
		if states[start] != 0:
			continue
		var stack: Array[int] = []
		var node: int = start
		while node >= 0 and states[node] == 0:
			work += 1
			states[node] = 1
			stack_indices[node] = stack.size()
			stack.append(node)
			node = leaders[node]
		if node >= 0 and states[node] == 1:
			var cycle_start: int = stack_indices[node]
			_solve_cycle(stack, cycle_start, desired, weights, positions)
			for index: int in range(cycle_start, stack.size()):
				work += 1
				states[stack[index]] = 2
		while not stack.is_empty():
			work += 1
			node = stack.pop_back()
			if states[node] == 2:
				continue
			var leader: int = leaders[node]
			if leader >= 0:
				positions[node] = minf(desired[node], positions[leader] + weights[node])
			states[node] = 2
	return positions


func _solve_cycle(
	stack: Array[int], first: int, desired: Array[float],
	weights: Array[float], positions: Array[float]
) -> void:
	var count: int = stack.size() - first
	var prefix: Array[float] = [0.0]
	var values: Array[float] = []
	for index: int in range(2 * count):
		work += 1
		var node: int = stack[first + index % count]
		values.append(desired[node] + prefix[index])
		prefix.append(prefix[index] + weights[node])
	assert(prefix[count] >= -1e-9, "Negative belt constraint cycle")
	# A read cursor replaces pop_front. A consumed deque prefix is never copied.
	var deque: Array[int] = []
	var read: int = 0
	for index: int in range(2 * count - 1):
		work += 1
		while deque.size() > read and values[deque[-1]] >= values[index]:
			work += 1
			deque.pop_back()
		deque.append(index)
		var window: int = index - count + 1
		if window < 0:
			continue
		while deque[read] < window:
			work += 1
			read += 1
		positions[stack[first + window]] = values[deque[read]] - prefix[window]
