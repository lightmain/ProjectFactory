class_name BeltPositionSolver
extends RefCounted
## Greatest feasible positions on a functional graph. No global relaxation.
## Every node enters/leaves the walk once; cycle deque indices enter/leave once.

var work: int = 0
var moved_ores: int = 0
var workspace_growths: int = 0
var _machine_capacity: int = 0
var _node_capacity: int = 0
var _ores: Array[LogisticsOre] = []
var _heads: Array[int] = []
var _tails: Array[int] = []
var _desired: Array[float] = []
var _leaders: Array[int] = []
var _weights: Array[float] = []
var _positions: Array[float] = []
var _states: Array[int] = []
var _stack_indices: Array[int] = []
var _stack: Array[int] = []
var _prefix: Array[float] = []
var _values: Array[float] = []
var _deque: Array[int] = []


func node_capacity() -> int:
	return _node_capacity


func clear() -> void:
	_resize_machines(0)
	_resize_nodes(0)


func _resize_machines(size: int) -> void:
	if size == _machine_capacity:
		return
	if size > _machine_capacity:
		workspace_growths += 1
	_machine_capacity = size
	_heads.resize(size)
	_tails.resize(size)


func _resize_nodes(size: int) -> void:
	if size == _node_capacity:
		return
	if size > _node_capacity:
		workspace_growths += 1
	_node_capacity = size
	_ores.resize(size)
	_desired.resize(size)
	_leaders.resize(size)
	_weights.resize(size)
	_positions.resize(size)
	_states.resize(size)
	_stack_indices.resize(size)
	_stack.resize(size)
	_prefix.resize(2 * size + 1 if size > 0 else 0)
	_values.resize(2 * size)
	_deque.resize(2 * size)


func advance(
	topology: LogisticsTopology, queues: Array[LogisticsOreQueue], delta: float
) -> void:
	_advance(topology, queues, delta, true)


func is_feasible(topology: LogisticsTopology, queues: Array[LogisticsOreQueue]) -> bool:
	## Check the entire settled graph without moving ores or triggering runtime assertions.
	return _advance(topology, queues, 0.0, false)


func _advance(
	topology: LogisticsTopology, queues: Array[LogisticsOreQueue], delta: float, commit: bool
) -> bool:
	work = 0
	moved_ores = 0
	_resize_machines(topology.machines.size())
	_resize_nodes(2 * topology.machines.size())
	var count: int = 0
	for index: int in range(topology.machines.size()):
		work += 1
		_heads[index] = -1
		_tails[index] = -1
		var queue: LogisticsOreQueue = queues[index]
		var limit: float = 1.0
		for ore: LogisticsOre in queue.ores:
			work += 1
			var node: int = count
			count += 1
			_ores[node] = ore
			_desired[node] = minf(ore.progress + delta / 0.5, limit)
			limit = _desired[node] - 0.5
			_leaders[node] = node - 1 if _heads[index] >= 0 else -1
			_weights[node] = -0.5
			if _heads[index] < 0:
				_heads[index] = node
			_tails[index] = node
	for index: int in range(_heads.size()):
		work += 1
		var target: int = topology.outgoing[index]
		if _heads[index] < 0 or target < 0 or _tails[target] < 0:
			continue
		if _ores[_tails[target]].incoming_direction == topology.machines[index].settled_direction:
			# An edited connection may join two occupied ends. Wait for its
			# initial gap to open rather than pulling the upstream ore back.
			# Transfer already requires the downstream tail to reach 0.5.
			if _ores[_heads[index]].progress > _ores[_tails[target]].progress + 0.5 + 1e-9:
				continue
			_leaders[_heads[index]] = _tails[target]
			_weights[_heads[index]] = 0.5
	_solve(_desired, _leaders, _weights, count)
	var feasible: bool = true
	for index: int in range(count):
		work += 1
		if not commit:
			if _positions[index] < _ores[index].progress - LogisticsData.TIME_EPSILON:
				feasible = false
		else:
			assert(_positions[index] >= _ores[index].progress - LogisticsData.TIME_EPSILON, "Infeasible belt state")
			if _positions[index] != _ores[index].progress:
				moved_ores += 1
			_ores[index].progress = _positions[index]
		# Scratch borrows ores only during this call, including failed validation.
		_ores[index] = null
	return feasible


func solve(
	desired: Array[float], leaders: Array[int], weights: Array[float]
) -> Array[float]:
	var size: int = desired.size()
	_resize_nodes(size)
	_solve(desired, leaders, weights, size)
	# Never expose the reusable result buffer.
	return _positions.slice(0, size)


func _solve(
	desired: Array[float], leaders: Array[int], weights: Array[float], size: int
) -> void:
	_states.fill(0)
	for index: int in range(size):
		_positions[index] = desired[index]
	for start: int in range(size):
		work += 1
		if _states[start] != 0:
			continue
		var stack_size: int = 0
		var node: int = start
		while node >= 0 and _states[node] == 0:
			work += 1
			_states[node] = 1
			_stack_indices[node] = stack_size
			_stack[stack_size] = node
			stack_size += 1
			node = leaders[node]
		if node >= 0 and _states[node] == 1:
			var cycle_start: int = _stack_indices[node]
			_solve_cycle(stack_size, cycle_start, desired, weights)
			for index: int in range(cycle_start, stack_size):
				work += 1
				_states[_stack[index]] = 2
		while stack_size > 0:
			work += 1
			stack_size -= 1
			node = _stack[stack_size]
			if _states[node] == 2:
				continue
			var leader: int = leaders[node]
			if leader >= 0:
				_positions[node] = minf(desired[node], _positions[leader] + weights[node])
			_states[node] = 2


func _solve_cycle(
	stack_size: int, first: int, desired: Array[float], weights: Array[float]
) -> void:
	var count: int = stack_size - first
	_prefix[0] = 0.0
	for index: int in range(2 * count):
		work += 1
		var node: int = _stack[first + index % count]
		_values[index] = desired[node] + _prefix[index]
		_prefix[index + 1] = _prefix[index] + weights[node]
	assert(_prefix[count] >= -1e-9, "Negative belt constraint cycle")
	# A read cursor replaces pop_front. A consumed deque prefix is never copied.
	var deque_size: int = 0
	var read: int = 0
	for index: int in range(2 * count - 1):
		work += 1
		while deque_size > read and _values[_deque[deque_size - 1]] >= _values[index]:
			work += 1
			deque_size -= 1
		_deque[deque_size] = index
		deque_size += 1
		var window: int = index - count + 1
		if window < 0:
			continue
		while _deque[read] < window:
			work += 1
			read += 1
		_positions[_stack[first + window]] = _values[_deque[read]] - _prefix[window]
