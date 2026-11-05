extends GdUnitTestSuite


func test_saved_logistics_continues_with_same_ore_ids_phase_and_quantity() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	var rules: LogisticsData = LogisticsData.new()
	rules.bind_world(world, 0.17, 2)
	for z: int in range(4):
		world.place_block(Vector3i(0, 0, z), VoxelWorldData.Block.MINER if z == 0 else (
			VoxelWorldData.Block.CHEST if z == 3 else VoxelWorldData.Block.BELT
		))
		rules.set_direction(Vector3i(0, 0, z), Vector3i.BACK)
	rules.advance(0.413)
	# An edit between clock boundaries must remain pending after loading.
	rules.set_direction(Vector3i(0, 0, 1), Vector3i.RIGHT)
	var restored: LogisticsData = LogisticsData.new()
	restored.bind_world(world)
	assert_bool(restored.restore_state(rules.save_state())).is_true()
	assert_bool(restored.save_state() == rules.save_state()).is_true()
	for delta: float in [0.007, 0.1, 0.43, 1.31]:
		rules.advance(delta)
		restored.advance(delta)
		assert_bool(restored.save_state() == rules.save_state()).is_true()


func test_invalid_restore_preserves_running_rules() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	var rules: LogisticsData = LogisticsData.new()
	rules.bind_world(world)
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	rules.advance(0.27)
	var before: Dictionary = rules.save_state()
	var invalid: Dictionary = before.duplicate(true)
	invalid["time"] = -1.0
	assert_bool(rules.restore_state(invalid)).is_false()
	assert_bool(rules.save_state() == before).is_true()


func test_forged_miner_phase_is_rejected_before_live_state_changes() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	var rules: LogisticsData = LogisticsData.new()
	rules.bind_world(world)
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	var before: Dictionary = rules.save_state()
	var forged: Dictionary = before.duplicate(true)
	var rows: Array = forged["machines"]
	var miner: Dictionary = rows[0]
	miner["cycles"] = 100
	assert_bool(rules.restore_state(forged)).is_false()
	assert_bool(rules.save_state() == before).is_true()


func test_settled_state_cannot_omit_connections_or_pending_rotation() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	var rules: LogisticsData = LogisticsData.new()
	rules.bind_world(world)
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	world.place_block(Vector3i.FORWARD, VoxelWorldData.Block.CHEST)
	var forged: Dictionary = rules.save_state()
	forged["dirty"] = false
	assert_bool(rules.restore_state(forged)).is_false()
	rules.advance(0.2)
	rules.set_direction(Vector3i.ZERO, Vector3i.RIGHT)
	forged = rules.save_state()
	forged["dirty"] = false
	assert_bool(rules.restore_state(forged)).is_false()


func test_ore_spacing_accepted_by_restore_is_safe_to_advance() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	var rules: LogisticsData = LogisticsData.new()
	rules.bind_world(world)
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	var forged: Dictionary = rules.save_state()
	forged["next_id"] = 3
	var rows: Array = forged["machines"]
	var belt: Dictionary = rows[0]
	belt["quantity"] = 2
	belt["ores"] = [
		{"id": 1, "incoming": Vector3i.FORWARD, "progress": 1.0},
		{"id": 2, "incoming": Vector3i.FORWARD, "progress": 0.500000005},
	]
	assert_bool(rules.restore_state(forged)).is_false()


func test_large_valid_mining_amount_and_disabled_miners_round_trip() -> void:
	for amount: int in [1000001, 2000000000000, 0, -1000001]:
		var world: VoxelWorldData = VoxelWorldData.new()
		var rules: LogisticsData = LogisticsData.new()
		rules.bind_world(world, 0.17, amount)
		world.place_block(Vector3i.ZERO, VoxelWorldData.Block.MINER)
		rules.advance(1.413)
		var restored: LogisticsData = LogisticsData.new()
		restored.bind_world(world)
		assert_bool(restored.restore_state(rules.save_state())).is_true()
		rules.advance(0.307)
		restored.advance(0.307)
		assert_bool(restored.save_state() == rules.save_state()).is_true()


func test_sub_epsilon_spacing_errors_cannot_accumulate_around_full_cycle() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	var rules: LogisticsData = LogisticsData.new()
	rules.bind_world(world)
	var cells: Array[Vector3i] = [Vector3i.ZERO, Vector3i.RIGHT, Vector3i(1, 0, 1), Vector3i.BACK]
	var directions: Array[Vector3i] = [Vector3i.RIGHT, Vector3i.BACK, Vector3i.LEFT, Vector3i.FORWARD]
	for index: int in range(4):
		world.place_block(cells[index], VoxelWorldData.Block.BELT)
		rules.set_direction(cells[index], directions[index])
	rules.advance(0.1)
	var before: Dictionary = rules.save_state()
	var forged: Dictionary = before.duplicate(true)
	forged["next_id"] = 9
	var rows: Array = forged["machines"]
	for index: int in range(4):
		var row: Dictionary = rows[index]
		var head: float = 1.0 - float(index) * 0.9e-9
		row["quantity"] = 2
		row["eligible"] = 2
		row["ores"] = [
			{"id": index * 2 + 1, "incoming": directions[(index + 3) % 4], "progress": head},
			{"id": index * 2 + 2, "incoming": directions[(index + 3) % 4], "progress": head - 0.5 + 0.9e-9},
		]
	assert_bool(rules.restore_state(forged)).is_false()
	assert_bool(rules.save_state() == before).is_true()
	for value: Dictionary in rows:
		var ores: Array = value["ores"]
		var first: Dictionary = ores[0]
		var second: Dictionary = ores[1]
		first["progress"] = 1.0
		second["progress"] = 0.5
	assert_bool(rules.restore_state(forged)).is_true()
	assert_bool(rules.save_state() == forged).is_true()
	rules.sample_belts()
	rules.advance(0.1)
	assert_int(rules.total_ore()).is_equal(8)
