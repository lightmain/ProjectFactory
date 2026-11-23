class_name BeltStraightTransport
extends RefCounted
## Development slice: one settled straight chain, optionally ending in a chest.
## The existing machine queues own identities. Their progress plus the shared
## offset is authoritative until an exit event materializes the offset.

var active: bool = false
var progress_offset: float = 0.0
var common_ticks: int = 0
var blocked_ticks: int = 0
var exit_events: int = 0
var machine_visits: int = 0
var ore_visits: int = 0
var materialized_ores: int = 0
var fallback_work: int = 0
var work: int = 0
var transfer_calls: int = 0
var _exit_distance: float = INF
var _eligibility_current: bool = false
var _blocked: bool = false


func prepare(topology: LogisticsTopology) -> bool:
	if active:
		return true
	if topology.dirty or topology.machines.is_empty():
		return false
	var direction: Vector3i = topology.machines[0].settled_direction
	var start: int = -1
	var terminals: int = 0
	for index: int in range(topology.machines.size()):
		machine_visits += 1
		var machine: LogisticsMachine = topology.machines[index]
		if machine.block not in [VoxelWorldData.Block.BELT, VoxelWorldData.Block.CHEST] or (
			machine.direction != direction or machine.settled_direction != direction
			or topology.inputs[index * 3 + 1] >= 0 or topology.inputs[index * 3 + 2] >= 0
		):
			return false
		if machine.block == VoxelWorldData.Block.CHEST and topology.outgoing[index] >= 0:
			return false
		if topology.inputs[index * 3] < 0:
			if start >= 0:
				return false
			start = index
		if topology.outgoing[index] < 0:
			terminals += 1
	if start < 0 or terminals != 1 or topology.machines[start].block != VoxelWorldData.Block.BELT:
		return false
	var count: int = 0
	var cursor: int = start
	while cursor >= 0 and count < topology.machines.size():
		machine_visits += 1
		count += 1
		cursor = topology.outgoing[cursor]
	if count != topology.machines.size() or cursor >= 0:
		return false
	active = true
	_blocked = false
	progress_offset = 0.0
	_eligibility_current = false
	_refresh_exit_distance(topology)
	return true


func advance_tick(
	topology: LogisticsTopology, queues: Array[LogisticsOreQueue],
	solver: BeltPositionSolver, batch: LogisticsBatch, tick: int
) -> void:
	work = 1
	transfer_calls = 0
	if _blocked:
		# No production exists in this restricted path. A zero-movement,
		# zero-transfer batch is a fixed point until an edit invalidates it.
		_eligibility_current = true
		blocked_ticks += 1
		return
	var movement: float = LogisticsData.LOGIC_STEP / LogisticsData.BELT_TRAVEL_TIME
	# Before any ore reaches its cell exit, all caps and gaps translate equally.
	# Tolerant batch readiness still needs the event slightly before exact 1.0.
	if progress_offset + movement < _exit_distance - LogisticsData.TIME_EPSILON:
		progress_offset += movement
		# A formal tick makes all quantities eligible. Defer per-cell writes
		# until an exit/edit; public expansion reads this epoch as quantity.
		_eligibility_current = true
		common_ticks += 1
		return
	exit_events += 1
	materialize(topology, false)
	solver.advance(topology, queues, LogisticsData.LOGIC_STEP)
	work += solver.work
	_set_eligibility(topology)
	batch.transfer(topology, tick)
	transfer_calls = 1
	work += batch.work
	fallback_work += solver.work + batch.work
	_blocked = solver.moved_ores == 0 and batch.transfers == 0
	# Only the following formal tick may make this batch's arrivals eligible.
	_eligibility_current = false
	_refresh_exit_distance(topology)


func eligibility_is_quantity() -> bool:
	return _eligibility_current


func materialize(topology: LogisticsTopology, include_eligibility: bool = true) -> void:
	if progress_offset == 0.0 and (not include_eligibility or not _eligibility_current):
		return
	for machine: LogisticsMachine in topology.machines:
		machine_visits += 1
		work += 1
		if include_eligibility and _eligibility_current:
			machine.eligible_quantity = machine.quantity
		if progress_offset != 0.0:
			for ore: LogisticsOre in machine.belt_ores:
				ore_visits += 1
				materialized_ores += 1
				work += 1
				ore.progress += progress_offset
	progress_offset = 0.0
	if include_eligibility:
		_eligibility_current = false


func clear() -> void:
	active = false
	progress_offset = 0.0
	_exit_distance = INF
	_eligibility_current = false
	_blocked = false


func _set_eligibility(topology: LogisticsTopology) -> void:
	for machine: LogisticsMachine in topology.machines:
		machine_visits += 1
		work += 1
		machine.eligible_quantity = machine.quantity


func _refresh_exit_distance(topology: LogisticsTopology) -> void:
	_exit_distance = INF
	for machine: LogisticsMachine in topology.machines:
		machine_visits += 1
		work += 1
		for ore: LogisticsOre in machine.belt_ores:
			ore_visits += 1
			work += 1
			_exit_distance = minf(_exit_distance, 1.0 - ore.progress)
