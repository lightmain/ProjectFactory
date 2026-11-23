extends RefCounted
## Frozen T03 algorithms (2026-11-09). Test-only; never inherit the production simulator.
## Copied from logistics_data/machine/topology/batch/belt_position_solver at T03.
## Work counters, cache reuse and input validation are omitted; simulation equations
## and batch ordering are retained. Replay supplies already validated plain states.

const LOGIC_STEP: float = 1.0 / 60.0
const TIME_EPSILON: float = 0.000000001

class Ore:
	extends RefCounted
	var id: int
	var incoming_direction: Vector3i
	var progress: float = 0.0

	func _init(ore_id: int, incoming: Vector3i) -> void:
		id = ore_id
		incoming_direction = incoming

	func copy() -> Ore:
		var result: Ore = Ore.new(id, incoming_direction)
		result.progress = progress
		return result


class Queue:
	extends RefCounted
	var cell: Vector3i
	var direction: Vector3i
	var block: int
	var ores: Array[Ore] = []


class Machine:
	extends RefCounted
	var block: int
	var direction: Vector3i = Vector3i.FORWARD
	var quantity: int = 0
	var interval: float
	var amount: int
	var next_production: float = INF
	var input_cursor: int = 0
	var belt_ores: Array[Ore] = []
	var settled_direction: Vector3i = Vector3i.FORWARD
	var eligible_quantity: int = 0
	var last_output_tick: int = -1
	var _placed_at: float
	var _produced_cycles: int = 0

	func _init(kind: int, placed_at: float, mining_interval: float, mining_amount: int) -> void:
		block = kind
		if VoxelWorldData.is_slope(block):
			direction = VoxelWorldData.slope_direction(block)
			settled_direction = direction
		interval = mining_interval
		amount = mining_amount
		_placed_at = placed_at
		if block == VoxelWorldData.Block.MINER and is_finite(interval) and interval >= 0.001 and amount > 0:
			var deadline: float = placed_at + interval
			if deadline > placed_at:
				next_production = deadline

	func produce_until(time: float) -> void:
		if next_production > time + 1e-9:
			return
		var elapsed_cycles: float = floorf((time - _placed_at + 1e-9) / interval)
		if not is_finite(elapsed_cycles) or elapsed_cycles >= float(9223372036854775807):
			next_production = INF
			return
		var cycles: int = int(elapsed_cycles)
		if cycles <= _produced_cycles:
			return
		quantity += (cycles - _produced_cycles) * amount
		_produced_cycles = cycles
		var deadline: float = _placed_at + float(cycles + 1) * interval
		next_production = deadline if deadline > time and deadline > next_production else INF

	func save_state() -> Dictionary:
		var ores: Array[Dictionary] = []
		for ore: Ore in belt_ores:
			ores.append({"id": ore.id, "incoming": ore.incoming_direction, "progress": ore.progress})
		return {
			"block": block, "direction": direction, "settled": settled_direction,
			"quantity": quantity, "eligible": eligible_quantity, "last_output": last_output_tick,
			"interval": interval, "amount": amount, "next": next_production,
			"cursor": input_cursor, "placed": _placed_at, "cycles": _produced_cycles, "ores": ores,
		}

	static func from_state(row: Dictionary) -> Machine:
		var machine: Machine = Machine.new(row["block"], row["placed"], row["interval"], row["amount"])
		machine.direction = row["direction"]
		machine.settled_direction = row["settled"]
		machine.quantity = row["quantity"]
		machine.eligible_quantity = row["eligible"]
		machine.last_output_tick = row["last_output"]
		machine.input_cursor = row["cursor"]
		machine._produced_cycles = row["cycles"]
		machine.next_production = row["next"]
		var ores: Array = row["ores"]
		for value: Dictionary in ores:
			var ore: Ore = Ore.new(value["id"], value["incoming"])
			ore.progress = value["progress"]
			machine.belt_ores.append(ore)
		return machine


class Graph:
	extends RefCounted
	var cells: Array[Vector3i] = []
	var machines: Array[Machine] = []
	var outgoing: Array[int] = []
	var inputs: Array[int] = []
	var dirty: bool = true
	# Sparse lookup replaces only the old dense address table, not graph rules.
	var _slots: Dictionary[Vector3i, int] = {}

	func index_at(cell: Vector3i) -> int:
		return _slots.get(cell, -1)

	func add(cell: Vector3i, machine: Machine) -> void:
		_slots[cell] = machines.size()
		cells.append(cell)
		machines.append(machine)
		outgoing.append(-1)
		for port: int in range(3):
			inputs.append(-1)
		dirty = true

	func remove(index: int) -> void:
		var target: int = outgoing[index]
		if target >= 0:
			for port: int in range(3):
				if inputs[target * 3 + port] == index:
					inputs[target * 3 + port] = -1
		for port: int in range(3):
			var source: int = inputs[index * 3 + port]
			if source >= 0:
				outgoing[source] = -1
		_slots.erase(cells[index])
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
			_slots[cells[index]] = index
		cells.pop_back()
		machines.pop_back()
		outgoing.pop_back()
		inputs.resize(last * 3)
		dirty = true

	static func input_count(block: int) -> int:
		return 0 if block == VoxelWorldData.Block.MINER else (3 if block == VoxelWorldData.Block.BELT else 1)

	static func port_direction(facing: Vector3i, port: int) -> Vector3i:
		var side: Vector3i = Vector3i(-facing.z, 0, facing.x)
		return facing if port == 0 else (side if port == 1 else -side)

	func connects(source: int, target: int, port: int) -> bool:
		var machine: Machine = machines[target]
		if port >= input_count(machine.block):
			return false
		var direction: Vector3i = port_direction(machine.settled_direction, port)
		return machines[source].settled_direction == direction and (
			cells[source] + direction + Vector3i.UP * VoxelWorldData.outlet_step(machines[source].block)
			== cells[target] + Vector3i.UP * VoxelWorldData.inlet_step(machine.block)
		)

	func rebuild() -> void:
		outgoing.fill(-1)
		inputs.fill(-1)
		for machine: Machine in machines:
			var facing: Vector3i = machine.settled_direction
			while facing != machine.direction:
				facing = Vector3i(-facing.z, 0, facing.x)
				for ore: Ore in machine.belt_ores:
					ore.incoming_direction = Vector3i(-ore.incoming_direction.z, 0, ore.incoming_direction.x)
			machine.settled_direction = machine.direction
		for target: int in range(machines.size()):
			var machine: Machine = machines[target]
			if machine.block == VoxelWorldData.Block.MINER:
				continue
			for port: int in range(input_count(machine.block)):
				var direction: Vector3i = port_direction(machine.settled_direction, port)
				var base: Vector3i = cells[target] - direction + Vector3i.UP * VoxelWorldData.inlet_step(machine.block)
				for height: int in range(2):
					var source: int = index_at(base + Vector3i.DOWN * height)
					if source >= 0 and connects(source, target, port):
						inputs[target * 3 + port] = source
						outgoing[source] = target
						break
		dirty = false


class Batch:
	extends RefCounted
	var next_ore_id: int = 1

	func transfer(topology: Graph, tick: int) -> void:
		var size: int = topology.machines.size()
		var sources: Array[int] = []
		var ports: Array[int] = []
		var amounts: Array[int] = []
		var valid: Array[bool] = []
		var output_targets: Array[int] = []
		var moved_ores: Array[Ore] = []
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
			var machine: Machine = topology.machines[target]
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
				var port: int = (machine.input_cursor + offset) % 3
				var source: int = topology.inputs[target * 3 + port]
				if source < 0 or (cycle_inputs[target] >= 0 and source != cycle_inputs[target]):
					continue
				if _available(topology, source, tick) <= 0:
					if VoxelWorldData.is_belt(topology.machines[source].block) and topology.machines[source].quantity > 0:
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
			if valid[target] and _full(topology.machines[target]) and output_targets[target] < 0:
				valid[target] = false
				rejected.append(target)
		var read: int = 0
		while read < rejected.size():
			var source: int = sources[rejected[read]]
			read += 1
			if valid[source] and _full(topology.machines[source]):
				valid[source] = false
				rejected.append(source)
		for target: int in range(size):
			if not valid[target]:
				continue
			var source: Machine = topology.machines[sources[target]]
			source.quantity -= amounts[target]
			source.eligible_quantity -= amounts[target]
			source.last_output_tick = tick
			if VoxelWorldData.is_belt(source.block):
				moved_ores[target] = source.belt_ores.pop_front()
		for target: int in range(size):
			if not valid[target]:
				continue
			var machine: Machine = topology.machines[target]
			machine.quantity += amounts[target]
			if not VoxelWorldData.is_belt(machine.block):
				continue
			var incoming: Vector3i = topology.machines[sources[target]].settled_direction
			var ore: Ore = moved_ores[target]
			if ore == null:
				ore = Ore.new(next_ore_id, incoming)
				next_ore_id += 1
			ore.incoming_direction = incoming
			ore.progress = 0.0
			machine.belt_ores.append(ore)
			machine.input_cursor = (ports[target] + 1) % 3

	func _full_cycle_inputs(topology: Graph, tick: int) -> Array[int]:
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
			var machine: Machine = topology.machines[index]
			ready[index] = (
				_full(machine) and _available(topology, index, tick) > 0
				and machine.belt_ores[-1].progress >= 0.5 - 1e-9
			)
		for start: int in range(size):
			if not ready[start] or states[start] != 0:
				continue
			var stack: Array[int] = []
			var index: int = start
			while index >= 0 and ready[index] and states[index] == 0:
				states[index] = 1
				stack_indices[index] = stack.size()
				stack.append(index)
				index = topology.outgoing[index]
			if index >= 0 and states[index] == 1:
				for cursor: int in range(stack_indices[index], stack.size()):
					var source: int = stack[cursor]
					predecessors[topology.outgoing[source]] = source
			for walked: int in stack:
				states[walked] = 2
		return predecessors

	static func _available(topology: Graph, index: int, tick: int) -> int:
		if index < 0:
			return 0
		var machine: Machine = topology.machines[index]
		if machine.last_output_tick == tick:
			return 0
		if VoxelWorldData.is_belt(machine.block):
			if machine.belt_ores.is_empty() or machine.belt_ores[0].progress < 1.0 - 1e-9:
				return 0
			return mini(machine.eligible_quantity, 1)
		return machine.eligible_quantity

	static func _full(machine: Machine) -> bool:
		return VoxelWorldData.is_belt(machine.block) and machine.quantity == 2


class Solver:
	extends RefCounted

	func advance(topology: Graph, queues: Array[Queue], delta: float) -> void:
		var ores: Array[Ore] = []
		var heads: Array[int] = []
		var tails: Array[int] = []
		var desired: Array[float] = []
		var leaders: Array[int] = []
		var weights: Array[float] = []
		for index: int in range(topology.machines.size()):
			heads.append(-1)
			tails.append(-1)
			var queue: Queue = queues[index]
			var limit: float = 1.0
			for ore: Ore in queue.ores:
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
			var target: int = topology.outgoing[index]
			if heads[index] < 0 or target < 0 or tails[target] < 0:
				continue
			if ores[tails[target]].incoming_direction == topology.machines[index].settled_direction:
				if ores[heads[index]].progress > ores[tails[target]].progress + 0.5 + 1e-9:
					continue
				leaders[heads[index]] = tails[target]
				weights[heads[index]] = 0.5
		var positions: Array[float] = solve(desired, leaders, weights)
		for index: int in range(ores.size()):
			assert(positions[index] >= ores[index].progress - 1e-9, "Infeasible frozen belt state")
			ores[index].progress = positions[index]

	func solve(desired: Array[float], leaders: Array[int], weights: Array[float]) -> Array[float]:
		var size: int = desired.size()
		var states: Array[int] = []
		var stack_indices: Array[int] = []
		states.resize(size)
		states.fill(0)
		stack_indices.resize(size)
		var positions: Array[float] = desired.duplicate()
		for start: int in range(size):
			if states[start] != 0:
				continue
			var stack: Array[int] = []
			var node: int = start
			while node >= 0 and states[node] == 0:
				states[node] = 1
				stack_indices[node] = stack.size()
				stack.append(node)
				node = leaders[node]
			if node >= 0 and states[node] == 1:
				var cycle_start: int = stack_indices[node]
				_solve_cycle(stack, cycle_start, desired, weights, positions)
				for index: int in range(cycle_start, stack.size()):
					states[stack[index]] = 2
			while not stack.is_empty():
				node = stack.pop_back()
				if states[node] == 2:
					continue
				var leader: int = leaders[node]
				if leader >= 0:
					positions[node] = minf(desired[node], positions[leader] + weights[node])
				states[node] = 2
		return positions

	func _solve_cycle(
		stack: Array[int], first: int, desired: Array[float], weights: Array[float], positions: Array[float]
	) -> void:
		var count: int = stack.size() - first
		var prefix: Array[float] = [0.0]
		var values: Array[float] = []
		for index: int in range(2 * count):
			var node: int = stack[first + index % count]
			values.append(desired[node] + prefix[index])
			prefix.append(prefix[index] + weights[node])
		assert(prefix[count] >= -1e-9, "Negative frozen belt constraint cycle")
		var deque: Array[int] = []
		var read: int = 0
		for index: int in range(2 * count - 1):
			while deque.size() > read and values[deque[-1]] >= values[index]:
				deque.pop_back()
			deque.append(index)
			var window: int = index - count + 1
			if window < 0:
				continue
			while deque[read] < window:
				read += 1
			positions[stack[first + window]] = values[deque[read]] - prefix[window]


var _world: VoxelWorldData
var _topology: Graph = Graph.new()
var _batch: Batch = Batch.new()
var _position_solver: Solver = Solver.new()
var _time: float = 0.0
var _time_compensation: float = 0.0
var _tick: int = 0
var _flushed_tick: int = -1
var _mining_interval: float = 1.0
var _mining_amount: int = 1


static func is_machine(block: int) -> bool:
	return block in [VoxelWorldData.Block.MINER, VoxelWorldData.Block.CHEST] or VoxelWorldData.is_belt(block)


func bind_world(world: VoxelWorldData, interval: float = 1.0, amount: int = 1) -> void:
	if _world != null:
		_world.cell_changed.disconnect(_on_cell_changed)
		_world.world_reset.disconnect(_on_world_reset)
	_world = world
	configure_miners(interval, amount)
	_world.cell_changed.connect(_on_cell_changed)
	_world.world_reset.connect(_on_world_reset)
	_on_world_reset()


func configure_miners(interval: float, amount: int) -> void:
	_mining_interval = interval
	_mining_amount = amount


func advance(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	var corrected: float = delta - _time_compensation
	var end_time: float = _time + corrected
	if not is_finite(end_time) or end_time / LOGIC_STEP >= float(9223372036854775807):
		return
	_time_compensation = (end_time - _time) - corrected
	if (
		_topology.dirty and _flushed_tick != _tick
		and absf(_time - float(_tick) * LOGIC_STEP) <= TIME_EPSILON
	):
		_topology.rebuild()
		_batch.transfer(_topology, _tick)
		_flushed_tick = _tick
	var end_tick: int = int(floorf((end_time + TIME_EPSILON) / LOGIC_STEP))
	if _topology.machines.is_empty():
		_tick = end_tick
	else:
		while _tick < end_tick:
			_tick += 1
			var queues: Array[Queue] = []
			for machine: Machine in _topology.machines:
				var queue: Queue = Queue.new()
				queue.ores = machine.belt_ores
				queues.append(queue)
			_position_solver.advance(_topology, queues, LOGIC_STEP)
			if _topology.dirty:
				_topology.rebuild()
			var boundary: float = float(_tick) * LOGIC_STEP
			for machine: Machine in _topology.machines:
				machine.produce_until(boundary)
				machine.eligible_quantity = machine.quantity
			_batch.transfer(_topology, _tick)
	_time = end_time


func set_direction(cell: Vector3i, direction: Vector3i) -> bool:
	var index: int = _topology.index_at(cell)
	if index < 0 or direction not in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]:
		return false
	var machine: Machine = _topology.machines[index]
	if machine.direction == direction:
		return true
	if VoxelWorldData.is_slope(machine.block):
		return false
	machine.direction = direction
	_topology.dirty = true
	return true


func save_state() -> Dictionary:
	var machines: Array[Dictionary] = []
	for index: int in range(_topology.machines.size()):
		var row: Dictionary = _topology.machines[index].save_state()
		row["cell"] = _topology.cells[index]
		machines.append(row)
	return {
		"time": _time, "compensation": _time_compensation, "tick": _tick,
		"flushed": _flushed_tick, "next_id": _batch.next_ore_id,
		"interval": _mining_interval, "amount": _mining_amount,
		"dirty": _topology.dirty, "machines": machines,
		"outgoing": _topology.outgoing.duplicate(), "inputs": _topology.inputs.duplicate(),
	}


func restore_state(state: Dictionary) -> bool:
	# Only validated plain snapshots reach this test helper. Validation remains
	# covered by production save tests; it is not a second trust boundary.
	_topology = Graph.new()
	var rows: Array = state["machines"]
	for row: Dictionary in rows:
		_topology.add(row["cell"], Machine.from_state(row))
	_topology.outgoing.assign(state["outgoing"])
	_topology.inputs.assign(state["inputs"])
	_topology.dirty = state["dirty"]
	_time = state["time"]
	_time_compensation = state["compensation"]
	_tick = state["tick"]
	_flushed_tick = state["flushed"]
	_batch.next_ore_id = state["next_id"]
	_mining_interval = state["interval"]
	_mining_amount = state["amount"]
	return true


func sample_state(extra_time: float = 0.0) -> Array[Dictionary]:
	var boundary: float = float(_tick) * LOGIC_STEP
	var requested: float = extra_time if is_finite(extra_time) and extra_time > 0.0 else 0.0
	var sample_time: float = clampf(_time + requested, boundary, float(_tick + 1) * LOGIC_STEP)
	var queues: Array[Queue] = []
	for index: int in range(_topology.machines.size()):
		var machine: Machine = _topology.machines[index]
		var queue: Queue = Queue.new()
		queue.cell = _topology.cells[index]
		queue.direction = machine.settled_direction
		queue.block = machine.block
		for ore: Ore in machine.belt_ores:
			queue.ores.append(ore.copy())
		queues.append(queue)
	_position_solver.advance(_topology, queues, sample_time - boundary)
	var rows: Array[Dictionary] = []
	for queue: Queue in queues:
		var ores: Array[Dictionary] = []
		for ore: Ore in queue.ores:
			ores.append({"id": ore.id, "incoming": ore.incoming_direction, "progress": ore.progress})
		rows.append({"cell": queue.cell, "direction": queue.direction, "block": queue.block, "ores": ores})
	return rows


func _on_world_reset() -> void:
	_topology = Graph.new()
	_time = 0.0
	_time_compensation = 0.0
	_tick = 0
	_flushed_tick = -1
	_batch.next_ore_id = 1
	for cell: Vector3i in _world.solid_cells():
		var block: int = _world.get_block(cell)
		if is_machine(block):
			_topology.add(cell, Machine.new(block, _time, _mining_interval, _mining_amount))


func _on_cell_changed(cell: Vector3i) -> void:
	var index: int = _topology.index_at(cell)
	if index >= 0:
		_topology.remove(index)
	var block: int = _world.get_block(cell)
	if is_machine(block):
		_topology.add(cell, Machine.new(block, _time, _mining_interval, _mining_amount))
