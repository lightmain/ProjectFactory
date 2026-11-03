extends GdUnitTestSuite

var _world: VoxelWorldData
var _logistics: LogisticsData


func before_test() -> void:
	_world = VoxelWorldData.new()
	_world.generate_flat()
	_logistics = LogisticsData.new()
	_logistics.bind_world(_world)


func _place(cell: Vector3i, block: int, facing: Vector3i = Vector3i.RIGHT) -> void:
	assert_bool(_world.place_block(cell, block)).is_true()
	assert_bool(_logistics.set_direction(cell, facing)).is_true()


func _line(interval: float = 1.0, amount: int = 1) -> void:
	_logistics.bind_world(_world, interval, amount)
	_place(Vector3i.LEFT, VoxelWorldData.Block.MINER)
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT)


func _first(cell: Vector3i = Vector3i.ZERO, extra_time: float = 0.0) -> LogisticsOre:
	var ores: Array[LogisticsOre] = _logistics.belt_ores(cell, extra_time)
	assert_int(ores.size()).is_greater(0)
	return ores[0] if not ores.is_empty() else LogisticsOre.new(-1, Vector3i.RIGHT)


func test_rear_input_moves_at_one_meter_per_second_and_waits_at_exit() -> void:
	_line()
	_logistics.advance(1.0)
	var entered: LogisticsOre = _first()
	assert_float(entered.progress).is_equal_approx(0.0, 0.000001)
	assert_vector(entered.surface_position(Vector3i.ZERO, Vector3i.RIGHT)).is_equal_approx(
		Vector3(0, 0.08, 0.25), Vector3.ONE * 0.000001
	)
	_logistics.advance(0.125)
	var moved: LogisticsOre = _first()
	assert_int(moved.id).is_equal(entered.id)
	assert_float(moved.progress).is_equal_approx(0.25, 0.000001)
	assert_float(moved.surface_position(Vector3i.ZERO, Vector3i.RIGHT).x).is_equal_approx(
		0.125, 0.000001
	)
	_logistics.advance(0.5)
	assert_float(_first().progress).is_equal_approx(1.0, 0.000001)


func test_crossing_into_side_input_preserves_identity_and_space_in_all_directions() -> void:
	for facing: Vector3i in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]:
		for sign_value: int in [-1, 1]:
			_world.generate_flat()
			var incoming: Vector3i = Vector3i(-facing.z, 0, facing.x) * sign_value
			var upstream: Vector3i = -incoming
			_place(upstream * 2, VoxelWorldData.Block.MINER, incoming)
			_place(upstream, VoxelWorldData.Block.BELT, incoming)
			_place(Vector3i.ZERO, VoxelWorldData.Block.BELT, facing)
			_logistics.advance(1.499999)
			var before: LogisticsOre = _first(upstream)
			var position: Vector3 = before.surface_position(upstream, incoming)
			_logistics.advance(0.000001)
			var after: LogisticsOre = _first()
			assert_int(after.id).is_equal(before.id)
			assert_vector(after.surface_position(Vector3i.ZERO, facing)).is_equal_approx(
				position, Vector3.ONE * 0.00001
			)
			var center: Vector3 = VoxelWorldData.cell_center(Vector3i.ZERO)
			center.y = 0.08
			_logistics.advance(0.125)
			assert_vector(_first().surface_position(Vector3i.ZERO, facing)).is_equal_approx(
				center - Vector3(incoming) * 0.125, Vector3.ONE * 0.00001
			)
			_logistics.advance(0.125)
			assert_vector(_first().surface_position(Vector3i.ZERO, facing)).is_equal_approx(
				center, Vector3.ONE * 0.00001
			)
			_logistics.advance(0.125)
			assert_vector(_first().surface_position(Vector3i.ZERO, facing)).is_equal_approx(
				center + Vector3(facing) * 0.125, Vector3.ONE * 0.00001
			)


func test_blocked_queue_preserves_spacing_and_batch_does_not_overlap_at_entry() -> void:
	_line(0.1, 8)
	_logistics.advance(0.1)
	assert_int(_logistics.ore_count(Vector3i.ZERO)).is_equal(1)
	_logistics.advance(0.1)
	assert_int(_logistics.ore_count(Vector3i.ZERO)).is_equal(1)
	_logistics.advance(0.8)
	var ores: Array[LogisticsOre] = _logistics.belt_ores(Vector3i.ZERO)
	assert_int(ores.size()).is_equal(2)
	if ores.size() != 2:
		return
	assert_float(ores[0].progress).is_equal_approx(1.0, 0.000001)
	assert_float(ores[1].progress).is_equal_approx(0.5, 0.000001)
	assert_int(ores[0].id).is_not_equal(ores[1].id)
	var front_id: int = ores[0].id
	_logistics.advance(5.0)
	assert_int(_first().id).is_equal(front_id)
	assert_int(_logistics.total_ore()).is_equal(60 * 8)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.CHEST)
	_logistics.advance(0.125)
	assert_int(_logistics.ore_count(Vector3i.RIGHT)).is_equal(1)
	assert_int(_first().id).is_equal(ores[1].id)
	assert_float(_first().progress).is_equal_approx(0.75, 0.000001)


func test_snapshots_and_prediction_never_mutate_authoritative_state() -> void:
	_line()
	_logistics.advance(1.125)
	var ore: LogisticsOre = _first()
	var original_id: int = ore.id
	ore.progress = 1.0
	ore.id = -10
	ore.incoming_direction = Vector3i.LEFT
	var predicted: LogisticsOre = _first(Vector3i.ZERO, 0.05)
	# Both requests stop at the next fixed batch boundary (1.1333...).
	assert_float(predicted.progress).is_equal_approx(16.0 / 60.0, 0.000001)
	var current: LogisticsOre = _first()
	assert_int(current.id).is_equal(original_id)
	assert_float(current.progress).is_equal_approx(0.25, 0.000001)
	assert_vector(current.incoming_direction).is_equal(Vector3i.RIGHT)
	assert_int(_logistics.ore_count(Vector3i.ZERO)).is_equal(1)
	assert_float(_first(Vector3i.ZERO, -1.0).progress).is_equal(current.progress)
	assert_float(_first(Vector3i.ZERO, NAN).progress).is_equal(current.progress)
	assert_float(_first(Vector3i.ZERO, 100.0).progress).is_equal_approx(16.0 / 60.0, 0.000001)


func test_prediction_stops_at_next_transfer_and_preserves_blocked_spacing() -> void:
	_line(0.1, 4)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.CHEST)
	_logistics.advance(0.4)
	# Prediction stops at the next fixed batch (0.41666...), with no transfers.
	assert_float(_first(Vector3i.ZERO, 10.0).progress).is_equal_approx(38.0 / 60.0, 0.000001)
	assert_int(_logistics.ore_count(Vector3i.RIGHT)).is_equal(0)
	_world.break_block(Vector3i.RIGHT)
	_logistics.advance(1.6)
	var ores: Array[LogisticsOre] = _logistics.belt_ores(Vector3i.ZERO, 1.0)
	assert_int(ores.size()).is_equal(2)
	if ores.size() == 2:
		assert_float(ores[0].progress - ores[1].progress).is_greater_equal(0.5)


func test_motion_matches_time_slices_and_placement_order() -> void:
	_line(0.3, 3)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.BELT)
	_place(Vector3i.RIGHT * 2, VoxelWorldData.Block.CHEST)
	_logistics.advance(10.125)
	var other_world: VoxelWorldData = VoxelWorldData.new()
	var other: LogisticsData = LogisticsData.new()
	other.bind_world(other_world, 0.3, 3)
	for cell: Vector3i in [Vector3i.RIGHT * 2, Vector3i.RIGHT, Vector3i.ZERO, Vector3i.LEFT]:
		other_world.place_block(cell, _world.get_block(cell))
		other.set_direction(cell, Vector3i.RIGHT)
	for tick: int in range(810):
		other.advance(0.0125)
	for cell: Vector3i in _logistics.machine_cells():
		assert_int(other.ore_count(cell)).is_equal(_logistics.ore_count(cell))
		var expected: Array[LogisticsOre] = _logistics.belt_ores(cell)
		var actual: Array[LogisticsOre] = other.belt_ores(cell)
		assert_int(actual.size()).is_equal(expected.size())
		for index: int in range(mini(actual.size(), expected.size())):
			assert_int(actual[index].id).is_equal(expected[index].id)
			assert_float(actual[index].progress).is_equal_approx(expected[index].progress, 0.000001)


func test_break_and_reset_remove_motion_and_replacement_gets_fresh_identity() -> void:
	_line()
	_logistics.advance(1.1)
	var old_id: int = _first().id
	_world.break_block(Vector3i.ZERO)
	assert_int(_logistics.belt_ores(Vector3i.ZERO).size()).is_equal(0)
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	_logistics.advance(0.9)
	assert_int(_first().id).is_not_equal(old_id)
	_world.generate_flat()
	assert_int(_logistics.belt_ores(Vector3i.ZERO).size()).is_equal(0)
	assert_int(_logistics.total_ore()).is_equal(0)


func test_out_of_phase_miner_cannot_starve_a_waiting_belt_input() -> void:
	_logistics.bind_world(_world, 0.5, 1)
	_place(Vector3i.LEFT * 2, VoxelWorldData.Block.MINER)
	_place(Vector3i.LEFT, VoxelWorldData.Block.BELT)
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.CHEST)
	_logistics.advance(0.1)
	_place(Vector3i.FORWARD, VoxelWorldData.Block.MINER, Vector3i.BACK)
	_logistics.advance(9.9)
	var rear_before: int = _logistics.ore_count(Vector3i.LEFT * 2)
	var side_before: int = _logistics.ore_count(Vector3i.FORWARD)
	_logistics.advance(10.0)
	# Both miners produce 20 new ores; each input must ship a fair share.
	assert_int(_logistics.ore_count(Vector3i.LEFT * 2) - rear_before).is_less(15)
	assert_int(_logistics.ore_count(Vector3i.FORWARD) - side_before).is_less(15)
	assert_int(_logistics.total_ore()).is_equal(79)


func test_side_merge_and_blockage_recovery_match_partitioned_time() -> void:
	var other_world: VoxelWorldData = VoxelWorldData.new()
	other_world.generate_flat()
	var other: LogisticsData = LogisticsData.new()
	other.bind_world(other_world, 0.3, 2)
	_logistics.bind_world(_world, 0.3, 2)
	var cells: Array[Vector3i] = [
		Vector3i(-2, 0, 0), Vector3i.LEFT, Vector3i(0, 0, -2),
		Vector3i.FORWARD, Vector3i.ZERO, Vector3i.RIGHT,
	]
	var blocks: Array[int] = [
		VoxelWorldData.Block.MINER, VoxelWorldData.Block.BELT,
		VoxelWorldData.Block.MINER, VoxelWorldData.Block.BELT,
		VoxelWorldData.Block.BELT, VoxelWorldData.Block.CHEST,
	]
	for index: int in range(cells.size()):
		var facing: Vector3i = Vector3i.BACK if index in [2, 3] else Vector3i.RIGHT
		_place(cells[index], blocks[index], facing)
		other_world.place_block(cells[index], blocks[index])
		other.set_direction(cells[index], facing)
	for stage: int in range(3):
		var ticks: int = 250 if stage == 0 else 280
		_logistics.advance(float(ticks) * 0.0125)
		for tick: int in range(ticks):
			other.advance(0.0125)
		for cell: Vector3i in cells:
			assert_int(other.ore_count(cell)).is_equal(_logistics.ore_count(cell))
			var expected: Array[LogisticsOre] = _logistics.belt_ores(cell)
			var actual: Array[LogisticsOre] = other.belt_ores(cell)
			assert_int(actual.size()).is_equal(expected.size())
			for index: int in range(mini(actual.size(), expected.size())):
				assert_vector(actual[index].incoming_direction).is_equal(expected[index].incoming_direction)
				assert_float(actual[index].progress).is_equal_approx(expected[index].progress, 0.000001)
				assert_vector(actual[index].surface_position(cell, _logistics.direction_at(cell))).is_equal_approx(
					expected[index].surface_position(cell, _logistics.direction_at(cell)),
					Vector3.ONE * 0.000001
				)
		if stage == 0:
			_world.break_block(Vector3i.RIGHT)
			other_world.break_block(Vector3i.RIGHT)
		elif stage == 1:
			_place(Vector3i.RIGHT, VoxelWorldData.Block.CHEST)
			other_world.place_block(Vector3i.RIGHT, VoxelWorldData.Block.CHEST)
			other.set_direction(Vector3i.RIGHT, Vector3i.RIGHT)


func _positions(extra_time: float = 0.0) -> Dictionary[int, Vector3]:
	var positions: Dictionary[int, Vector3] = {}
	for cell: Vector3i in _logistics.machine_cells():
		for ore: LogisticsOre in _logistics.belt_ores(cell, extra_time):
			positions[ore.id] = ore.surface_position(cell, _logistics.direction_at(cell))
	return positions


func test_reconnecting_a_packed_line_moves_every_waiting_ore_together() -> void:
	_line(0.1, 8)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.BELT)
	_place(Vector3i.RIGHT * 2, VoxelWorldData.Block.BELT)
	# The missing middle section leaves three upstream cells packed.
	_logistics.advance(5.0)
	var before: Dictionary[int, Vector3] = _positions()
	assert_int(before.size()).is_equal(6)
	_place(Vector3i.RIGHT * 3, VoxelWorldData.Block.BELT)
	_place(Vector3i.RIGHT * 4, VoxelWorldData.Block.CHEST)
	_logistics.advance(0.125)
	var after: Dictionary[int, Vector3] = _positions()
	for id: int in before:
		assert_bool(after.has(id)).is_true()
		if after.has(id):
			assert_float(after[id].x - before[id].x).is_equal_approx(0.125, 0.000001)
	# Keep the same packed gap through several ownership changes.
	for tick: int in range(16):
		var positions: Dictionary[int, Vector3] = _positions()
		var ordered: Array[float] = []
		for position: Vector3 in positions.values():
			ordered.append(position.x)
		ordered.sort()
		for index: int in range(1, ordered.size()):
			assert_float(ordered[index] - ordered[index - 1]).is_equal_approx(0.25, 0.000001)
		_logistics.advance(0.0625)


func test_cross_cell_spacing_and_render_prediction_follow_the_downstream_tail() -> void:
	_line(0.1, 8)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.BELT)
	_logistics.advance(5.0)
	for extra_time: float in [0.0, 0.01, 100.0]:
		var positions: Dictionary[int, Vector3] = _positions(extra_time)
		var ordered: Array[float] = []
		for position: Vector3 in positions.values():
			ordered.append(position.x)
		ordered.sort()
		for index: int in range(1, ordered.size()):
			assert_float(ordered[index] - ordered[index - 1]).is_greater_equal(0.25 - 0.000001)
	var before: Dictionary[int, Vector3] = _positions()
	_logistics.advance(0.123)
	var after: Dictionary[int, Vector3] = _positions()
	for id: int in before:
		assert_vector(after[id]).is_equal(before[id])


func test_full_belt_ring_keeps_circulating_with_a_waiting_feeder() -> void:
	_line(0.1, 8)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.BELT, Vector3i.BACK)
	_place(Vector3i(1, 0, 1), VoxelWorldData.Block.BELT, Vector3i.LEFT)
	_place(Vector3i.BACK, VoxelWorldData.Block.BELT, Vector3i.FORWARD)
	_logistics.advance(5.0)
	var before: Dictionary[int, Vector3] = _positions()
	assert_int(before.size()).is_equal(8)
	_logistics.advance(0.125)
	var after: Dictionary[int, Vector3] = _positions()
	assert_int(after.size()).is_equal(before.size())
	for id: int in before:
		assert_bool(after.has(id)).is_true()
		if after.has(id):
			assert_float(after[id].distance_to(before[id])).is_greater(0.08)
	_world.break_block(Vector3i.LEFT)
	_logistics.advance(100.0)
	assert_int(_logistics.total_ore()).is_equal(8)


func test_waiting_merge_inputs_never_jump_back_when_another_port_is_admitted() -> void:
	_logistics.bind_world(_world, 0.1, 8)
	_place(Vector3i.LEFT * 2, VoxelWorldData.Block.MINER)
	_place(Vector3i.LEFT, VoxelWorldData.Block.BELT)
	_place(Vector3i.FORWARD * 2, VoxelWorldData.Block.MINER, Vector3i.BACK)
	_place(Vector3i.FORWARD, VoxelWorldData.Block.BELT, Vector3i.BACK)
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.CHEST)
	var previous: Dictionary[int, Vector3] = _positions()
	for tick: int in range(300):
		_logistics.advance(0.01)
		var current: Dictionary[int, Vector3] = _positions()
		for id: int in previous:
			if current.has(id):
				assert_float(current[id].distance_to(previous[id])).is_less_equal(0.010001)
		previous = current
