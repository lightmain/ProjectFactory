extends GdUnitTestSuite

const DIRECTIONS: Array[Vector3i] = [Vector3i.BACK, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.RIGHT]


func test_eight_slopes_are_single_cell_without_structure_ids() -> void:
	for block: int in range(9, 17):
		var world: VoxelWorldData = VoxelWorldData.new()
		assert_bool(world.place_block(Vector3i.ZERO, block)).is_true()
		assert_int(world.block_count()).is_equal(1)
		assert_int(world.get_block(Vector3i.UP)).is_equal(VoxelWorldData.Block.AIR)
		assert_bool(world.structure_at(Vector3i.ZERO).is_empty()).is_true()
		assert_bool(world.structure_rows().is_empty()).is_true()
		var logistics: LogisticsData = LogisticsData.new()
		logistics.bind_world(world)
		assert_vector(logistics.direction_at(Vector3i.ZERO)).is_equal(DIRECTIONS[(block - 9) % 4])
		assert_bool(logistics.set_direction(Vector3i.ZERO, -DIRECTIONS[(block - 9) % 4])).is_false()
		assert_bool(world.break_block(Vector3i.ZERO)).is_true()
		assert_int(world.block_count()).is_equal(0)


func test_surface_rays_follow_45_degrees_in_all_directions() -> void:
	for block: int in range(9, 17):
		var world: VoxelWorldData = VoxelWorldData.new()
		assert_bool(world.place_block(Vector3i.ZERO, block)).is_true()
		var facing: Vector3 = Vector3(DIRECTIONS[(block - 9) % 4])
		for progress: float in [0.1, 0.5, 0.9]:
			var point: Vector3 = Vector3(0.25, 1.0, 0.25) + facing * ((progress - 0.5) * 0.5)
			var height: float = 0.08 + (progress if block < 13 else 1.0 - progress) * 0.5
			var hit: VoxelHit = VoxelRaycast.cast(world, point, Vector3.DOWN, 2.0)
			assert_object(hit).is_not_null()
			if hit != null:
				assert_vector(hit.cell).is_equal(Vector3i.ZERO)
				assert_float(hit.position.y).is_equal_approx(height, 0.00001)
				assert_vector(hit.normal).is_equal(Vector3i.UP)


func test_ray_crosses_slope_air_and_hits_protruding_lip() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	assert_bool(world.place_block(Vector3i.ZERO, 12)).is_true()
	assert_object(VoxelRaycast.cast(world, Vector3(0.4, 0.1, -0.2), Vector3.BACK, 1.0)).is_null()
	var hit: VoxelHit = VoxelRaycast.cast(world, Vector3(0.48, 0.55, -0.2), Vector3.BACK, 1.0)
	assert_object(hit).is_not_null()
	if hit != null:
		assert_vector(hit.cell).is_equal(Vector3i.ZERO)
		assert_float(hit.position.y).is_equal_approx(0.55, 0.00001)
	assert_bool(world.place_block(Vector3i(0, 0, 2), VoxelWorldData.Block.STONE)).is_true()
	hit = VoxelRaycast.cast(world, Vector3(0.4, 0.1, -0.2), Vector3.BACK, 2.0)
	assert_object(hit).is_not_null()
	if hit != null:
		assert_vector(hit.cell).is_equal(Vector3i(0, 0, 2))


func test_lip_overlap_is_rejected_in_both_placement_orders_and_at_world_top() -> void:
	for first_slope: bool in [true, false]:
		var world: VoxelWorldData = VoxelWorldData.new()
		assert_bool(world.place_block(Vector3i.ZERO if first_slope else Vector3i.UP,
			12 if first_slope else VoxelWorldData.Block.BELT)).is_true()
		assert_bool(world.place_block(Vector3i.UP if first_slope else Vector3i.ZERO,
			VoxelWorldData.Block.BELT if first_slope else 12)).is_false()
	var world: VoxelWorldData = VoxelWorldData.new()
	assert_bool(world.place_block(Vector3i(0, 59, 0), 12)).is_false()
	# Empty space under the plate remains physically empty.
	assert_bool(world.place_block(Vector3i.ZERO, 12,
		AABB(Vector3(0.3, 0.01, 0.1), Vector3(0.1, 0.05, 0.1)))).is_true()
	world.break_block(Vector3i.ZERO)
	assert_bool(world.place_block(Vector3i.ZERO, 12,
		AABB(Vector3(0.3, 0.32, 0.1), Vector3(0.1, 0.06, 0.1)))).is_false()


func test_flat_up_up_down_down_flat_pipeline_preserves_ore_and_save_progress() -> void:
	for facing: Vector3i in DIRECTIONS:
		var world: VoxelWorldData = VoxelWorldData.new()
		var logistics: LogisticsData = LogisticsData.new()
		logistics.bind_world(world, 0.5, 4)
		var cells: Array[Vector3i] = [
			Vector3i.ZERO, facing, facing * 2, facing * 3 + Vector3i.UP,
			facing * 4 + Vector3i.UP, facing * 5, facing * 6, facing * 7,
		]
		var rotation: int = DIRECTIONS.find(facing)
		var blocks: Array[int] = [5, 6, 9 + rotation, 9 + rotation, 13 + rotation, 13 + rotation, 6, 7]
		for index: int in range(cells.size()):
			assert_bool(world.place_block(cells[index], blocks[index])).is_true()
			assert_bool(logistics.set_direction(cells[index], facing)).is_true()
		logistics.advance(3.125)
		var restored_world: VoxelWorldData = VoxelWorldData.new()
		assert_bool(restored_world.restore_chunks(false, world.chunk_deltas())).is_true()
		var restored: LogisticsData = LogisticsData.new()
		restored.bind_world(restored_world)
		assert_bool(restored.restore_state(logistics.save_state())).is_true()
		for cell: Vector3i in cells:
			var ores: Array[LogisticsOre] = logistics.belt_ores(cell)
			var restored_ores: Array[LogisticsOre] = restored.belt_ores(cell)
			assert_int(restored_ores.size()).is_equal(ores.size())
			for index: int in range(ores.size()):
				assert_int(restored_ores[index].id).is_equal(ores[index].id)
				assert_float(restored_ores[index].progress).is_equal(ores[index].progress)
		logistics.advance(10.0)
		restored.advance(10.0)
		assert_int(logistics.ore_count(cells[-1])).is_greater(0)
		assert_int(restored.ore_count(cells[-1])).is_equal(logistics.ore_count(cells[-1]))
		assert_int(logistics.total_ore()).is_equal(26 * 4)


func test_slopes_reject_side_inputs_and_wrong_port_heights() -> void:
	for block: int in [12, 16]:
		for wrong: bool in [true, false]:
			var world: VoxelWorldData = VoxelWorldData.new()
			var logistics: LogisticsData = LogisticsData.new()
			logistics.bind_world(world)
			var slope: Vector3i = Vector3i.UP
			var source: Vector3i = slope + (Vector3i.LEFT if wrong else Vector3i.FORWARD)
			if block == 12 and wrong:
				source += Vector3i.UP
			assert_bool(world.place_block(source, 5)).is_true()
			assert_bool(logistics.set_direction(source, Vector3i.RIGHT if wrong else Vector3i.BACK)).is_true()
			assert_bool(world.place_block(slope, block)).is_true()
			logistics.advance(4.0)
			assert_int(logistics.ore_count(slope)).is_equal(0)
			assert_int(logistics.total_ore()).is_equal(4)


func test_flat_path_cannot_redirect_a_slope() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	assert_bool(world.place_block(Vector3i.ZERO, 12)).is_true()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world)
	var placement: BeltPlacement = BeltPlacement.new()
	placement.bind_world(world, logistics)
	assert_bool(placement.begin(VoxelHit.new(Vector3i.ZERO, Vector3i.UP, 1.0), Vector3i.LEFT)).is_false()
	assert_vector(logistics.direction_at(Vector3i.ZERO)).is_equal(Vector3i.RIGHT)


func test_invalid_slope_direction_side_ore_and_wrong_height_graph_restore_atomically() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world)
	world.place_block(Vector3i.ZERO, 5)
	logistics.set_direction(Vector3i.ZERO, Vector3i.RIGHT)
	world.place_block(Vector3i.RIGHT, 12)
	logistics.advance(1.25)
	var before: Dictionary = logistics.save_state()
	for field: String in ["direction", "settled"]:
		var forged: Dictionary = before.duplicate(true)
		var rows: Array = forged["machines"]
		var slope: Dictionary = rows[1]
		slope[field] = Vector3i.LEFT
		assert_bool(logistics.restore_state(forged)).is_false()
		assert_bool(logistics.save_state() == before).is_true()
	var forged: Dictionary = before.duplicate(true)
	var rows: Array = forged["machines"]
	var slope: Dictionary = rows[1]
	var ores: Array = slope["ores"]
	var ore: Dictionary = ores[0]
	ore["incoming"] = Vector3i.BACK
	assert_bool(logistics.restore_state(forged)).is_false()
	world.place_block(Vector3i.RIGHT * 2, 7)
	logistics.set_direction(Vector3i.RIGHT * 2, Vector3i.RIGHT)
	logistics.advance(0.1)
	before = logistics.save_state()
	forged = before.duplicate(true)
	var outgoing: Array = forged["outgoing"]
	var inputs: Array = forged["inputs"]
	outgoing[1] = 2
	inputs[6] = 1
	forged["dirty"] = true
	assert_bool(logistics.restore_state(forged)).is_false()
	assert_bool(logistics.save_state() == before).is_true()


func test_world_restore_rejects_conflicting_upper_block_without_changing_live_world() -> void:
	var forged_world: VoxelWorldData = VoxelWorldData.new()
	forged_world.place_block(Vector3i.ZERO, 12)
	var chunks: Dictionary[Vector3i, PackedByteArray] = forged_world.chunk_deltas()
	var chunk: Vector3i = VoxelWorldData.chunk_for(Vector3i.UP)
	var records: PackedByteArray = chunks[chunk]
	# Same X/Z, next Y record: local index increases by 1024.
	var upper_index: int = records.decode_u16(0) + 1024
	records.append(upper_index & 255)
	records.append(upper_index >> 8)
	records.append(VoxelWorldData.Block.STONE)
	chunks[chunk] = records
	var live: VoxelWorldData = VoxelWorldData.new()
	live.generate_flat()
	var count: int = live.block_count()
	assert_bool(live.restore_chunks(false, chunks)).is_false()
	assert_int(live.block_count()).is_equal(count)
	assert_int(live.get_block(Vector3i.ZERO)).is_equal(0)
	assert_bool(live.has_flat_baseline()).is_true()


func test_slope_sampling_is_straight_and_endpoints_match_flat_and_next_slope() -> void:
	for rotation: int in range(4):
		for up: bool in [true, false]:
			var block: int = (9 if up else 13) + rotation
			var direction: Vector3i = DIRECTIONS[rotation]
			var cell: Vector3i = Vector3i(7, 7, 7)
			var ore: LogisticsOre = LogisticsOre.new(1, direction)
			var start: Vector3
			for progress: float in [0.0, 0.25, 0.5, 0.75, 1.0]:
				ore.progress = progress
				var position: Vector3 = ore.surface_position(cell, direction, block)
				if progress == 0.0:
					start = position
				assert_vector(position - start).is_equal_approx(
					(Vector3(direction) + Vector3.UP * (1.0 if up else -1.0)) * progress * 0.5,
					Vector3.ONE * 0.00001
				)
			var end: Vector3 = ore.surface_position(cell, direction, block)
			ore.progress = 0.0
			assert_vector(ore.surface_position(
				cell + direction + Vector3i.UP * (1 if up else -1), direction, block
			)).is_equal_approx(end, Vector3.ONE * 0.00001)
			assert_vector(ore.surface_position(
				cell + direction + Vector3i.UP * (1 if up else 0), direction
			)).is_equal_approx(end, Vector3.ONE * 0.00001)


func test_camera_sweep_crosses_air_and_stops_at_slope_including_upper_lip() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	world.place_block(Vector3i.ZERO, 12)
	var start: Vector3 = Vector3(0.4, 0.1, -0.2)
	assert_vector(FreeCameraRules.move_linear(world, start, Vector3.BACK * 0.8, start, 10, 0.02)).is_equal_approx(
		start + Vector3.BACK * 0.8, Vector3.ONE * 0.001
	)
	start = Vector3(0.48, 0.55, -0.2)
	var end: Vector3 = FreeCameraRules.move_linear(world, start, Vector3.BACK * 0.8, start, 10, 0.02)
	assert_float(end.z).is_less(0.0)
	assert_float(end.z).is_greater(-0.1)


func test_packed_slopes_resume_together_and_keep_linear_work_bound() -> void:
	var world: VoxelWorldData = VoxelWorldData.new()
	var logistics: LogisticsData = LogisticsData.new()
	logistics.bind_world(world, 0.1, 8)
	world.place_block(Vector3i.ZERO, 5)
	logistics.set_direction(Vector3i.ZERO, Vector3i.RIGHT)
	for x: int in range(1, 9):
		world.place_block(Vector3i(x, x - 1, 0), 12)
	logistics.advance(10.0)
	var ids: Array[int] = []
	var progress: Array[float] = []
	for x: int in range(1, 9):
		var ores: Array[LogisticsOre] = logistics.belt_ores(Vector3i(x, x - 1, 0))
		assert_int(ores.size()).is_equal(2)
		for ore: LogisticsOre in ores:
			ids.append(ore.id)
			progress.append(ore.progress)
	assert_int(logistics.work_stats()["sample"]).is_less_equal(16 * 9)
	world.place_block(Vector3i(9, 8, 0), 12)
	logistics.advance(0.125)
	var resumed_ids: Array[int] = []
	for x: int in range(1, 10):
		for ore: LogisticsOre in logistics.belt_ores(Vector3i(x, x - 1, 0)):
			resumed_ids.append(ore.id)
			var index: int = ids.find(ore.id)
			if index >= 0:
				var previous_cell: int = index / 2 + 1
				assert_float(ore.progress + float(x - previous_cell) - progress[index]).is_equal_approx(0.25, 0.00001)
	for id: int in ids:
		assert_bool(resumed_ids.has(id)).is_true()
	assert_int(logistics.work_stats()["advance"]).is_less_equal(80 * 10 * 9)
