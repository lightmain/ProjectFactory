class_name BeltTransportLines
extends RefCounted
## Development network slice. A shared displacement is safe before any cell
## exit because every existing path constraint translates at the same speed.
## Active legacy regions and boundary events explicitly use the original batch.

var active: bool = false
var line_count: int = 0
var progress_offset: float = 0.0
var common_ticks: int = 0
var boundary_events: int = 0
var exit_events: int = 0
var machine_visits: int = 0
var ore_visits: int = 0
var materialized_ores: int = 0
var fallback_work: int = 0
var blocked_ticks: int = 0
var inventory_checks: int = 0
var work: int = 0
var transfer_calls: int = 0
var legacy_belts: int = 0
var slope_belts: int = 0
var _exit_distance: float = INF
var _input_distance: float = INF
var _eligibility_current: bool = false
var _legacy_occupied: bool = false
var _blocked: bool = false
var _inventories: Array[int] = []
var _aggregated: Array[bool] = []


func prepare(topology: LogisticsTopology) -> bool:
	if active:
		return true
	if topology.dirty or topology.machines.is_empty():
		return false
	_aggregated.resize(topology.machines.size())
	_aggregated.fill(false)
	_inventories.clear()
	legacy_belts = 0
	slope_belts = 0
	line_count = 0
	for index: int in range(topology.machines.size()):
		machine_visits += 1
		var machine: LogisticsMachine = topology.machines[index]
		if not VoxelWorldData.is_belt(machine.block):
			_inventories.append(index)
		else:
			_aggregated[index] = true
			if VoxelWorldData.is_slope(machine.block):
				slope_belts += 1
	# Classify cycles without recursion. They remain an explicit legacy region
	# for this slice, including cycles whose path contains a slope. Every
	# acyclic belt has the same normalized travel time, including ramps.
	var states: Array[int] = []
	states.resize(_aggregated.size())
	states.fill(0)
	var stack: Array[int] = []
	var has_cycle: bool = false
	for start: int in range(states.size()):
		if states[start] != 0:
			continue
		stack.clear()
		var cursor: int = start
		while cursor >= 0 and states[cursor] == 0:
			machine_visits += 1
			states[cursor] = 1
			stack.append(cursor)
			cursor = topology.outgoing[cursor]
		if cursor >= 0 and states[cursor] == 1:
			has_cycle = true
			var first: int = stack.find(cursor)
			for position: int in range(first, stack.size()):
				var index: int = stack[position]
				if _aggregated[index]:
					_aggregated[index] = false
					legacy_belts += 1
					if VoxelWorldData.is_slope(topology.machines[index].block):
						slope_belts -= 1
		for index: int in stack:
			states[index] = 2
	# A merge is a boundary, not a line. Count maximal non-merge runs.
	for index: int in range(_aggregated.size()):
		machine_visits += 1
		if not _aggregated[index] or _input_count(topology, index) > 1:
			continue
		var predecessor: int = -1
		for port: int in range(3):
			var source: int = topology.inputs[index * 3 + port]
			if source >= 0:
				predecessor = source
		if predecessor < 0 or not _aggregated[predecessor] or _input_count(topology, predecessor) > 1:
			line_count += 1
	if line_count == 0 and not has_cycle and _inventories.is_empty():
		clear()
		return false
	active = true
	progress_offset = 0.0
	_eligibility_current = false
	_refresh_events(topology)
	return true


func advance_tick(
	topology: LogisticsTopology, queues: Array[LogisticsOreQueue],
	solver: BeltPositionSolver, batch: LogisticsBatch, tick: int, production_due: bool = false
) -> void:
	work = 1
	transfer_calls = 0
	if _blocked and not production_due:
		# After an eligible, zero-motion/zero-transfer formal batch, nothing
		# inside this settled graph can free a port without production/edit.
		_eligibility_current = true
		blocked_ticks += 1
		return
	var movement: float = LogisticsData.LOGIC_STEP / LogisticsData.BELT_TRAVEL_TIME
	var input_due: bool = progress_offset + movement >= _input_distance - LogisticsData.TIME_EPSILON
	var exit_due: bool = progress_offset + movement >= _exit_distance - LogisticsData.TIME_EPSILON
	if not production_due and not input_due and not exit_due and not _legacy_occupied:
		progress_offset += movement
		_eligibility_current = true
		common_ticks += 1
		return
	if production_due or input_due:
		boundary_events += 1
	if exit_due:
		exit_events += 1
	materialize(topology, false)
	solver.advance(topology, queues, LogisticsData.LOGIC_STEP)
	work += solver.work
	for machine: LogisticsMachine in topology.machines:
		machine_visits += 1
		work += 1
		machine.eligible_quantity = machine.quantity
	batch.transfer(topology, tick)
	transfer_calls = 1
	work += batch.work
	fallback_work += solver.work + batch.work
	_blocked = solver.moved_ores == 0 and batch.transfers == 0
	_eligibility_current = false
	_refresh_events(topology)


func eligibility_is_quantity() -> bool:
	return _eligibility_current


func prediction_displacement(delta: float) -> float:
	## Display queries never transfer inventory or wake production.
	if _blocked:
		return 0.0
	var movement: float = delta / LogisticsData.BELT_TRAVEL_TIME
	if active and not _legacy_occupied and progress_offset + movement <= _exit_distance:
		return movement
	return NAN


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
				work += 1
				materialized_ores += 1
				ore.progress += progress_offset
	progress_offset = 0.0
	if include_eligibility:
		_eligibility_current = false


func clear() -> void:
	active = false
	line_count = 0
	legacy_belts = 0
	slope_belts = 0
	progress_offset = 0.0
	_eligibility_current = false
	_legacy_occupied = false
	_blocked = false
	_exit_distance = INF
	_input_distance = INF
	_inventories.clear()
	_aggregated.clear()


func _refresh_events(topology: LogisticsTopology) -> void:
	_exit_distance = INF
	_input_distance = INF
	_legacy_occupied = false
	for index: int in range(topology.machines.size()):
		machine_visits += 1
		work += 1
		var machine: LogisticsMachine = topology.machines[index]
		if VoxelWorldData.is_belt(machine.block) and not _aggregated[index] and machine.quantity > 0:
			_legacy_occupied = true
		for ore: LogisticsOre in machine.belt_ores:
			ore_visits += 1
			work += 1
			_exit_distance = minf(_exit_distance, 1.0 - ore.progress)
	for slot: int in range(_inventories.size()):
		inventory_checks += 1
		machine_visits += 1
		work += 1
		var source: int = _inventories[slot]
		var target: int = topology.outgoing[source]
		var threshold: float = INF
		if topology.machines[source].quantity > 0 and target >= 0:
			var machine: LogisticsMachine = topology.machines[target]
			machine_visits += 1
			work += 1
			if not VoxelWorldData.is_belt(machine.block) or machine.belt_ores.is_empty():
				threshold = 0.0
			elif machine.quantity < LogisticsData.BELT_CAPACITY:
				ore_visits += 1
				work += 1
				threshold = maxf(0.0, 0.5 - machine.belt_ores[-1].progress)
		_input_distance = minf(_input_distance, threshold)


static func _input_count(topology: LogisticsTopology, index: int) -> int:
	var count: int = 0
	for port: int in range(3):
		if topology.inputs[index * 3 + port] >= 0:
			count += 1
	return count
