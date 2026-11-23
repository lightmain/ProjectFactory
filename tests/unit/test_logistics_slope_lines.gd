extends GdUnitTestSuite

const Reference = preload("res://tests/support/logistics_t03_reference.gd")
const Replay = preload("res://tests/support/logistics_replay.gd")
const STEP: float = LogisticsData.LOGIC_STEP
const DIRECTIONS: Array[Vector3i] = [Vector3i.BACK, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.RIGHT]


func _place(logistics: LogisticsData, cell: Vector3i, block: int, direction: Vector3i) -> void:
	assert_bool(logistics._world.place_block(cell, block)).is_true()
	assert_bool(logistics.set_direction(cell, direction)).is_true()


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


func _enable(logistics: LogisticsData, slopes: int) -> void:
	assert_bool(logistics.enable_transport_lines()).is_true()
	assert_int(logistics.work_stats().get("transport_slope_belts", -1)).is_equal(slopes)
	assert_int(logistics.work_stats()["transport_legacy_belts"]).is_equal(0)


func test_continuous_slopes_are_aggregated_instead_of_forcing_every_tick_fallback() -> void:
	for count: int in [1000, 10000]:
		var world: VoxelWorldData = VoxelWorldData.new()
		assert_bool(world.generate_flat(Vector3i(-2, -4, -2), Vector3i(104, 8, 100))).is_true()
		var logistics: LogisticsData = LogisticsData.new()
		logistics.bind_world(world, INF, 1)
		for lane: int in range(count / 100):
			for x: int in range(100):
				_place(logistics, Vector3i(x, (lane / 32) * 2, (lane % 32) * 3),
					VoxelWorldData.Block.BELT_UP_EAST if x % 2 == 0 else VoxelWorldData.Block.BELT_DOWN_EAST,
					Vector3i.RIGHT)
		logistics.advance(STEP)
		var state: Dictionary = logistics.save_state()
		var rows: Array = state["machines"]
		assert_int(rows.size()).is_equal(count)
		if rows.size() != count:
			return
		for index: int in range(count):
			rows[index]["ores"] = [{"id": index + 1, "incoming": Vector3i.RIGHT, "progress": 0.1}]
			rows[index]["quantity"] = 1
			rows[index]["eligible"] = 0
		state["next_id"] = count + 1
		assert_bool(logistics.restore_state(state)).is_true()
		_enable(logistics, count)
		assert_int(logistics.work_stats()["transport_line_count"]).is_equal(count / 100)
		var before: Dictionary[String, int] = logistics.work_stats()
		logistics.advance(STEP * 8)
		var after: Dictionary[String, int] = logistics.work_stats()
		assert_int(after["transport_common_ticks"] - before["transport_common_ticks"]).is_equal(8)
		assert_int(after["transport_ore_visits"] - before["transport_ore_visits"]).is_equal(0)
		assert_int(after["transport_machine_visits"] - before["transport_machine_visits"]).is_equal(0)
		assert_int(after["transport_fallback_work"] - before["transport_fallback_work"]).is_equal(0)
		assert_int(logistics.total_ore()).is_equal(count)
		var ores: Array[LogisticsOre] = logistics.belt_ores(Vector3i.ZERO)
		assert_int(ores.size()).is_equal(1)
		if ores.size() == 1:
			assert_float(ores[0].progress).is_equal_approx(0.1 + 8.0 / 30.0, 0.000001)


func test_four_directions_double_slopes_turns_side_inputs_and_prediction_match_reference() -> void:
	for rotation: int in range(4):
		var facing: Vector3i = DIRECTIONS[rotation]
		var side: Vector3i = Vector3i(-facing.z, 0, facing.x)
		var world: VoxelWorldData = VoxelWorldData.new()
		var logistics: LogisticsData = LogisticsData.new()
		logistics.bind_world(world, 0.17, 2)
		var cells: Array[Vector3i] = [
			-facing, Vector3i.ZERO, facing, facing * 2 + Vector3i.UP,
			facing * 3 + Vector3i.UP, facing * 4, facing * 5, facing * 5 + side,
		]
		var blocks: Array[int] = [
			VoxelWorldData.Block.MINER, VoxelWorldData.Block.BELT, 9 + rotation, 9 + rotation,
			13 + rotation, 13 + rotation, VoxelWorldData.Block.BELT, VoxelWorldData.Block.CHEST,
		]
		for index: int in range(cells.size()):
			_place(logistics, cells[index], blocks[index], facing if index < 6 else side)
		# Side input at the flat arrival, plus a wrong side feeder
		# aimed at a slope; only the former is a legal inventory boundary.
		_place(logistics, facing * 5 - side, VoxelWorldData.Block.MINER, side)
		_place(logistics, facing - side, VoxelWorldData.Block.MINER, side)
		assert_bool(logistics.prefill_belts()).is_true()
		logistics.advance(STEP)
		var reference: RefCounted = _reference(logistics)
		_enable(logistics, 4)
		for tick: int in range(360):
			logistics.advance(STEP)
			reference.call("advance", STEP)
			_compare(logistics, reference)
			if tick % 17 == 0:
				var before: Dictionary = logistics.save_state()
				var all_predicted: Array = reference.call("sample_state", STEP * 0.6)
				var predicted: Array[Dictionary] = []
				for row: Dictionary in all_predicted:
					if row["cell"] in [cells[2], cells[5]]:
						predicted.append(row)
				var actual: Array[Dictionary] = []
				for queue: LogisticsOreQueue in logistics.sample_cells([cells[2], cells[5]], STEP * 0.6):
					var ores: Array[Dictionary] = []
					for ore: LogisticsOre in queue.ores:
						ores.append({"id": ore.id, "incoming": ore.incoming_direction, "progress": ore.progress})
						assert_bool(ore.surface_position(queue.cell, queue.direction, queue.block).is_finite()).is_true()
					actual.append({"cell": queue.cell, "direction": queue.direction, "block": queue.block, "ores": ores})
				var difference: Dictionary = Replay.first_difference(predicted, actual)
				assert_bool(difference.is_empty()).override_failure_message(var_to_str(difference)).is_true()
				assert_bool(logistics.save_state() == before).is_true()
		assert_int(logistics.ore_count(cells[-1])).is_greater(0)
