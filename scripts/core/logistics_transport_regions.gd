class_name LogisticsTransportRegions
extends RefCounted
## Spatial ownership survives global dense-index compaction. Only invalidated
## connected graphs are rediscovered; no region allocates a world-sized lookup.

var active: bool = false
var pure_segments: bool = false
var rebuilt_machines: int = 0
var rebuild_work: int = 0
var work: int = 0
var transfer_calls: int = 0
var common_ticks: int = 0
var _regions: Dictionary[LogisticsTransportRegion, bool] = {}
var _owners: Dictionary[Vector3i, LogisticsTransportRegion] = {}
var _dirty: Dictionary[LogisticsTransportRegion, bool] = {}
var _retained: Dictionary[LogisticsTransportRegion, bool] = {}
var _pending: Dictionary[Vector3i, bool] = {}
var _retired_stats: Dictionary[String, int] = {}
var _created: Dictionary[Vector3i, LogisticsOre] = {}
var _production: LogisticsProductionSchedule = LogisticsProductionSchedule.new()
var _region_visits: int = 0
var prediction_work: int = 0
var prediction_direct_rows: int = 0
var prediction_dependency_rows: int = 0
var prediction_hits: int = 0
var prediction_solves: int = 0
var _prediction_queue_creations: int = 0
var _prediction_ore_creations: int = 0
var _unconnected_predictions: Dictionary[Vector3i, LogisticsOreQueue] = {}


func clear() -> void:
	active = false
	_regions.clear()
	_owners.clear()
	_dirty.clear()
	_retained.clear()
	_pending.clear()
	_retired_stats.clear()
	_created.clear()
	_production.clear()
	_region_visits = 0
	_unconnected_predictions.clear()
	begin_prediction()
	rebuilt_machines = 0
	rebuild_work = 0
	common_ticks = 0


func prepare(topology: LogisticsTopology) -> bool:
	if active:
		return true
	if topology.machines.is_empty():
		return false
	var preparation_work: int = 0
	for index: int in range(topology.cells.size()):
		var cell: Vector3i = topology.cells[index]
		_pending[cell] = true
		register_machine(cell, topology.machines[index])
		preparation_work += 1
	active = true
	rebuild(topology)
	rebuild_work += preparation_work + _production.work
	if topology.dirty:
		# Build from the saved settled edges; the requested graph enters only at
		# its normal batch boundary, after movement on these borrowed old edges.
		for region: LogisticsTransportRegion in _regions:
			region.invalidate()
			_dirty[region] = true
		for cell: Vector3i in topology.cells:
			_pending[cell] = true
	return true


func before_edit(cell: Vector3i, rotation: bool = false) -> int:
	var edit_work: int = 0
	var owner: LogisticsTransportRegion = _owners.get(cell)
	if rotation and owner != null and owner.segments.active and not _dirty.has(owner):
		var index: int = owner.topology.index_at(cell)
		var retain: bool = not VoxelWorldData.is_belt(owner.topology.machines[index].block)
		for nearby: Vector3i in LogisticsTopology.edit_neighborhood(cell):
			edit_work += 1
			var neighbor: LogisticsTransportRegion = _owners.get(nearby)
			if (neighbor != null and neighbor != owner) or _pending.has(nearby):
				retain = false
		if retain:
			owner.mark_port_edit(cell)
			_retained[owner] = true
			return edit_work
	for nearby: Vector3i in LogisticsTopology.edit_neighborhood(cell):
		edit_work += 1
		var region: LogisticsTransportRegion = _owners.get(nearby)
		if region != null:
			edit_work += region.invalidate()
			_dirty[region] = true
			_retained.erase(region)
	_pending[cell] = true
	return edit_work


func remove(cell: Vector3i) -> void:
	_production.remove(cell)
	_unconnected_predictions.erase(cell)
	var region: LogisticsTransportRegion = _owners.get(cell)
	if region != null:
		region.remove(cell)
		_owners.erase(cell)


func register_machine(cell: Vector3i, machine: LogisticsMachine) -> void:
	_production.add(cell, machine)


func move_before_rebuild() -> void:
	work = 0
	for region: LogisticsTransportRegion in _dirty:
		region.move_before_rebuild()
		work += region.work
	for region: LogisticsTransportRegion in _retained:
		region.move_segments_before_rebuild()
		work += region.work


func rebuild(topology: LogisticsTopology, defer_pure_segments: bool = false) -> Array[LogisticsTransportRegion]:
	rebuild_work = 0
	var result: Array[LogisticsTransportRegion] = []
	for region: LogisticsTransportRegion in _retained:
		if region.refresh_ports(topology):
			result.append(region)
		else:
			rebuild_work += region.invalidate()
			_dirty[region] = true
		rebuild_work += region.work
	_retained.clear()
	for region: LogisticsTransportRegion in _dirty:
		_accumulate(_retired_stats, _region_stats(region))
		for cell: Vector3i in region.topology.cells:
			rebuild_work += 1
			_pending[cell] = true
			_owners.erase(cell)
		_regions.erase(region)
	_dirty.clear()
	for cell: Vector3i in _pending:
		rebuild_work += 1
		var start: int = topology.index_at(cell)
		if start < 0 or _owners.has(cell):
			continue
		var region: LogisticsTransportRegion = LogisticsTransportRegion.new()
		region.pure_segments = pure_segments
		var indices: Array[int] = [start]
		_owners[cell] = region
		var read: int = 0
		while read < indices.size():
			var index: int = indices[read]
			read += 1
			rebuilt_machines += 1
			rebuild_work += 1
			var neighbors: Array[int] = [topology.outgoing[index]]
			for port: int in range(3):
				neighbors.append(topology.inputs[index * 3 + port])
			for neighbor: int in neighbors:
				rebuild_work += 1
				if neighbor < 0:
					continue
				var next_cell: Vector3i = topology.cells[neighbor]
				assert(not _owners.has(next_cell) or _owners[next_cell] == region, "Edit missed connected region")
				if not _owners.has(next_cell):
					_owners[next_cell] = region
					indices.append(neighbor)
		# Local batch ordering remains the global target order.
		indices.sort()
		for index: int in indices:
			rebuild_work += 1
			region.topology.add(topology.cells[index], topology.machines[index])
		for index: int in range(indices.size()):
			rebuild_work += 1
			var global_index: int = indices[index]
			var target: int = topology.outgoing[global_index]
			region.topology.outgoing[index] = region.topology.index_at(topology.cells[target]) if target >= 0 else -1
			for port: int in range(3):
				var source: int = topology.inputs[global_index * 3 + port]
				region.topology.inputs[index * 3 + port] = region.topology.index_at(topology.cells[source]) if source >= 0 else -1
		for owned_cell: Vector3i in region.topology.cells:
			_unconnected_predictions.erase(owned_cell)
		region.prepare(defer_pure_segments)
		rebuild_work += region.prepare_work
		_regions[region] = true
		result.append(region)
	_pending.clear()
	return result


func advance_tick(tick: int, moved: Array[LogisticsTransportRegion]) -> void:
	var before_production: int = _production.work
	var due: Array[Vector3i] = _production.produce_due(float(tick) * LogisticsData.LOGIC_STEP)
	work = _production.work - before_production
	var awakened: Dictionary[LogisticsTransportRegion, bool] = {}
	for cell: Vector3i in due:
		work += 1
		var owner: LogisticsTransportRegion = _owners.get(cell)
		assert(owner != null, "Scheduled miner has no transport region")
		awakened[owner] = true
	transfer_calls = 0
	var has_lines: bool = false
	var all_common: bool = true
	for region: LogisticsTransportRegion in _regions:
		_region_visits += 1
		work += 1
		var before_common: int = region.lines.common_ticks
		region.batch.created_ores.clear()
		if region in moved:
			if region.segments.active:
				region.settle_segments_tick(tick)
			else:
				region.settle_tick(tick)
				region.prepare()
				region.work += region.prepare_work
		else:
			region.advance_tick(tick, awakened.has(region))
		work += region.work
		transfer_calls += region.transfer_calls
		if region.lines.active:
			has_lines = true
			all_common = all_common and region.lines.common_ticks > before_common
		_collect_created(region)
	if has_lines and all_common and transfer_calls == 0:
		common_ticks += 1


func supplemental(tick: int, changed: Array[LogisticsTransportRegion]) -> void:
	work = 0
	transfer_calls = 0
	for region: LogisticsTransportRegion in changed:
		if region.segments.active:
			region.supplemental_segments(tick)
		else:
			region.transfer(tick)
			region.prepare()
			region.work += region.prepare_work
		work += region.work
		transfer_calls += region.transfer_calls
		_collect_created(region)


func _collect_created(region: LogisticsTransportRegion) -> void:
	for cell: Vector3i in region.batch.created_ores:
		_created[cell] = region.batch.created_ores[cell]
	region.batch.created_ores.clear()


func assign_identities(topology: LogisticsTopology, batch: LogisticsBatch) -> void:
	var indices: Array[int] = []
	for cell: Vector3i in _created:
		indices.append(topology.index_at(cell))
	indices.sort()
	for index: int in indices:
		work += 1
		_created[topology.cells[index]].id = batch.next_ore_id
		batch.next_ore_id += 1
	_created.clear()


func save_row(cell: Vector3i, machine: LogisticsMachine) -> Dictionary:
	var region: LogisticsTransportRegion = _owners.get(cell)
	return region.save_row(cell) if region != null else machine.save_state()


func quantity(cell: Vector3i, machine: LogisticsMachine) -> int:
	var region: LogisticsTransportRegion = _owners.get(cell)
	return region.segments.quantity(region.topology.index_at(cell)) \
		if region != null and region.segments.active else machine.quantity


func total_ore() -> int:
	var count: int = 0
	for region: LogisticsTransportRegion in _regions:
		if region.segments.active:
			count += region.segments.total_ore()
		else:
			for machine: LogisticsMachine in region.topology.machines:
				count += machine.quantity
	return count


func write_row(bytes: PackedByteArray, index: int, cell: Vector3i, machine: LogisticsMachine) -> void:
	var region: LogisticsTransportRegion = _owners.get(cell)
	if region != null:
		region.write_row(bytes, index, cell)
	else:
		LogisticsPacked.write_row(bytes, index, cell, machine)


func refresh_prediction(queue: LogisticsOreQueue, cell: Vector3i, machine: LogisticsMachine) -> int:
	prediction_work = 0
	var region: LogisticsTransportRegion = _owners.get(cell)
	if region == null:
		return queue.refresh_prediction(machine, cell)
	var created: int = region.refresh_prediction(queue, cell)
	prediction_work = region.prediction_work
	return created


func begin_prediction() -> void:
	prediction_work = 0
	prediction_direct_rows = 0
	prediction_dependency_rows = 0
	prediction_hits = 0
	prediction_solves = 0


func sample_row(
	cell: Vector3i, machine: LogisticsMachine, version: int, delta: float
) -> LogisticsOreQueue:
	prediction_work += 1
	var region: LogisticsTransportRegion = _owners.get(cell)
	if region == null:
		# New facilities have no settled edges or ores until the next batch.
		if not _unconnected_predictions.has(cell):
			_unconnected_predictions[cell] = LogisticsOreQueue.new()
			_prediction_queue_creations += 1
		var queue: LogisticsOreQueue = _unconnected_predictions[cell]
		prediction_work += 1
		queue.refresh_prediction(machine, cell)
		prediction_direct_rows += 1
		return queue
	var before_rows: int = region.prediction_queue_creations
	var before_ores: int = region.prediction_ore_creations
	var result: LogisticsOreQueue = region.sample_row(cell, version, delta)
	_prediction_queue_creations += region.prediction_queue_creations - before_rows
	_prediction_ore_creations += region.prediction_ore_creations - before_ores
	prediction_work += region.prediction_work
	prediction_direct_rows += region.prediction_direct_rows
	prediction_dependency_rows += region.prediction_dependency_rows
	prediction_hits += region.prediction_hits
	prediction_solves += region.prediction_solves
	return result


func materialize() -> void:
	for region: LogisticsTransportRegion in _regions:
		region.invalidate()


func stats() -> Dictionary[String, int]:
	var result: Dictionary[String, int] = _retired_stats.duplicate()
	for key: String in [
		"transport_line_count", "transport_legacy_belts", "transport_slope_belts",
		"transport_common_ticks", "transport_exit_events", "transport_boundary_events",
		"transport_machine_visits", "transport_ore_visits", "transport_materialized_ores",
		"transport_fallback_work", "transport_ring_count", "transport_ring_ticks",
		"transport_ring_exits", "transport_ring_machine_visits", "transport_ring_ore_visits",
		"transport_ring_materialized_ores",
		"transport_blocked_ticks", "transport_inventory_checks",
	]:
		if not result.has(key):
			result[key] = 0
	for region: LogisticsTransportRegion in _regions:
		_accumulate(result, _region_stats(region))
	for key: String in ["pure_segment_count", "pure_segment_runs", "pure_segment_prediction_runs",
		"pure_segment_identity_count", "pure_segment_identity_capacity"]:
		result[key] = 0
	for region: LogisticsTransportRegion in _regions:
		_accumulate(result, region.segments.live_stats())
	var cache_rows: int = _unconnected_predictions.size()
	var cache_slots: int = 0
	for region: LogisticsTransportRegion in _regions:
		cache_rows += region.prediction_cache_rows()
		cache_slots += region.prediction_ore_slots
	result["sample_region_cache_rows"] = cache_rows
	result["sample_region_cache_ore_slots"] = cache_slots
	result["sample_region_queue_creations"] = _prediction_queue_creations
	result["sample_region_ore_creations"] = _prediction_ore_creations
	result["transport_rebuilt_machines"] = rebuilt_machines
	result["transport_common_ticks"] = common_ticks
	result["transport_region_visits"] = _region_visits
	result["production_deadline_checks"] = _production.deadline_checks
	result["production_due_visits"] = _production.due_visits
	result["production_heap_comparisons"] = _production.heap_comparisons
	result["production_work"] = _production.work
	result["production_schedule_count"] = _production.size()
	return result


static func _accumulate(target: Dictionary[String, int], source: Dictionary[String, int]) -> void:
	for key: String in source:
		target[key] = target.get(key, 0) + source[key]


static func _region_stats(region: LogisticsTransportRegion) -> Dictionary[String, int]:
	return {
		"pure_segment_internal_transfers": region.segments.internal_transfers,
		"pure_segment_materialized_cells": region.segments.materialized_cells,
		"pure_segment_materialize_work": region.segments.materialize_work,
		"pure_segment_fallback_ticks": region.segments.fallback_ticks,
		"pure_segment_run_visits": region.segments.run_visits,
		"transport_line_count": region.lines.line_count,
		"transport_legacy_belts": region.lines.legacy_belts,
		"transport_slope_belts": region.lines.slope_belts,
		"transport_common_ticks": region.lines.common_ticks,
		"transport_exit_events": region.lines.exit_events,
		"transport_boundary_events": region.lines.boundary_events,
		"transport_machine_visits": region.lines.machine_visits,
		"transport_ore_visits": region.lines.ore_visits,
		"transport_materialized_ores": region.lines.materialized_ores,
		"transport_fallback_work": region.lines.fallback_work,
		"transport_blocked_ticks": region.lines.blocked_ticks,
		"transport_inventory_checks": region.lines.inventory_checks,
		"transport_ring_count": 1 if region.ring.active else 0,
		"transport_ring_ticks": region.ring.ticks,
		"transport_ring_exits": region.ring.exits,
		"transport_ring_machine_visits": region.ring.machine_visits,
		"transport_ring_ore_visits": region.ring.ore_visits,
		"transport_ring_materialized_ores": region.ring.materialized_ores,
	}
