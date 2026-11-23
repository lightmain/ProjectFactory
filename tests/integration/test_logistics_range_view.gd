extends GdUnitTestSuite
## Actual view consumers must filter before requesting independent sample rows.

class ObservedLogistics:
	extends LogisticsData

	var full_calls: int = 0
	var cell_calls: int = 0
	var requested: Array[Vector3i] = []

	func sample_belts(extra_time: float = 0.0) -> Array[LogisticsOreQueue]:
		full_calls += 1
		return super.sample_belts(extra_time)

	func sample_cells(cells: Array[Vector3i], extra_time: float = 0.0) -> Array[LogisticsOreQueue]:
		cell_calls += 1
		requested = cells.duplicate()
		return super.sample_cells(cells, extra_time)


var _root: Node3D
var _world: VoxelWorldData
var _data: ObservedLogistics
var _camera: Camera3D
var _view: LogisticsView


func before_test() -> void:
	_root = auto_free(Node3D.new()) as Node3D
	add_child(_root)
	_world = VoxelWorldData.new()
	assert_bool(_world.generate_flat(Vector3i(-32, -2, -32), Vector3i(32, 16, 32), 2)).is_true()
	_data = ObservedLogistics.new()
	_data.bind_world(_world)
	_camera = Camera3D.new()
	_root.add_child(_camera)
	_camera.global_position = VoxelWorldData.cell_center(Vector3i.ZERO)
	_view = LogisticsView.new()
	_root.add_child(_view)
	_view.set_process(false)
	_view.render_distance = 0.5
	_view.bind_logistics(_data, _world, _camera)


func _place(cell: Vector3i, block: int = VoxelWorldData.Block.BELT) -> void:
	assert_bool(_world.place_block(cell, block)).is_true()
	assert_bool(_data.set_direction(cell, Vector3i.RIGHT)).is_true()


func _visual_count() -> int:
	return _view.find_children("Machine_*", "Node3D", false, false).size()


func _running_line() -> int:
	_place(Vector3i.LEFT, VoxelWorldData.Block.MINER)
	_place(Vector3i.ZERO)
	_data.advance(1.125)
	var ores: Array[LogisticsOre] = _data.belt_ores(Vector3i.ZERO)
	assert_int(ores.size()).is_equal(1)
	return ores[0].id if not ores.is_empty() else -1


func test_sphere_boundary_and_vertical_distance_filter_before_copying() -> void:
	for cell: Vector3i in [Vector3i.ZERO, Vector3i.RIGHT, Vector3i.UP, Vector3i(1, 0, 1)]:
		_place(cell)
	_view.refresh_from_data()
	assert_int(_data.full_calls).is_equal(0)
	assert_int(_data.cell_calls).is_equal(1)
	assert_int(_data.requested.size()).is_equal(3)
	for cell: Vector3i in [Vector3i.ZERO, Vector3i.RIGHT, Vector3i.UP]:
		assert_bool(_data.requested.has(cell)).is_true()
	assert_bool(_data.requested.has(Vector3i(1, 0, 1))).is_false()
	assert_int(_visual_count()).is_equal(3)


func test_disabled_distance_and_empty_world_range_skip_sample_and_retire_visuals() -> void:
	var id: int = _running_line()
	_view.refresh_from_data()
	assert_bool(_view.item_render_pool.has_item(id)).is_true()
	var calls: int = _data.cell_calls
	for distance: float in [0.0, -1.0, NAN, INF]:
		_view.render_distance = distance
		_view.refresh_from_data()
		assert_int(_data.full_calls).is_equal(0)
		assert_int(_data.cell_calls).is_equal(calls)
		assert_int(_visual_count()).is_equal(0)
		assert_int(_view.item_render_pool.stats()["visible_items"]).is_equal(0)
	_view.render_distance = 0.5
	_camera.global_position = Vector3.ONE * 100000000000000000000.0
	_view.refresh_from_data()
	assert_int(_data.cell_calls).is_equal(calls)
	assert_int(_data.full_calls).is_equal(0)


func test_camera_switch_culls_previous_cells_and_restores_current_identity() -> void:
	var id: int = _running_line()
	_place(Vector3i(16, 0, 16), VoxelWorldData.Block.CHEST)
	_view.refresh_from_data()
	var alternate: Camera3D = Camera3D.new()
	_root.add_child(alternate)
	alternate.global_position = VoxelWorldData.cell_center(Vector3i(16, 0, 16))
	_view.set_camera(alternate)
	_view.refresh_from_data()
	assert_bool(_view.item_render_pool.has_item(id)).is_false()
	assert_int(_visual_count()).is_equal(1)
	assert_bool(_view.has_node("Machine_0_0_0")).is_false()
	_data.advance(0.125)
	_view.set_camera(_camera)
	_view.refresh_from_data()
	assert_bool(_view.item_render_pool.has_item(id)).is_true()
	assert_float(_view.item_render_pool.item_transform(id).origin.x).is_equal_approx(0.25, 0.000001)
	assert_bool(_view.has_node("Machine_16_0_16")).is_false()
	assert_int(_data.full_calls).is_equal(0)


func test_hidden_view_does_no_queries_and_rebind_removes_previous_state() -> void:
	_running_line()
	_view.refresh_from_data()
	var calls: int = _data.cell_calls
	_view.hide()
	_data.advance(0.125)
	_view.refresh_from_data()
	assert_int(_data.cell_calls).is_equal(calls)
	assert_int(_data.full_calls).is_equal(0)
	_view.show()
	var replacement: ObservedLogistics = ObservedLogistics.new()
	var world: VoxelWorldData = VoxelWorldData.new()
	world.generate_flat()
	replacement.bind_world(world)
	world.place_block(Vector3i.ZERO, VoxelWorldData.Block.CHEST)
	_view.bind_logistics(replacement, world, _camera)
	_view.refresh_from_data()
	assert_int(replacement.full_calls).is_equal(0)
	# Inventory-only decorations do not require transport predictions.
	assert_int(replacement.cell_calls).is_equal(0)
	assert_int(_view.item_render_pool.stats()["visible_items"]).is_equal(0)
	assert_int(_visual_count()).is_equal(1)


func test_invisible_downstream_still_blocks_prediction_and_queries_keep_pending_edit() -> void:
	_data.configure_miners(0.1, 8)
	_place(Vector3i.LEFT, VoxelWorldData.Block.MINER)
	for x: int in range(4):
		_place(Vector3i(x, 0, 0))
	_data.advance(5.0)
	_view.render_distance = 0.1
	assert_bool(_data.set_direction(Vector3i.ZERO, Vector3i.BACK)).is_true()
	var before: Dictionary = _data.save_state()
	var expected: Array[LogisticsOreQueue] = _data.sample_cells([Vector3i.ZERO], 100.0)
	assert_int(expected.size()).is_equal(1)
	_view.refresh_from_data(100.0)
	assert_int(_data.full_calls).is_equal(0)
	assert_bool(_data.requested == [Vector3i.ZERO]).is_true()
	assert_int(expected[0].ores.size()).is_equal(2)
	for ore: LogisticsOre in expected[0].ores:
		assert_bool(_view.item_render_pool.has_item(ore.id)).is_true()
		assert_vector(_view.item_render_pool.item_transform(ore.id).origin).is_equal_approx(
			ore.surface_position(Vector3i.ZERO, expected[0].direction, expected[0].block) + Vector3.UP * 0.04,
			Vector3.ONE * 0.000001
		)
	assert_bool(_data.save_state() == before).is_true()


func test_fixed_visible_set_keeps_requested_rows_bounded_as_distant_factory_grows() -> void:
	_running_line()
	_view.render_distance = 0.1
	_view.refresh_from_data()
	var before: Array[Vector3i] = _data.requested.duplicate()
	for x: int in range(16, 32):
		for z: int in range(-32, 0):
			_place(Vector3i(x, 0, z))
	_view.refresh_from_data()
	assert_int(_data.full_calls).is_equal(0)
	assert_bool(_data.requested == before).is_true()
	assert_int(_data.requested.size()).is_equal(1)
	assert_int(_data.work_stats().get("sample_return_rows", -1)).is_equal(1)
	assert_int(_data.work_stats().get("sample_return_ores", -1)).is_equal(1)


func test_visible_rows_match_full_sampling_across_slope_prediction_and_edit_boundaries() -> void:
	_running_line()
	var cells: Array[Vector3i] = [
		Vector3i(-7, 0, 3), Vector3i(-6, 0, 3), Vector3i(-5, 0, 3), Vector3i(-4, 1, 3),
		Vector3i(-3, 1, 3), Vector3i(-2, 0, 3), Vector3i(-1, 0, 3), Vector3i(0, 0, 3),
	]
	var blocks: Array[int] = [
		VoxelWorldData.Block.MINER, VoxelWorldData.Block.BELT,
		VoxelWorldData.Block.BELT_UP_EAST, VoxelWorldData.Block.BELT_UP_EAST,
		VoxelWorldData.Block.BELT_DOWN_EAST, VoxelWorldData.Block.BELT_DOWN_EAST,
		VoxelWorldData.Block.BELT, VoxelWorldData.Block.CHEST,
	]
	for index: int in range(cells.size()):
		_place(cells[index], blocks[index])
	_data.advance(3.125)
	assert_bool(_data.set_direction(Vector3i.ZERO, Vector3i.BACK)).is_true()
	_camera.global_position = Vector3(-1, 2, 1.5)
	_view.render_distance = 3.0
	for delta: float in [0.0, 0.005, LogisticsData.LOGIC_STEP]:
		_data.advance(delta)
		var before: Dictionary = _data.save_state()
		var reference: LogisticsData = LogisticsData.new()
		reference.bind_world(_world)
		assert_bool(reference.restore_state(before)).is_true()
		for extra: float in [0.0, 0.002, 1.0, NAN]:
			var expected_cells: Array[Vector3i] = []
			var expected_ores: int = 0
			_view.refresh_from_data(extra)
			for row: LogisticsOreQueue in reference.sample_belts(extra):
				if _camera.global_position.distance_squared_to(VoxelWorldData.cell_center(row.cell)) > 9.0:
					continue
				if VoxelWorldData.is_belt(row.block):
					expected_cells.append(row.cell)
				expected_ores += row.ores.size()
				for ore: LogisticsOre in row.ores:
					assert_bool(_view.item_render_pool.has_item(ore.id)).is_true()
					assert_vector(_view.item_render_pool.item_transform(ore.id).origin).is_equal_approx(
						ore.surface_position(row.cell, row.direction, row.block) + Vector3.UP * 0.04,
						Vector3.ONE * 0.000001
					)
			assert_int(_data.requested.size()).is_equal(expected_cells.size())
			for cell: Vector3i in expected_cells:
				assert_bool(_data.requested.has(cell)).is_true()
			assert_int(_view.item_render_pool.stats()["visible_items"]).is_equal(expected_ores)
			assert_bool(_data.save_state() == before).is_true()
	assert_int(_data.full_calls).is_equal(0)
