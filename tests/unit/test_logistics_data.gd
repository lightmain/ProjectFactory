extends GdUnitTestSuite

var _world: VoxelWorldData
var _logistics: LogisticsData


func before_test() -> void:
	_world = VoxelWorldData.new()
	_world.generate_flat()
	_logistics = LogisticsData.new()
	_logistics.bind_world(_world)


func _place(cell: Vector3i, block: int, direction: Vector3i = Vector3i.RIGHT) -> void:
	assert_bool(_world.place_block(cell, block)).is_true()
	assert_bool(_logistics.set_direction(cell, direction)).is_true()


func test_default_miner_produces_without_nodes_or_ore_blocks() -> void:
	_place(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	_logistics.advance(0.99)
	assert_int(_logistics.ore_count(Vector3i.ZERO)).is_equal(0)
	_logistics.advance(0.01)
	assert_int(_logistics.ore_count(Vector3i.ZERO)).is_equal(1)
	_logistics.advance(59.0)
	assert_int(_logistics.ore_count(Vector3i.ZERO)).is_equal(60)


func test_custom_miner_delivers_whole_batches_to_chest() -> void:
	_logistics.bind_world(_world, 0.3, 4)
	_place(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.CHEST)
	_logistics.advance(0.9)
	assert_int(_logistics.ore_count(Vector3i.RIGHT)).is_equal(12)
	assert_int(_logistics.total_ore()).is_equal(12)


func test_belt_pipeline_delivers_two_per_second_after_startup() -> void:
	_logistics.bind_world(_world, 0.5, 8)
	_place(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.BELT)
	_place(Vector3i.RIGHT * 2, VoxelWorldData.Block.BELT)
	_place(Vector3i.RIGHT * 3, VoxelWorldData.Block.CHEST)
	_logistics.advance(3.0)
	var before: int = _logistics.ore_count(Vector3i.RIGHT * 3)
	_logistics.advance(10.0)
	assert_int(_logistics.ore_count(Vector3i.RIGHT * 3) - before).is_equal(20)
	assert_int(_logistics.total_ore()).is_equal(26 * 8)


func test_blocked_belt_retains_ore_and_resumes_when_connected() -> void:
	_place(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.BELT)
	_logistics.advance(10.0)
	assert_int(_logistics.ore_count(Vector3i.RIGHT)).is_equal(2)
	assert_int(_logistics.total_ore()).is_equal(10)
	_place(Vector3i.RIGHT * 2, VoxelWorldData.Block.CHEST)
	_logistics.advance(2.0)
	assert_int(_logistics.ore_count(Vector3i.RIGHT * 2)).is_equal(4)
	assert_int(_logistics.total_ore()).is_equal(12)


func test_ports_reject_side_vertical_reversed_and_miner_inputs() -> void:
	_place(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.CHEST, Vector3i.BACK)
	_place(Vector3i.BACK, VoxelWorldData.Block.CHEST)
	_place(Vector3i.UP, VoxelWorldData.Block.CHEST)
	_logistics.advance(2.0)
	assert_int(_logistics.ore_count(Vector3i.ZERO)).is_equal(2)
	assert_int(_logistics.ore_count(Vector3i.RIGHT)).is_equal(0)
	assert_int(_logistics.ore_count(Vector3i.BACK)).is_equal(0)
	assert_int(_logistics.ore_count(Vector3i.UP)).is_equal(0)
	_world.break_block(Vector3i.RIGHT)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.MINER)
	_logistics.advance(1.0)
	assert_int(_logistics.ore_count(Vector3i.ZERO)).is_equal(3)
	assert_int(_logistics.ore_count(Vector3i.RIGHT)).is_equal(1)


func test_chest_has_working_output_to_a_belt() -> void:
	_place(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.CHEST)
	_logistics.advance(4.0)
	assert_int(_logistics.ore_count(Vector3i.RIGHT)).is_equal(4)
	_place(Vector3i.RIGHT * 2, VoxelWorldData.Block.BELT)
	_place(Vector3i.RIGHT * 3, VoxelWorldData.Block.CHEST)
	_logistics.advance(3.0)
	assert_int(_logistics.ore_count(Vector3i.RIGHT * 3)).is_greater(0)
	assert_int(_logistics.total_ore()).is_equal(7)


func test_belt_accepts_both_side_inputs_in_all_four_directions() -> void:
	for facing: Vector3i in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]:
		for side: int in [-1, 1]:
			_world.generate_flat()
			var incoming: Vector3i = Vector3i(-facing.z, 0, facing.x) * side
			_place(-incoming, VoxelWorldData.Block.MINER, incoming)
			_place(Vector3i.ZERO, VoxelWorldData.Block.BELT, facing)
			_place(facing, VoxelWorldData.Block.CHEST, facing)
			_logistics.advance(1.0)
			assert_int(_logistics.ore_count(Vector3i.ZERO)).is_equal(1)
			_logistics.advance(0.5)
			assert_int(_logistics.ore_count(facing)).is_equal(1)
			assert_int(_logistics.total_ore()).is_equal(1)


func test_belt_output_face_cannot_be_used_as_an_input() -> void:
	_place(Vector3i.RIGHT, VoxelWorldData.Block.MINER, Vector3i.LEFT)
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	_logistics.advance(3.0)
	assert_int(_logistics.ore_count(Vector3i.ZERO)).is_equal(0)
	assert_int(_logistics.ore_count(Vector3i.RIGHT)).is_equal(3)


func test_three_inputs_merge_fairly_without_exceeding_capacity_or_throughput() -> void:
	_logistics.bind_world(_world, 0.5, 4)
	var source_cells: Array[Vector3i] = [Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]
	var source_directions: Array[Vector3i] = [Vector3i.RIGHT, Vector3i.BACK, Vector3i.FORWARD]
	for index: int in range(source_cells.size()):
		_place(source_cells[index], VoxelWorldData.Block.MINER, source_directions[index])
	_place(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.CHEST)
	for tick: int in range(20):
		_logistics.advance(0.5)
		assert_int(_logistics.ore_count(Vector3i.ZERO)).is_between(0, 2)
	assert_int(_logistics.ore_count(Vector3i.RIGHT)).is_equal(19)
	assert_int(_logistics.total_ore()).is_equal(20 * 4 * 3)
	for cell: Vector3i in source_cells:
		assert_int(_logistics.ore_count(cell)).is_less(20 * 4)
	for first: Vector3i in source_cells:
		for second: Vector3i in source_cells:
			assert_int(absi(_logistics.ore_count(first) - _logistics.ore_count(second))).is_less_equal(1)


func test_merging_belts_keep_one_output_each_and_are_independent_of_placement_order() -> void:
	var cells: Array[Vector3i] = [
		Vector3i(-2, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, -2),
		Vector3i(0, 0, -1), Vector3i.ZERO, Vector3i.RIGHT,
	]
	var blocks: Array[int] = [
		VoxelWorldData.Block.MINER, VoxelWorldData.Block.BELT, VoxelWorldData.Block.MINER,
		VoxelWorldData.Block.BELT, VoxelWorldData.Block.BELT, VoxelWorldData.Block.CHEST,
	]
	var directions: Array[Vector3i] = [
		Vector3i.RIGHT, Vector3i.RIGHT, Vector3i.BACK, Vector3i.BACK,
		Vector3i.RIGHT, Vector3i.RIGHT,
	]
	_logistics.bind_world(_world, 0.5, 2)
	for index: int in range(cells.size()):
		_place(cells[index], blocks[index], directions[index])
	_logistics.advance(10.0)
	var other_world: VoxelWorldData = VoxelWorldData.new()
	var other: LogisticsData = LogisticsData.new()
	other.bind_world(other_world, 0.5, 2)
	for index: int in range(cells.size() - 1, -1, -1):
		other_world.place_block(cells[index], blocks[index])
		other.set_direction(cells[index], directions[index])
	for tick: int in range(20):
		other.advance(0.5)
	for cell: Vector3i in cells:
		assert_int(other.ore_count(cell)).is_equal(_logistics.ore_count(cell))
	assert_int(_logistics.ore_count(Vector3i(0, 0, -2))).is_less(38)
	assert_int(_logistics.ore_count(Vector3i.LEFT)).is_between(0, 2)
	assert_int(_logistics.ore_count(Vector3i(0, 0, -1))).is_between(0, 2)
	assert_int(_logistics.total_ore()).is_equal(80)


func test_all_four_directions_connect_and_new_ore_cannot_skip_the_belt() -> void:
	for direction: Vector3i in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.BACK]:
		_world.generate_flat()
		_place(Vector3i.ZERO, VoxelWorldData.Block.MINER, direction)
		_place(direction, VoxelWorldData.Block.BELT, direction)
		_place(direction * 2, VoxelWorldData.Block.CHEST, direction)
		_logistics.advance(1.0)
		assert_int(_logistics.ore_count(direction)).is_equal(1)
		assert_int(_logistics.ore_count(direction * 2)).is_equal(0)
		_logistics.advance(0.5)
		assert_int(_logistics.ore_count(direction * 2)).is_equal(1)


func test_large_delta_matches_small_deltas_and_placement_order() -> void:
	_logistics.bind_world(_world, 0.3, 3)
	_place(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	_place(Vector3i.RIGHT, VoxelWorldData.Block.BELT)
	_place(Vector3i.RIGHT * 2, VoxelWorldData.Block.CHEST)
	_logistics.advance(60.0)
	var other_world: VoxelWorldData = VoxelWorldData.new()
	var other: LogisticsData = LogisticsData.new()
	other.bind_world(other_world, 0.3, 3)
	for cell: Vector3i in [Vector3i.RIGHT * 2, Vector3i.RIGHT, Vector3i.ZERO]:
		other_world.place_block(cell, _world.get_block(cell))
		other.set_direction(cell, Vector3i.RIGHT)
	for frame: int in range(3600):
		other.advance(1.0 / 60.0)
	for cell: Vector3i in _logistics.machine_cells():
		assert_int(other.ore_count(cell)).is_equal(_logistics.ore_count(cell))
	assert_int(other.total_ore()).is_equal(600)


func test_two_hours_of_production_match_integer_cycle_count_and_time_slices() -> void:
	_logistics.bind_world(_world, 0.3, 1)
	_place(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	_logistics.advance(7200.0)
	assert_int(_logistics.total_ore()).is_equal(24000)
	_world.generate_flat()
	_place(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	for cycle: int in range(24000):
		_logistics.advance(0.3)
	assert_int(_logistics.total_ore()).is_equal(24000)


func test_sub_millisecond_cycle_cannot_schedule_a_non_advancing_deadline() -> void:
	var tiny: LogisticsMachine = LogisticsMachine.new(VoxelWorldData.Block.MINER, 1.0, 1e-20, 1)
	assert_bool(is_inf(tiny.next_production)).is_true()
	# Do not advance a potentially stuck machine until the deadline guard passes.


func test_invalid_mining_configs_are_disabled_and_miners_keep_independent_clocks() -> void:
	for interval: float in [-1.0, INF, NAN, 0.0001]:
		_world.generate_flat()
		_logistics.bind_world(_world, interval, 1)
		_place(Vector3i.ZERO, VoxelWorldData.Block.MINER)
		_logistics.advance(2.0)
		assert_int(_logistics.total_ore()).is_equal(0)
	for amount: int in [-1, 0]:
		_world.generate_flat()
		_logistics.bind_world(_world, 1.0, amount)
		_place(Vector3i.ZERO, VoxelWorldData.Block.MINER)
		_logistics.advance(2.0)
		assert_int(_logistics.total_ore()).is_equal(0)
	_world.generate_flat()
	_logistics.bind_world(_world)
	_place(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	_logistics.advance(0.75)
	_place(Vector3i.RIGHT * 2, VoxelWorldData.Block.MINER)
	_logistics.advance(0.25)
	assert_int(_logistics.ore_count(Vector3i.ZERO)).is_equal(1)
	assert_int(_logistics.ore_count(Vector3i.RIGHT * 2)).is_equal(0)
	_logistics.advance(0.75)
	assert_int(_logistics.ore_count(Vector3i.RIGHT * 2)).is_equal(1)


func test_break_replacement_and_world_reset_remove_old_state() -> void:
	_place(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	_logistics.advance(2.8)
	_world.break_block(Vector3i.ZERO)
	assert_int(_logistics.total_ore()).is_equal(0)
	_place(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	_logistics.advance(0.2)
	assert_int(_logistics.total_ore()).is_equal(0)
	_logistics.advance(0.8)
	assert_int(_logistics.total_ore()).is_equal(1)
	_world.generate_flat()
	assert_int(_logistics.machine_cells().size()).is_equal(0)


func test_invalid_time_config_and_direction_do_not_corrupt_state() -> void:
	_logistics.bind_world(_world, 0.0, 1)
	_place(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	_logistics.advance(10.0)
	assert_int(_logistics.total_ore()).is_equal(0)
	assert_bool(_logistics.set_direction(Vector3i.ZERO, Vector3i.UP)).is_false()
	assert_bool(_logistics.set_direction(Vector3i.ZERO, Vector3i(1, 0, 1))).is_false()
	assert_bool(_logistics.set_direction(Vector3i(10, 0, 0), Vector3i.RIGHT)).is_false()
	_logistics.advance(-1.0)
	_logistics.advance(INF)
	_logistics.advance(NAN)
	assert_int(_logistics.total_ore()).is_equal(0)
