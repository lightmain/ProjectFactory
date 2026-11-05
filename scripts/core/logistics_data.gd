class_name LogisticsData
extends RefCounted
## Fixed-clock authoritative logistics. Rule work is O(N) per tick/sample;
## catch-up is O((1 + ceil(delta / LOGIC_STEP)) * N), with no event scans.

signal machine_changed(cell: Vector3i)
signal reset

const BELT_TRAVEL_TIME: float = 0.5
const BELT_CAPACITY: int = 2
const LOGIC_STEP: float = 1.0 / 60.0
const TIME_EPSILON: float = 0.000000001

var _world: VoxelWorldData
var _topology: LogisticsTopology = LogisticsTopology.new()
var _batch: LogisticsBatch = LogisticsBatch.new()
var _position_solver: BeltPositionSolver = BeltPositionSolver.new()
var _time: float = 0.0
var _time_compensation: float = 0.0
var _tick: int = 0
var _flushed_tick: int = -1
var _mining_interval: float = 1.0
var _mining_amount: int = 1
var _version: int = 0
var _sample_version: int = -1
var _sample_time: float = -1.0
var _sample_queues: Array[LogisticsOreQueue] = []
var _work_count: int = 0
var _batch_count: int = 0
var _sample_work: int = 0
var _sample_solves: int = 0


static func is_machine(block: int) -> bool:
	return block in [VoxelWorldData.Block.MINER, VoxelWorldData.Block.BELT, VoxelWorldData.Block.CHEST]


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
	_work_count = 0
	_batch_count = 0
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
		_rebuild_topology()
		_batch.transfer(_topology, _tick)
		_work_count += _batch.work
		_batch_count += 1
		_flushed_tick = _tick
		_version += 1
	var end_tick: int = int(floorf((end_time + TIME_EPSILON) / LOGIC_STEP))
	if _topology.machines.is_empty():
		_tick = end_tick
	else:
		while _tick < end_tick:
			_tick += 1
			# Move on the previously settled graph. Edits enter at this boundary.
			_advance_belts(LOGIC_STEP)
			if _topology.dirty:
				_rebuild_topology()
			var boundary: float = float(_tick) * LOGIC_STEP
			for machine: LogisticsMachine in _topology.machines:
				_work_count += 1
				machine.produce_until(boundary)
				# Arrivals below are excluded from any supplemental edit flush.
				machine.eligible_quantity = machine.quantity
			_batch.transfer(_topology, _tick)
			_work_count += _batch.work
			_batch_count += 1
			_version += 1
	_time = end_time


func set_direction(cell: Vector3i, direction: Vector3i) -> bool:
	var index: int = _topology.index_at(cell)
	if index < 0 or direction not in [
		Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK,
	]:
		return false
	var machine: LogisticsMachine = _topology.machines[index]
	if machine.direction == direction:
		return true
	machine.direction = direction
	_topology.dirty = true
	_version += 1
	machine_changed.emit(cell)
	return true


func direction_at(cell: Vector3i) -> Vector3i:
	var index: int = _topology.index_at(cell)
	return _topology.machines[index].direction if index >= 0 else Vector3i.ZERO


func ore_count(cell: Vector3i) -> int:
	var index: int = _topology.index_at(cell)
	return _topology.machines[index].quantity if index >= 0 else 0


func belt_ores(cell: Vector3i, extra_time: float = 0.0) -> Array[LogisticsOre]:
	_ensure_sample(extra_time)
	var ores: Array[LogisticsOre] = []
	var index: int = _topology.index_at(cell)
	if index >= 0:
		for ore: LogisticsOre in _sample_queues[index].ores:
			ores.append(ore.copy())
	return ores


func sample_belts(extra_time: float = 0.0) -> Array[LogisticsOreQueue]:
	## One ordered row per live facility; the snapshot uses no hashing.
	_ensure_sample(extra_time)
	var result: Array[LogisticsOreQueue] = []
	for cached: LogisticsOreQueue in _sample_queues:
		var queue: LogisticsOreQueue = LogisticsOreQueue.new()
		queue.cell = cached.cell
		queue.direction = cached.direction
		for ore: LogisticsOre in cached.ores:
			queue.ores.append(ore.copy())
		result.append(queue)
	return result


func total_ore() -> int:
	var count: int = 0
	for machine: LogisticsMachine in _topology.machines:
		count += machine.quantity
	return count


func machine_cells() -> Array[Vector3i]:
	return _topology.cells.duplicate()


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
	if _world == null or not SnapshotValues.number(state.get("time"), 0.0, 100000000.0) or (
		not SnapshotValues.number(state.get("compensation"), -0.00001, 0.00001)
		or not SnapshotValues.integer(state.get("tick"), 0, 6000000000)
		or not SnapshotValues.integer(state.get("flushed"), -1, 6000000000)
		or not SnapshotValues.integer(state.get("next_id"), 1, SnapshotValues.MAX_INTEGER)
		or not state.get("interval") is float
		or not SnapshotValues.integer(state.get("amount"), SnapshotValues.MIN_INTEGER, SnapshotValues.MAX_INTEGER)
		or not state.get("dirty") is bool or not state.get("machines") is Array
		or not state.get("inputs") is Array or not state.get("outgoing") is Array
	):
		return false
	var time: float = state["time"]
	var tick: int = state["tick"]
	var flushed: int = state["flushed"]
	if tick != int(floorf((time + TIME_EPSILON) / LOGIC_STEP)) or flushed > tick:
		return false
	var rows: Array = state["machines"]
	if rows.size() != _topology.machines.size():
		return false
	var topology: LogisticsTopology = LogisticsTopology.new()
	var ids: Dictionary[int, bool] = {}
	for value: Variant in rows:
		if not value is Dictionary:
			return false
		var row: Dictionary = value
		if not row.get("cell") is Vector3i:
			return false
		var cell: Vector3i = row["cell"]
		var machine: LogisticsMachine = LogisticsMachine.decode(row, time, tick)
		if machine == null or topology.index_at(cell) >= 0 or (
			not _world.is_in_bounds(cell) or _world.get_block(cell) != machine.block
		):
			return false
		for ore: LogisticsOre in machine.belt_ores:
			if ids.has(ore.id) or ore.id >= state["next_id"]:
				return false
			ids[ore.id] = true
		topology.add(cell, machine)
	var outgoing: Array = state["outgoing"]
	var inputs: Array = state["inputs"]
	if outgoing.size() != rows.size() or inputs.size() != rows.size() * 3:
		return false
	for value: Variant in outgoing + inputs:
		if not SnapshotValues.integer(value, -1, rows.size() - 1):
			return false
	topology.outgoing.assign(outgoing)
	topology.inputs.assign(inputs)
	for target: int in range(rows.size()):
		var machine: LogisticsMachine = topology.machines[target]
		var facing: Vector3i = machine.settled_direction
		var side: Vector3i = Vector3i(-facing.z, 0, facing.x)
		var ports: Array[Vector3i] = [facing, side, -side]
		for port: int in range(3):
			var source: int = topology.inputs[target * 3 + port]
			if source < 0:
				continue
			if machine.block == VoxelWorldData.Block.MINER or (
				machine.block == VoxelWorldData.Block.CHEST and port != 0
			) or topology.outgoing[source] != target or (
				topology.cells[source] != topology.cells[target] - ports[port]
				or topology.machines[source].settled_direction != ports[port]
			):
				return false
		var destination: int = topology.outgoing[target]
		if destination >= 0 and target not in topology.inputs.slice(destination * 3, destination * 3 + 3):
			return false
	topology.dirty = state["dirty"]
	if not topology.dirty:
		for machine: LogisticsMachine in topology.machines:
			if machine.direction != machine.settled_direction:
				return false
		# A settled graph must contain every legal edge, not merely valid listed edges.
		topology.rebuild()
		if topology.inputs != inputs or topology.outgoing != outgoing:
			return false
	var queues: Array[LogisticsOreQueue] = []
	for machine: LogisticsMachine in topology.machines:
		var queue: LogisticsOreQueue = LogisticsOreQueue.new()
		queue.ores = machine.belt_ores
		queues.append(queue)
	var solver: BeltPositionSolver = BeltPositionSolver.new()
	if not solver.is_feasible(topology, queues):
		return false
	_topology = topology
	_time = time
	_time_compensation = state["compensation"]
	_tick = tick
	_flushed_tick = state["flushed"]
	_batch.next_ore_id = state["next_id"]
	_mining_interval = state["interval"]
	_mining_amount = state["amount"]
	_sample_queues.clear()
	for machine: LogisticsMachine in _topology.machines:
		_sample_queues.append(LogisticsOreQueue.new())
	_version += 1
	_sample_version = -1
	reset.emit()
	return true


func work_stats() -> Dictionary[String, int]:
	return {
		"advance": _work_count, "batches": _batch_count,
		"sample": _sample_work, "sample_solves": _sample_solves,
		"cache_rows": _sample_queues.size(),
	}


func _ensure_sample(extra_time: float) -> void:
	var boundary: float = float(_tick) * LOGIC_STEP
	var requested: float = extra_time if is_finite(extra_time) and extra_time > 0.0 else 0.0
	var sample_time: float = clampf(_time + requested, boundary, float(_tick + 1) * LOGIC_STEP)
	if _sample_version == _version and _sample_time == sample_time:
		return
	var copy_work: int = 0
	for index: int in range(_topology.machines.size()):
		copy_work += 1
		var machine: LogisticsMachine = _topology.machines[index]
		var queue: LogisticsOreQueue = _sample_queues[index]
		# Each live row owns at most two copies. Deleted rows retire at the edit,
		# so this cleanup never depends on a previous, larger facility count.
		copy_work += queue.ores.size()
		queue.ores.clear()
		queue.cell = _topology.cells[index]
		queue.direction = machine.settled_direction
		for ore: LogisticsOre in machine.belt_ores:
			copy_work += 1
			queue.ores.append(ore.copy())
	_position_solver.advance(_topology, _sample_queues, sample_time - boundary)
	_sample_solves += 1
	_sample_work = copy_work + _position_solver.work
	_sample_version = _version
	_sample_time = sample_time


func _advance_belts(delta: float) -> void:
	var queues: Array[LogisticsOreQueue] = []
	for machine: LogisticsMachine in _topology.machines:
		_work_count += 1
		var queue: LogisticsOreQueue = LogisticsOreQueue.new()
		queue.ores = machine.belt_ores
		queues.append(queue)
	_position_solver.advance(_topology, queues, delta)
	_work_count += _position_solver.work


func _rebuild_topology() -> void:
	_topology.rebuild()
	_work_count += _topology.work


func _on_world_reset() -> void:
	_topology.clear()
	_sample_queues.clear()
	_time = 0.0
	_time_compensation = 0.0
	_tick = 0
	_flushed_tick = -1
	_batch.next_ore_id = 1
	_version += 1
	for cell: Vector3i in _world.solid_cells():
		var block: int = _world.get_block(cell)
		if is_machine(block):
			_topology.add(cell, LogisticsMachine.new(block, _time, _mining_interval, _mining_amount))
			_sample_queues.append(LogisticsOreQueue.new())
	reset.emit()


func _on_cell_changed(cell: Vector3i) -> void:
	var index: int = _topology.index_at(cell)
	if index >= 0:
		# Compact the cache in the same order as the topology, in constant work.
		_sample_queues[index] = _sample_queues[-1]
		_sample_queues.pop_back()
		_topology.remove(index)
	var block: int = _world.get_block(cell)
	if is_machine(block):
		_topology.add(cell, LogisticsMachine.new(block, _time, _mining_interval, _mining_amount))
		_sample_queues.append(LogisticsOreQueue.new())
	_version += 1
	machine_changed.emit(cell)
