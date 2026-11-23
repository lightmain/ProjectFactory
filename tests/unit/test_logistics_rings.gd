extends GdUnitTestSuite

const Reference = preload("res://tests/support/logistics_t03_reference.gd")
const Replay = preload("res://tests/support/logistics_replay.gd")
const STEP: float = LogisticsData.LOGIC_STEP


func _ring(width: int = 4, height: int = 3, phase: float = 0.0, supply: bool = false) -> LogisticsData:
	var world: VoxelWorldData = VoxelWorldData.new()
	assert_bool(world.generate_flat(Vector3i(-2, -4, -2), Vector3i(width + 2, 4, height + 2))).is_true()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, 0.17, 2)
	var cells: Array[Vector3i] = [Vector3i.ZERO]
	for z: int in range(height):
		if z % 2 == 0:
			for x: int in range(1, width):
				cells.append(Vector3i(x, 0, z))
		else:
			for x: int in range(width - 1, 0, -1):
				cells.append(Vector3i(x, 0, z))
	if height % 2 != 0:
		# Odd height closes along the right edge by using an even width
		# perimeter instead; large work probes below always use even height.
		cells = [Vector3i.ZERO, Vector3i.RIGHT, Vector3i(2, 0, 0), Vector3i(3, 0, 0),
			Vector3i(3, 0, 1), Vector3i(3, 0, 2), Vector3i(2, 0, 2), Vector3i(1, 0, 2),
			Vector3i(0, 0, 2), Vector3i(0, 0, 1)]
	else:
		for z: int in range(height - 1, 0, -1):
			cells.append(Vector3i(0, 0, z))
	for index: int in range(cells.size()):
		assert_bool(world.place_block(cells[index], VoxelWorldData.Block.BELT)).is_true()
		assert_bool(logistics.set_direction(cells[index], cells[(index + 1) % cells.size()] - cells[index])).is_true()
	if supply:
		assert_bool(world.place_block(Vector3i.LEFT, VoxelWorldData.Block.MINER)).is_true()
		assert_bool(logistics.set_direction(Vector3i.LEFT, Vector3i.RIGHT)).is_true()
	logistics.advance(STEP)
	var state: Dictionary = logistics.save_state()
	var rows: Array = state["machines"]
	var next_id: int = state["next_id"]
	for index: int in range(cells.size()):
		rows[index]["ores"] = [
			{"id": next_id, "incoming": Vector3i.LEFT, "progress": phase + 0.5},
			{"id": next_id + 1, "incoming": Vector3i.BACK, "progress": phase},
		]
		next_id += 2
		rows[index]["quantity"] = 2
		rows[index]["eligible"] = index % 3
	state["next_id"] = next_id
	assert_bool(logistics.restore_state(state)).is_true()
	return logistics


func _reference(logistics: LogisticsData) -> RefCounted:
	var reference: RefCounted = Reference.new()
	reference.call("bind_world", logistics._world)
	assert_bool(reference.call("restore_state", logistics.save_state())).is_true()
	return reference


func _compare(logistics: LogisticsData, reference: RefCounted) -> void:
	var difference: Dictionary = Replay.first_difference(
		Replay.canonical_state(reference.call("save_state")),
		Replay.canonical_state(logistics.save_state())
	)
	assert_bool(difference.is_empty()).override_failure_message(var_to_str(difference)).is_true()


func _enable(logistics: LogisticsData, dense: bool = true) -> void:
	var before: Dictionary = logistics.save_state()
	assert_bool(logistics.enable_transport_lines()).is_true()
	assert_bool(logistics.save_state() == before).is_true()
	assert_int(logistics.work_stats().get("transport_ring_count", -1)).is_equal(1 if dense else 0)


func test_full_ring_identity_metadata_and_predictions_match_every_tick() -> void:
	for phase: float in [0.0, 0.13, 0.5]:
		var logistics: LogisticsData = _ring(4, 3, phase)
		var reference: RefCounted = _reference(logistics)
		_enable(logistics)
		for tick: int in range(120):
			logistics.advance(STEP * 0.3)
			reference.call("advance", STEP * 0.3)
			_compare(logistics, reference)
			logistics.advance(STEP * 0.7)
			reference.call("advance", STEP * 0.7)
			_compare(logistics, reference)
			var before: Dictionary = logistics.save_state()
			var expected: Array = reference.call("sample_state", STEP * 0.8)
			var actual: Array[Dictionary] = []
			for queue: LogisticsOreQueue in logistics.sample_belts(STEP * 0.8):
				var ores: Array[Dictionary] = []
				for ore: LogisticsOre in queue.ores:
					ores.append({"id": ore.id, "incoming": ore.incoming_direction, "progress": ore.progress})
				actual.append({"cell": queue.cell, "direction": queue.direction, "block": queue.block, "ores": ores})
			var difference: Dictionary = Replay.first_difference(expected, actual)
			assert_bool(difference.is_empty()).override_failure_message(var_to_str(difference)).is_true()
			assert_bool(logistics.save_state() == before).is_true()
			# Packed decoding is a separate observer; neither observer unfolds
			# the authoritative ring to make the next tick correct.
			var restored: LogisticsData = LogisticsData.new()
			restored.bind_world(logistics._world)
			assert_bool(restored.restore_state(logistics.save_packed_state())).is_true()
			_compare(restored, reference)
		assert_int(logistics.work_stats().get("transport_ring_exits", -1)).is_greater(4)


func test_full_ring_blocks_external_supply_but_preserves_production_phase() -> void:
	var logistics: LogisticsData = _ring(4, 3, 0.5, true)
	var reference: RefCounted = _reference(logistics)
	_enable(logistics)
	var next_id: int = logistics.save_state()["next_id"]
	for tick: int in range(180):
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)
	assert_int(logistics.save_state()["next_id"]).is_equal(next_id)
	assert_int(logistics.ore_count(Vector3i.LEFT)).is_greater(0)
	assert_int(logistics.work_stats().get("transport_fallback_work", -1)).is_equal(0)


func test_sparse_and_empty_rings_use_explicit_fallback_without_losing_ores() -> void:
	for occupied: bool in [false, true]:
		var logistics: LogisticsData = _ring()
		var state: Dictionary = logistics.save_state()
		var rows: Array = state["machines"]
		for index: int in range(rows.size()):
			var ores: Array = rows[index]["ores"]
			if occupied and index == 0:
				ores.resize(1)
			else:
				ores.clear()
			rows[index]["quantity"] = ores.size()
			rows[index]["eligible"] = ores.size()
		assert_bool(logistics.restore_state(state)).is_true()
		var reference: RefCounted = _reference(logistics)
		_enable(logistics, false)
		for tick: int in range(90):
			logistics.advance(STEP)
			reference.call("advance", STEP)
			_compare(logistics, reference)
		assert_int(logistics.total_ore()).is_equal(1 if occupied else 0)
		if occupied:
			assert_int(logistics.work_stats().get("transport_fallback_work", -1)).is_greater(0)


func test_failed_restore_keeps_ring_and_cut_materializes_current_identity() -> void:
	var logistics: LogisticsData = _ring()
	var reference: RefCounted = _reference(logistics)
	_enable(logistics)
	logistics.advance(STEP * 48)
	reference.call("advance", STEP * 48)
	_compare(logistics, reference)
	var before: Dictionary = logistics.save_state()
	var invalid: Dictionary = before.duplicate(true)
	invalid["next_id"] = 1
	assert_bool(logistics.restore_state(invalid)).is_false()
	assert_bool(logistics.save_state() == before).is_true()
	assert_int(logistics.work_stats().get("transport_ring_count", -1)).is_equal(1)
	assert_bool(logistics._world.break_block(Vector3i(3, 0, 1))).is_true()
	assert_int(logistics.work_stats().get("transport_ring_count", -1)).is_equal(0)
	_compare(logistics, reference)
	for tick: int in range(30):
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)


func test_large_full_rings_do_not_scan_ores_or_facilities_even_at_exits() -> void:
	for dimensions: Vector2i in [Vector2i(50, 20), Vector2i(100, 100)]:
		var logistics: LogisticsData = _ring(dimensions.x, dimensions.y, 0.5)
		var count: int = dimensions.x * dimensions.y
		assert_int(logistics.machine_cells().size()).is_equal(count)
		_enable(logistics)
		var before: Dictionary[String, int] = logistics.work_stats()
		logistics.advance(STEP * 61)
		var after: Dictionary[String, int] = logistics.work_stats()
		assert_int(after.get("transport_ring_ticks", -1) - before.get("transport_ring_ticks", -1)).is_equal(61)
		assert_int(after.get("transport_ring_exits", -1) - before.get("transport_ring_exits", -1)).is_equal(5)
		assert_int(after.get("transport_ring_machine_visits", -1) - before.get("transport_ring_machine_visits", -1)).is_equal(0)
		assert_int(after.get("transport_ring_ore_visits", -1) - before.get("transport_ring_ore_visits", -1)).is_equal(0)
		assert_int(after["transport_fallback_work"] - before["transport_fallback_work"]).is_equal(0)
		assert_int(after["transfer_calls"]).is_equal(0)
		assert_int(logistics.total_ore()).is_equal(count * 2)
		assert_int(after.get("transport_ring_materialized_ores", -1)).is_equal(0)
		var ids: Dictionary[int, bool] = {}
		var rows: Array = logistics.save_state()["machines"]
		for row: Dictionary in rows:
			for ore: Dictionary in row["ores"]:
				assert_bool(ids.has(ore["id"])).is_false()
				ids[ore["id"]] = true
		assert_int(ids.size()).is_equal(count * 2)
		assert_int(rows[0]["ores"][0]["id"]).is_equal(count * 2 - 2)
		assert_int(rows[0]["ores"][1]["id"]).is_equal(count * 2 - 5)


func test_edit_after_first_exit_preserves_initial_tail_incoming_and_query_isolation() -> void:
	var logistics: LogisticsData = _ring(4, 3, 0.5)
	var reference: RefCounted = _reference(logistics)
	_enable(logistics)
	logistics.advance(STEP)
	reference.call("advance", STEP)
	var before: Dictionary = logistics.save_state()
	var queues: Array[LogisticsOreQueue] = logistics.sample_cells([Vector3i.ZERO])
	queues[0].ores[0].id = 777
	queues[0].ores[0].incoming_direction = Vector3i.RIGHT
	queues.clear()
	assert_bool(logistics.save_state() == before).is_true()
	assert_bool(logistics.set_direction(Vector3i.ZERO, Vector3i.BACK)).is_true()
	assert_bool(reference.call("set_direction", Vector3i.ZERO, Vector3i.BACK)).is_true()
	_compare(logistics, reference)
	for tick: int in range(20):
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)


func test_disconnected_ring_and_flat_region_are_aggregated_independently() -> void:
	var logistics: LogisticsData = _ring()
	assert_bool(logistics._world.place_block(Vector3i(1, 2, 1), VoxelWorldData.Block.BELT)).is_true()
	assert_bool(logistics.set_direction(Vector3i(1, 2, 1), Vector3i.RIGHT)).is_true()
	logistics.advance(STEP)
	var reference: RefCounted = _reference(logistics)
	_enable(logistics)
	assert_int(logistics.work_stats()["transport_legacy_belts"]).is_equal(0)
	assert_int(logistics.work_stats()["transport_line_count"]).is_equal(1)
	for tick: int in range(60):
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)
	assert_int(logistics.work_stats()["transport_fallback_work"]).is_equal(0)


func test_nonuniform_initial_full_ring_uses_fallback_until_constraints_settle() -> void:
	var logistics: LogisticsData = _ring()
	var state: Dictionary = logistics.save_state()
	var rows: Array = state["machines"]
	# These old incoming directions do not constrain the newly joined edge.
	# Valid edited states need not yet have a common ring phase.
	rows[0]["ores"][0]["progress"] = 0.6
	rows[0]["ores"][1]["progress"] = 0.1
	assert_bool(logistics.restore_state(state)).is_true()
	var reference: RefCounted = _reference(logistics)
	_enable(logistics, false)
	for tick: int in range(90):
		logistics.advance(STEP)
		reference.call("advance", STEP)
		_compare(logistics, reference)
	assert_int(logistics.total_ore()).is_equal(20)
	assert_int(logistics.work_stats()["transport_fallback_work"]).is_greater(0)
