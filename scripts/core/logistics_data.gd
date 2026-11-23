class_name LogisticsData
extends RefCounted
## Fixed-clock authoritative logistics. The default solver is linear;
## opted-in connected regions defer uniform movement until their boundaries.

signal machine_changed(cell: Vector3i)
signal reset

const BELT_TRAVEL_TIME: float = 0.5
const BELT_CAPACITY: int = 2
const LOGIC_STEP: float = 1.0 / 60.0
const TIME_EPSILON: float = 0.000000001
const RustTransport = preload("res://scripts/core/rust_belt_transport.gd")

var _world: VoxelWorldData
var _topology: LogisticsTopology = LogisticsTopology.new()
var _batch: LogisticsBatch = LogisticsBatch.new()
var _position_solver: BeltPositionSolver = BeltPositionSolver.new()
var _straight_transport: BeltStraightTransport = BeltStraightTransport.new()
var _transport_regions: LogisticsTransportRegions = LogisticsTransportRegions.new()
var _pure_segments_requested: bool = false
var _rust_requested: bool = false
var _rust_transport: RustTransport
var _transport_error: String = ""
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
var _advance_queues: Array[LogisticsOreQueue] = []
var _queue_creations: int = 0
var _cache_ore_creations: int = 0
var _cache_ore_slots: int = 0
var _work_count: int = 0
var _edit_work: int = 0
var _batch_count: int = 0
var _transfer_calls: int = 0
var _sample_work: int = 0
var _full_sample_work: int = 0
var _sample_solves: int = 0
var _sample_return_rows: int = 0
var _sample_return_ores: int = 0
var _sample_direct_rows: int = 0
var _sample_dependency_rows: int = 0
var _sample_prediction_hits: int = 0


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
	_work_count = 0
	_batch_count = 0
	_transfer_calls = 0
	if not is_finite(delta) or delta <= 0.0:
		return
	if _rust_requested:
		_advance_rust(delta)
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
		if _transport_regions.active:
			var changed: Array[LogisticsTransportRegion] = _transport_regions.rebuild(_topology, true)
			_work_count += _transport_regions.rebuild_work
			_transport_regions.supplemental(_tick, changed)
			_transport_regions.assign_identities(_topology, _batch)
			_work_count += _transport_regions.work
			_transfer_calls += _transport_regions.transfer_calls
		else:
			_batch.transfer(_topology, _tick)
			_transfer_calls += 1
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
			if _transport_regions.active:
				var moved: Array[LogisticsTransportRegion] = []
				if _topology.dirty:
					_transport_regions.move_before_rebuild()
					_work_count += _transport_regions.work
					_rebuild_topology()
					moved = _transport_regions.rebuild(_topology, true)
					_work_count += _transport_regions.rebuild_work
				_transport_regions.advance_tick(_tick, moved)
				_transport_regions.assign_identities(_topology, _batch)
				_work_count += _transport_regions.work
				_transfer_calls += _transport_regions.transfer_calls
				_batch_count += 1
				_version += 1
				continue
			if _straight_transport.active:
				_straight_transport.advance_tick(_topology, _advance_queues, _position_solver, _batch, _tick)
				_work_count += _straight_transport.work
				_transfer_calls += _straight_transport.transfer_calls
				_batch_count += 1
				_version += 1
				continue
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
			_transfer_calls += 1
			_work_count += _batch.work
			_batch_count += 1
			_version += 1
	_time = end_time


func set_direction(cell: Vector3i, direction: Vector3i) -> bool:
	_edit_work = 0
	if _rust_requested and not _transport_error.is_empty():
		return false
	var index: int = _topology.index_at(cell)
	if index < 0 or direction not in [
		Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK,
	]:
		return false
	var machine: LogisticsMachine = _topology.machines[index]
	if machine.direction == direction:
		return true
	if VoxelWorldData.is_slope(machine.block):
		return false
	_before_rust_edit()
	if _transport_regions.active:
		_edit_work += _transport_regions.before_edit(cell, true)
	else:
		_stop_straight_transport()
	machine.direction = direction
	_topology.mark_changed(cell)
	_version += 1
	machine_changed.emit(cell)
	return true


func direction_at(cell: Vector3i) -> Vector3i:
	var index: int = _topology.index_at(cell)
	return _topology.machines[index].direction if index >= 0 else Vector3i.ZERO


func ore_count(cell: Vector3i) -> int:
	var index: int = _topology.index_at(cell)
	if index >= 0 and _rust_requested and _ensure_rust():
		return _rust_transport.quantity(index, _topology)
	if index >= 0 and _transport_regions.active:
		return _transport_regions.quantity(cell, _topology.machines[index])
	return _topology.machines[index].quantity if index >= 0 else 0


func belt_ores(cell: Vector3i, extra_time: float = 0.0) -> Array[LogisticsOre]:
	if _rust_requested:
		var rows: Array[LogisticsOreQueue] = sample_cells([cell], extra_time)
		return rows[0].ores if not rows.is_empty() else []
	_ensure_sample(extra_time)
	var ores: Array[LogisticsOre] = []
	var index: int = _topology.index_at(cell)
	if index >= 0:
		for ore: LogisticsOre in _sample_queues[index].ores:
			ores.append(ore.copy())
	return ores


func sample_belts(extra_time: float = 0.0) -> Array[LogisticsOreQueue]:
	## One ordered row per live facility; the snapshot uses no hashing.
	_sample_return_rows = 0
	_sample_return_ores = 0
	if _rust_requested:
		return sample_cells(machine_cells(), extra_time)
	_ensure_sample(extra_time)
	var result: Array[LogisticsOreQueue] = []
	for cached: LogisticsOreQueue in _sample_queues:
		result.append(_copy_sample_row(cached))
	return result


func sample_cells(cells: Array[Vector3i], extra_time: float = 0.0) -> Array[LogisticsOreQueue]:
	## Candidate order is caller-owned; the solver still includes downstream constraints.
	_sample_return_rows = 0
	_sample_return_ores = 0
	_sample_work = 0
	_sample_direct_rows = 0
	_sample_dependency_rows = 0
	_sample_prediction_hits = 0
	var indices: Array[int] = []
	var seen: Dictionary[Vector3i, bool] = {}
	for cell: Vector3i in cells:
		if seen.has(cell):
			continue
		seen[cell] = true
		var index: int = _topology.index_at(cell)
		if index >= 0:
			indices.append(index)
	var result: Array[LogisticsOreQueue] = []
	if indices.is_empty():
		return result
	if _rust_requested:
		if not _ensure_rust():
			return result
		result = _rust_transport.sample(indices, _topology)
		_sample_direct_rows = indices.size()
		_sample_return_rows = result.size()
		for row: LogisticsOreQueue in result:
			_sample_return_ores += row.ores.size()
		_sample_work = _sample_return_rows + _sample_return_ores
		return result
	if _transport_regions.active:
		_transport_regions.begin_prediction()
		var delta: float = _prediction_time(extra_time) - float(_tick) * LOGIC_STEP
		for index: int in indices:
			var cached: LogisticsOreQueue = _transport_regions.sample_row(
				_topology.cells[index], _topology.machines[index], _version, delta)
			result.append(_copy_sample_row(cached))
		_sample_work = _transport_regions.prediction_work
		_sample_direct_rows = _transport_regions.prediction_direct_rows
		_sample_dependency_rows = _transport_regions.prediction_dependency_rows
		_sample_prediction_hits = _transport_regions.prediction_hits
		_sample_solves += _transport_regions.prediction_solves
		return result
	_ensure_sample(extra_time)
	for index: int in indices:
		result.append(_copy_sample_row(_sample_queues[index]))
	return result


func begin_display_frame() -> void:
	_sample_return_rows = 0
	_sample_return_ores = 0
	_sample_work = 0
	_sample_direct_rows = 0
	_sample_dependency_rows = 0
	_sample_prediction_hits = 0
	if _rust_transport != null:
		_rust_transport.reset_display_stats()


func sample_display_cells(cells: Array[Vector3i], offset: Vector3) -> Dictionary:
	## Rust display data stays packed; ordinary rule and save reads keep sample_cells.
	_sample_return_rows = 0
	_sample_return_ores = 0
	_sample_work = 0
	_sample_direct_rows = 0
	_sample_dependency_rows = 0
	_sample_prediction_hits = 0
	if not _rust_requested or not offset.is_finite() or not _ensure_rust():
		return {"ok": false, "error": "Rust display backend unavailable or invalid offset."}
	var indices: PackedInt64Array = PackedInt64Array()
	var requested: Array[Vector3i] = []
	var seen: Dictionary[Vector3i, bool] = {}
	for cell: Vector3i in cells:
		if seen.has(cell):
			continue
		seen[cell] = true
		var index: int = _topology.index_at(cell)
		if index >= 0 and VoxelWorldData.is_belt(_topology.machines[index].block):
			indices.append(index)
			requested.append(cell)
	var page: Dictionary = _rust_transport.sample_display(indices, _topology, offset)
	if page.get("ok", false):
		page["cells"] = requested
		var ids: PackedInt64Array = page["ids"]
		_sample_return_rows = indices.size()
		_sample_direct_rows = indices.size()
		_sample_return_ores = ids.size()
		_sample_work = _sample_return_rows + _sample_return_ores
	return page


func _copy_sample_row(cached: LogisticsOreQueue) -> LogisticsOreQueue:
	_sample_return_rows += 1
	var queue: LogisticsOreQueue = LogisticsOreQueue.new()
	queue.cell = cached.cell
	queue.direction = cached.direction
	queue.block = cached.block
	for ore: LogisticsOre in cached.ores:
		queue.ores.append(ore.copy())
		_sample_return_ores += 1
	return queue


func total_ore() -> int:
	if _rust_requested and _ensure_rust():
		return _rust_transport.total(_topology)
	var count: int = 0
	for index: int in range(_topology.machines.size()):
		count += ore_count(_topology.cells[index])
	return count


func machine_cells() -> Array[Vector3i]:
	return _topology.cells.duplicate()


func candidate_cells(minimum: Vector3i, maximum: Vector3i) -> Array[Vector3i]:
	## Spatial reads never prepare predictions or apply pending rotations.
	return _topology.candidate_cells(minimum, maximum)


func save_state() -> Dictionary:
	if _rust_requested:
		return save_packed_state()
	var machines: Array[Dictionary] = []
	for index: int in range(_topology.machines.size()):
		var row: Dictionary = (
			_transport_regions.save_row(_topology.cells[index], _topology.machines[index])
			if _transport_regions.active else
			_topology.machines[index].save_state(_progress_offset(), _eligibility_is_quantity())
		)
		row["cell"] = _topology.cells[index]
		machines.append(row)
	return {
		"time": _time, "compensation": _time_compensation, "tick": _tick,
		"flushed": _flushed_tick, "next_id": _batch.next_ore_id,
		"interval": _mining_interval, "amount": _mining_amount,
		"dirty": _topology.dirty, "machines": machines,
		"outgoing": _topology.outgoing.duplicate(), "inputs": _topology.inputs.duplicate(),
	}


func save_packed_state() -> Dictionary:
	if _rust_requested and not _ensure_rust():
		return {}
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(_topology.machines.size() * LogisticsPacked.ROW_SIZE)
	bytes.fill(0)
	for index: int in range(_topology.machines.size()):
		if _transport_regions.active:
			_transport_regions.write_row(bytes, index, _topology.cells[index], _topology.machines[index])
			continue
		LogisticsPacked.write_row(
			bytes, index, _topology.cells[index], _topology.machines[index],
			_progress_offset(), _eligibility_is_quantity()
		)
	var result: Dictionary = {
		"packed": 1, "time": _time, "compensation": _time_compensation, "tick": _tick,
		"flushed": _flushed_tick, "next_id": _batch.next_ore_id,
		"interval": _mining_interval, "amount": _mining_amount, "dirty": _topology.dirty,
		"machines": bytes, "outgoing": PackedInt32Array(_topology.outgoing),
		"inputs": PackedInt32Array(_topology.inputs),
	}
	if _rust_requested:
		result["backend"] = "rust"
		result["native"] = _rust_transport.snapshot()
		result["incoming"] = _rust_transport.save_incoming()
		result["binding"] = _rust_transport.save_binding()
	return result


func mining_settings() -> Dictionary:
	return {"interval": _mining_interval, "amount": _mining_amount}


func enable_straight_transport() -> bool:
	if _rust_requested:
		return false
	## Development opt-in; ordinary game sessions keep the verified solver.
	if _pure_segments_requested:
		_stop_straight_transport()
		_pure_segments_requested = false
		_transport_regions.pure_segments = false
	if _transport_regions.active:
		return false
	return _straight_transport.prepare(_topology)


func enable_transport_lines() -> bool:
	if _rust_requested:
		return false
	## Development opt-in; inventory and legacy boundaries are accounted separately.
	if _pure_segments_requested:
		_stop_straight_transport()
		_pure_segments_requested = false
		_transport_regions.pure_segments = false
	if _straight_transport.active:
		return false
	return _transport_regions.prepare(_topology)


func enable_pure_segments() -> bool:
	if _rust_requested:
		return false
	if _pure_segments_requested and _transport_regions.active:
		return true
	_stop_straight_transport()
	_pure_segments_requested = true
	_transport_regions.pure_segments = true
	if _topology.machines.is_empty():
		_transport_regions.active = true
		return true
	return _transport_regions.prepare(_topology)


func logic_tick() -> int:
	return _tick


func enable_rust_transport() -> bool:
	if _rust_requested:
		return _ensure_rust()
	_stop_straight_transport()
	_rust_requested = true
	if not _ensure_rust():
		return false
	return true


func transport_backend() -> String:
	return "rust" if _rust_requested else "gdscript"


func transport_error() -> String:
	return _transport_error


func prefill_belts() -> bool:
	## Authoring helper for a fresh factory; disk writes still validate a full snapshot.
	if _tick != 0 or _time != 0.0 or total_ore() != 0:
		return false
	_before_rust_edit()
	_stop_straight_transport()
	_topology.rebuild()
	for index: int in range(_topology.machines.size()):
		var machine: LogisticsMachine = _topology.machines[index]
		if not VoxelWorldData.is_belt(machine.block):
			continue
		var incoming: Vector3i = machine.settled_direction
		for port: int in range(3):
			var source: int = _topology.inputs[index * 3 + port]
			if source >= 0:
				incoming = _topology.machines[source].settled_direction
				break
		for progress: float in [1.0, 0.5]:
			var ore: LogisticsOre = LogisticsOre.new(_batch.next_ore_id, incoming)
			_batch.next_ore_id += 1
			ore.progress = progress
			machine.belt_ores.append(ore)
		machine.quantity = 2
		machine.eligible_quantity = 2
	_version += 1
	if _pure_segments_requested:
		enable_pure_segments()
	return true


func restore_state(state: Dictionary) -> bool:
	var backend: Variant = state.get("backend", "gdscript")
	if backend not in ["gdscript", "rust"]:
		return false
	if backend == "rust" and (not state.get("native") is PackedByteArray
		or not state.get("incoming") is Dictionary or not state.get("binding") is Dictionary
		or state.get("dirty") != false):
		return false
	var packed: bool = state.get("machines") is PackedByteArray
	if packed and (not SnapshotValues.integer(state.get("packed"), 1, 1)
		or not state.get("inputs") is PackedInt32Array or not state.get("outgoing") is PackedInt32Array):
		return false
	if _world == null or not SnapshotValues.number(state.get("time"), 0.0, 100000000.0) or (
		not SnapshotValues.number(state.get("compensation"), -0.00001, 0.00001)
		or not SnapshotValues.integer(state.get("tick"), 0, 6000000000)
		or not SnapshotValues.integer(state.get("flushed"), -1, 6000000000)
		or not SnapshotValues.integer(state.get("next_id"), 1, SnapshotValues.MAX_INTEGER)
		or not state.get("interval") is float
		or not SnapshotValues.integer(state.get("amount"), SnapshotValues.MIN_INTEGER, SnapshotValues.MAX_INTEGER)
		or not state.get("dirty") is bool or (not packed and (
			not state.get("machines") is Array or not state.get("inputs") is Array or not state.get("outgoing") is Array))
	):
		return false
	var time: float = state["time"]
	var tick: int = state["tick"]
	var flushed: int = state["flushed"]
	if tick != int(floorf((time + TIME_EPSILON) / LOGIC_STEP)) or flushed > tick:
		return false
	var rows: Array = []
	var bytes: PackedByteArray = PackedByteArray()
	if packed:
		bytes = state["machines"]
		if bytes.size() % LogisticsPacked.ROW_SIZE != 0:
			return false
	else:
		rows = state["machines"]
	var count: int = bytes.size() / LogisticsPacked.ROW_SIZE if packed else rows.size()
	if count != _topology.machines.size():
		return false
	var topology: LogisticsTopology = LogisticsTopology.new()
	topology.clear(_world)
	var ids: Dictionary[int, bool] = {}
	for index: int in range(count):
		var value: Variant = LogisticsPacked.read_row(bytes, index) if packed else rows[index]
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
	var outgoing: Array = []
	var inputs: Array = []
	if packed:
		var packed_outgoing: PackedInt32Array = state["outgoing"]
		var packed_inputs: PackedInt32Array = state["inputs"]
		outgoing.assign(Array(packed_outgoing))
		inputs.assign(Array(packed_inputs))
	else:
		var array_outgoing: Array = state["outgoing"]
		var array_inputs: Array = state["inputs"]
		outgoing.assign(array_outgoing)
		inputs.assign(array_inputs)
	if outgoing.size() != count or inputs.size() != count * 3:
		return false
	for value: Variant in outgoing + inputs:
		if not SnapshotValues.integer(value, -1, count - 1):
			return false
	topology.outgoing.assign(outgoing)
	topology.inputs.assign(inputs)
	for target: int in range(count):
		for port: int in range(3):
			var source: int = topology.inputs[target * 3 + port]
			if source < 0:
				continue
			if topology.outgoing[source] != target or not topology.connects(source, target, port):
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
	var native: RustTransport
	if backend == "rust":
		if not ids.is_empty():
			return false
		native = RustTransport.new()
		var next_id: int = state["next_id"]
		var binding: Dictionary = state["binding"]
		var checkpoint: PackedByteArray = state["native"]
		var incoming: Dictionary = state["incoming"]
		if not native.prepare(topology, next_id, tick, binding) or (
			not native.restore(checkpoint, tick)
			or not native.restore_incoming(incoming)
			or native.last_identity() + 1 != state["next_id"]
		):
			return false
	var resume_regions: bool = _transport_regions.active
	_straight_transport.clear()
	_transport_regions.clear()
	_topology = topology
	_rust_requested = backend == "rust"
	_rust_transport = native
	_transport_error = ""
	_time = time
	_time_compensation = state["compensation"]
	_tick = tick
	_flushed_tick = state["flushed"]
	_batch.next_ore_id = state["next_id"]
	_mining_interval = state["interval"]
	_mining_amount = state["amount"]
	_sample_queues.clear()
	_advance_queues.clear()
	_cache_ore_slots = 0
	_position_solver.clear()
	_batch.clear()
	for machine: LogisticsMachine in _topology.machines:
		_add_queue_rows(machine)
	if resume_regions and not _rust_requested:
		if _topology.machines.is_empty():
			_transport_regions.active = true
		else:
			_transport_regions.prepare(_topology)
	_version += 1
	_sample_version = -1
	reset.emit()
	return true


func work_stats() -> Dictionary[String, int]:
	var result: Dictionary[String, int] = {
		"advance": _work_count, "edit": _edit_work,
		"batches": _batch_count, "transfer_calls": _transfer_calls,
		"sample": _sample_work, "sample_solves": _sample_solves,
		"cache_rows": _sample_queues.size(),
		"advance_queue_rows": _advance_queues.size(),
		"queue_creations": _queue_creations, "cache_ore_creations": _cache_ore_creations,
		"cache_ore_slots": _cache_ore_slots,
		"solver_workspace_growths": _position_solver.workspace_growths,
		"solver_node_capacity": _position_solver.node_capacity(),
		"batch_workspace_growths": _batch.workspace_growths,
		"batch_capacity": _batch.capacity(),
		"sample_return_rows": _sample_return_rows, "sample_return_ores": _sample_return_ores,
		"sample_direct_rows": _sample_direct_rows,
		"sample_dependency_rows": _sample_dependency_rows,
		"sample_prediction_hits": _sample_prediction_hits,
		"candidate_partitions": _topology.candidate_partition_visits,
		"candidate_checks": _topology.candidate_checks,
		"candidate_copies": _topology.candidate_copies,
		"candidate_partition_count": _topology.candidate_partition_count(),
		"straight_line_active": 1 if _straight_transport.active else 0,
		"straight_common_ticks": _straight_transport.common_ticks,
		"straight_blocked_ticks": _straight_transport.blocked_ticks,
		"straight_exit_events": _straight_transport.exit_events,
		"straight_machine_visits": _straight_transport.machine_visits,
		"straight_ore_visits": _straight_transport.ore_visits,
		"straight_materialized_ores": _straight_transport.materialized_ores,
		"straight_fallback_work": _straight_transport.fallback_work,
	}
	result.merge(_transport_regions.stats(), true)
	if _rust_transport != null:
		result.merge(_rust_transport.stats(), true)
	return result


func _ensure_rust() -> bool:
	if not _transport_error.is_empty():
		return false
	if _rust_transport != null:
		return true
	_topology.rebuild()
	var staged: RustTransport = RustTransport.new()
	if not staged.prepare(_topology, _batch.next_ore_id, _tick):
		_transport_error = staged.error
		return false
	_rust_transport = staged
	_rust_transport.release_host_queues(_topology)
	_sample_queues.clear()
	_advance_queues.clear()
	_cache_ore_slots = 0
	_batch.next_ore_id = _rust_transport.last_identity() + 1
	return true


func _before_rust_edit() -> void:
	if _rust_transport == null:
		return
	if _rust_transport.stats()["rust_items"] > 0:
		_rust_transport.materialize(_topology)
		_edit_work += _topology.machines.size() + _rust_transport.stats()["rust_items"]
		if not _rust_transport.error.is_empty():
			_transport_error = _rust_transport.error
			return
	_batch.next_ore_id = _rust_transport.last_identity() + 1
	_rust_transport = null


func _advance_rust(delta: float) -> void:
	if not _ensure_rust():
		return
	var corrected: float = delta - _time_compensation
	var end_time: float = _time + corrected
	if not is_finite(end_time) or end_time / LOGIC_STEP >= float(SnapshotValues.MAX_INTEGER):
		return
	var compensation: float = (end_time - _time) - corrected
	var end_tick: int = int(floorf((end_time + TIME_EPSILON) / LOGIC_STEP))
	while _tick < end_tick:
		if not _rust_transport.advance_tick(_topology, _tick + 1):
			_transport_error = _rust_transport.error
			return
		_tick += 1
		_time = float(_tick) * LOGIC_STEP
		_time_compensation = 0.0
		_batch.next_ore_id = _rust_transport.last_identity() + 1
		_batch_count += 1
		_work_count += _rust_transport.work
		_version += 1
	_batch.next_ore_id = _rust_transport.last_identity() + 1
	_time = end_time
	_time_compensation = compensation


func _prediction_time(extra_time: float) -> float:
	var boundary: float = float(_tick) * LOGIC_STEP
	var requested: float = extra_time if is_finite(extra_time) and extra_time > 0.0 else 0.0
	return clampf(_time + requested, boundary, float(_tick + 1) * LOGIC_STEP)


func _ensure_sample(extra_time: float) -> void:
	var boundary: float = float(_tick) * LOGIC_STEP
	var sample_time: float = _prediction_time(extra_time)
	if _sample_version == _version and _sample_time == sample_time:
		_sample_work = _full_sample_work
		return
	var copy_work: int = 0
	for index: int in range(_topology.machines.size()):
		copy_work += 1
		var machine: LogisticsMachine = _topology.machines[index]
		var queue: LogisticsOreQueue = _sample_queues[index]
		# Each live row owns at most two copies. Deleted rows retire at the edit,
		# so this cleanup never depends on a previous, larger facility count.
		copy_work += queue.ores.size()
		var created: int = 0
		if _transport_regions.active:
			created = _transport_regions.refresh_prediction(queue, _topology.cells[index], machine)
			copy_work += _transport_regions.prediction_work
		else:
			created = queue.refresh_prediction(machine, _topology.cells[index], _progress_offset())
		_cache_ore_creations += created
		_cache_ore_slots += created
		copy_work += queue.ores.size()
	_position_solver.advance(_topology, _sample_queues, sample_time - boundary)
	_sample_solves += 1
	_sample_work = copy_work + _position_solver.work
	_full_sample_work = _sample_work
	_sample_version = _version
	_sample_time = sample_time


func _advance_belts(delta: float) -> void:
	_work_count += _advance_queues.size()
	_position_solver.advance(_topology, _advance_queues, delta)
	_work_count += _position_solver.work


func _rebuild_topology() -> void:
	if _transport_regions.active:
		_topology.rebuild_pending()
	else:
		_topology.rebuild()
	_work_count += _topology.work


func _on_world_reset() -> void:
	_rust_transport = null
	_transport_error = ""
	_straight_transport.clear()
	_transport_regions.clear()
	_topology.clear(_world)
	_sample_queues.clear()
	_advance_queues.clear()
	_cache_ore_slots = 0
	_position_solver.clear()
	_batch.clear()
	_time = 0.0
	_time_compensation = 0.0
	_tick = 0
	_flushed_tick = -1
	_batch.next_ore_id = 1
	_version += 1
	for cell: Vector3i in _world.solid_cells():
		var block: int = _world.get_block(cell)
		if is_machine(block):
			var machine: LogisticsMachine = LogisticsMachine.new(block, _time, _mining_interval, _mining_amount)
			_topology.add(cell, machine)
			_add_queue_rows(machine)
	if _pure_segments_requested:
		enable_pure_segments()
	reset.emit()


func _on_cell_changed(cell: Vector3i) -> void:
	_edit_work = 0
	var index: int = _topology.index_at(cell)
	var block: int = _world.get_block(cell)
	if index < 0 and not is_machine(block):
		_version += 1
		machine_changed.emit(cell)
		return
	_before_rust_edit()
	if _transport_regions.active:
		_edit_work += _transport_regions.before_edit(cell)
		_transport_regions.remove(cell)
	else:
		_stop_straight_transport()
	if index >= 0:
		# Compact the cache in the same order as the topology, in constant work.
		if not _rust_requested:
			_cache_ore_slots -= _sample_queues[index].cached_ore_slots()
			_sample_queues[index] = _sample_queues[-1]
			_sample_queues.pop_back()
			_advance_queues[index] = _advance_queues[-1]
			_advance_queues.pop_back()
		_topology.remove(index)
	if is_machine(block):
		var machine: LogisticsMachine = LogisticsMachine.new(block, _time, _mining_interval, _mining_amount)
		_topology.add(cell, machine)
		_add_queue_rows(machine)
		if _transport_regions.active:
			_transport_regions.register_machine(cell, machine)
	_version += 1
	machine_changed.emit(cell)


func _add_queue_rows(machine: LogisticsMachine) -> void:
	if _rust_requested:
		return
	var borrowed: LogisticsOreQueue = LogisticsOreQueue.new()
	borrowed.ores = machine.belt_ores
	_advance_queues.append(borrowed)
	_sample_queues.append(LogisticsOreQueue.new())
	_queue_creations += 2


func _stop_straight_transport() -> void:
	if _transport_regions.active:
		_transport_regions.materialize()
		_transport_regions.clear()
	if not _straight_transport.active:
		return
	_straight_transport.materialize(_topology)
	_straight_transport.clear()


func _progress_offset() -> float:
	return _straight_transport.progress_offset


func _eligibility_is_quantity() -> bool:
	return _straight_transport.eligibility_is_quantity()
