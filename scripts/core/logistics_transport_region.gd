class_name LogisticsTransportRegion
extends RefCounted
## A settled connected graph borrowing the authoritative machines and ores.

var topology: LogisticsTopology = LogisticsTopology.new(true)
var lines: BeltTransportLines = BeltTransportLines.new()
var ring: BeltRingTransport = BeltRingTransport.new()
var solver: BeltPositionSolver = BeltPositionSolver.new()
var batch: LogisticsBatch = LogisticsBatch.new()
var pure_segments: bool = false
var segments: BeltSegmentTransport = BeltSegmentTransport.new()
var queues: Array[LogisticsOreQueue] = []
var invalidated: bool = false
var work: int = 0
var transfer_calls: int = 0
var prepare_work: int = 0
var prediction_work: int = 0
var prediction_direct_rows: int = 0
var prediction_dependency_rows: int = 0
var prediction_hits: int = 0
var prediction_solves: int = 0
var prediction_queue_creations: int = 0
var prediction_ore_creations: int = 0
var prediction_ore_slots: int = 0
var _prediction_rows: Dictionary[Vector3i, LogisticsOreQueue] = {}
var _prediction_stamps: Dictionary[Vector3i, int] = {}
var _prediction_queues: Array[LogisticsOreQueue] = []
var _prediction_solver: BeltPositionSolver = BeltPositionSolver.new()
var _prediction_version: int = -1
var _prediction_delta: float = -1.0
var _prediction_generation: int = 0
var _dependency_generation: int = -1
var _port_edits: Dictionary[Vector3i, bool] = {}
var _segments_moved: bool = false


func _init() -> void:
	batch.defer_identity = true


func prepare(defer_pure_segments: bool = false) -> void:
	clear_prediction()
	prepare_work = 0
	if segments.active:
		prepare_work += segments.materialize()
	var before: int = lines.machine_visits + lines.ore_visits + ring.machine_visits + ring.ore_visits
	lines.clear()
	ring.clear()
	invalidated = false
	queues.clear()
	for machine: LogisticsMachine in topology.machines:
		prepare_work += 1
		var queue: LogisticsOreQueue = LogisticsOreQueue.new()
		queue.ores = machine.belt_ores
		queues.append(queue)
	topology.accept_settled()
	if pure_segments:
		# Edited regions still need raw queues for the pending boundary batch.
		# Merge only after that batch, avoiding an immediate second expansion.
		if not defer_pure_segments:
			segments.prepare(topology)
			prepare_work += segments.work
		return
	if not ring.prepare(topology):
		lines.prepare(topology)
	prepare_work += lines.machine_visits + lines.ore_visits + ring.machine_visits + ring.ore_visits - before


func invalidate() -> int:
	if invalidated:
		return 0
	var edit_work: int = 0
	if _segments_moved:
		edit_work += segments.accept_movement()
		_segments_moved = false
	_port_edits.clear()
	if segments.active:
		edit_work += segments.materialize()
	if ring.active:
		ring.materialize(topology)
		ring.clear()
	if lines.active:
		lines.materialize(topology)
		lines.clear()
	invalidated = true
	return edit_work


func mark_port_edit(cell: Vector3i) -> void:
	_port_edits[cell] = true
	clear_prediction()


func move_segments_before_rebuild() -> void:
	segments.move_tick()
	work = segments.work
	_segments_moved = true


func refresh_ports(global_topology: LogisticsTopology) -> bool:
	work = 0
	segments.work = 0
	var valid: bool = true
	var nearby_cells: Dictionary[Vector3i, bool] = {}
	for cell: Vector3i in _port_edits:
		for nearby: Vector3i in LogisticsTopology.edit_neighborhood(cell):
			work += 1
			nearby_cells[nearby] = true
	for cell: Vector3i in nearby_cells:
		work += 1
		var index: int = topology.index_at(cell)
		if index < 0:
			continue
		var global_index: int = global_topology.index_at(cell)
		var target: int = global_topology.outgoing[global_index]
		topology.outgoing[index] = topology.index_at(global_topology.cells[target]) if target >= 0 else -1
		for port: int in range(3):
			work += 1
			var source: int = global_topology.inputs[global_index * 3 + port]
			topology.inputs[index * 3 + port] = topology.index_at(global_topology.cells[source]) if source >= 0 else -1
		valid = segments.accepts_edges(index) and valid
	work += segments.work
	var accepted: bool = valid and segments.refresh_boundaries()
	if not valid:
		segments.work = 0
	work += segments.work
	if accepted:
		_port_edits.clear()
		clear_prediction()
	return accepted


func settle_segments_tick(tick: int) -> void:
	segments.transfer_moved(tick, batch)
	work = segments.work
	transfer_calls = 0
	_segments_moved = false


func supplemental_segments(tick: int) -> void:
	segments.supplemental(tick, batch)
	work = segments.work
	transfer_calls = 0


func remove(cell: Vector3i) -> void:
	var index: int = topology.index_at(cell)
	if index < 0:
		return
	clear_prediction()
	queues[index] = queues[-1]
	queues.pop_back()
	topology.remove(index)


func move_before_rebuild() -> void:
	solver.advance(topology, queues, LogisticsData.LOGIC_STEP)
	work = solver.work
	lines.fallback_work += solver.work


func settle_tick(tick: int) -> void:
	work = 0
	if segments.active:
		work += segments.materialize()
	for machine: LogisticsMachine in topology.machines:
		work += 1
		lines.machine_visits += 1
		machine.eligible_quantity = machine.quantity
	transfer(tick)


func transfer(tick: int) -> void:
	if segments.active:
		work += segments.materialize()
	batch.transfer(topology, tick)
	work += batch.work
	lines.fallback_work += batch.work
	transfer_calls = 1


func advance_tick(tick: int, production_due: bool = false) -> void:
	work = 0
	transfer_calls = 0
	if segments.active:
		segments.advance_tick(tick, batch)
		work = segments.work
	elif ring.active:
		ring.advance_tick(topology, tick)
		work = ring.work
	elif lines.active:
		lines.advance_tick(topology, queues, solver, batch, tick, production_due)
		work = lines.work
		transfer_calls = lines.transfer_calls
	else:
		if pure_segments:
			segments.fallback_ticks += 1
		move_before_rebuild()
		var movement_work: int = work
		settle_tick(tick)
		work += movement_work


func save_row(cell: Vector3i) -> Dictionary:
	var index: int = topology.index_at(cell)
	if segments.active:
		return segments.save_row(index)
	if ring.contains(index):
		return ring.save_row(topology, index)
	return topology.machines[index].save_state(lines.progress_offset, lines.eligibility_is_quantity())


func write_row(bytes: PackedByteArray, global_index: int, cell: Vector3i) -> void:
	var index: int = topology.index_at(cell)
	if segments.active:
		segments.write_row(bytes, global_index, index)
	elif ring.contains(index):
		ring.write_row(bytes, topology, index, global_index)
	else:
		LogisticsPacked.write_row(
			bytes, global_index, cell, topology.machines[index],
			lines.progress_offset, lines.eligibility_is_quantity()
		)


func refresh_prediction(queue: LogisticsOreQueue, cell: Vector3i) -> int:
	prediction_work = 0
	var index: int = topology.index_at(cell)
	if segments.active:
		var before: int = segments.work
		var created: int = segments.refresh_prediction(queue, index)
		prediction_work = segments.work - before
		return created
	if ring.contains(index):
		return ring.refresh_prediction(queue, topology, index)
	return queue.refresh_prediction(topology.machines[index], cell, lines.progress_offset)


func clear_prediction() -> void:
	_prediction_rows.clear()
	_prediction_stamps.clear()
	_prediction_queues.clear()
	_prediction_solver.clear()
	prediction_ore_slots = 0
	_prediction_version = -1
	_dependency_generation = -1


func prediction_cache_rows() -> int:
	return _prediction_rows.size()


func sample_row(cell: Vector3i, version: int, delta: float) -> LogisticsOreQueue:
	prediction_work = 1
	prediction_direct_rows = 0
	prediction_dependency_rows = 0
	prediction_hits = 0
	prediction_solves = 0
	if version != _prediction_version or delta != _prediction_delta:
		_prediction_version = version
		_prediction_delta = delta
		_prediction_generation += 1
	if _prediction_stamps.get(cell, -1) == _prediction_generation:
		prediction_hits = 1
		return _prediction_rows[cell]
	var index: int = topology.index_at(cell)
	var machine: LogisticsMachine = topology.machines[index]
	if segments.active:
		var solved: bool = segments.prepare_prediction(version, delta)
		var before_work: int = segments.work
		var queue: LogisticsOreQueue = _prediction_row(cell)
		var created: int = segments.refresh_prediction(queue, index, true)
		prediction_work += segments.prediction_work + segments.work - before_work
		prediction_ore_creations += created
		prediction_ore_slots += created
		prediction_direct_rows = 1
		prediction_solves = int(solved)
		_prediction_stamps[cell] = _prediction_generation
		return queue
	var movement: float = lines.prediction_displacement(delta)
	if delta == 0.0 or machine.belt_ores.is_empty() or ring.contains(index) or is_finite(movement):
		var queue: LogisticsOreQueue = _prediction_row(cell)
		_refresh_sample_row(queue, cell)
		# Uniform rings can reach a cell exit during prediction, but the
		# query only clamps positions; identities transfer at a formal tick.
		var limit: float = 1.0
		var displacement: float = delta / LogisticsData.BELT_TRAVEL_TIME if ring.contains(index) else movement
		if not is_finite(displacement):
			displacement = 0.0
		for ore: LogisticsOre in queue.ores:
			prediction_work += 1
			ore.progress = minf(ore.progress + displacement, limit)
			limit = ore.progress - 0.5
		_prediction_stamps[cell] = _prediction_generation
		prediction_direct_rows = 1
		return queue
	_prepare_dependency()
	return _prediction_rows[cell]


func _prediction_row(cell: Vector3i) -> LogisticsOreQueue:
	if not _prediction_rows.has(cell):
		_prediction_rows[cell] = LogisticsOreQueue.new()
		prediction_queue_creations += 1
	return _prediction_rows[cell]


func _refresh_sample_row(queue: LogisticsOreQueue, cell: Vector3i) -> void:
	prediction_work += 1 + queue.ores.size()
	var created: int = refresh_prediction(queue, cell)
	prediction_ore_creations += created
	prediction_ore_slots += created
	prediction_work += queue.ores.size()


func _prepare_dependency() -> void:
	if _dependency_generation == _prediction_generation:
		return
	if _prediction_queues.is_empty():
		for cell: Vector3i in topology.cells:
			prediction_work += 1
			_prediction_queues.append(_prediction_row(cell))
	for index: int in range(topology.cells.size()):
		var cell: Vector3i = topology.cells[index]
		_refresh_sample_row(_prediction_queues[index], cell)
		_prediction_stamps[cell] = _prediction_generation
		prediction_dependency_rows += 1
	_prediction_solver.advance(topology, _prediction_queues, _prediction_delta)
	prediction_solves = 1
	prediction_work += _prediction_solver.work
	_dependency_generation = _prediction_generation
