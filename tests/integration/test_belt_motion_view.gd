extends GdUnitTestSuite

var _game: FactoryGame


func before_test() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_game = auto_free(scene.instantiate()) as FactoryGame
	add_child(_game)
	_game.set_physics_process(false)
	_game.player.set_physics_process(false)
	_game.player.set_controls_captured(false)
	_game.logistics_view.set_process(false)
	_game.logistics_data.bind_world(_game.world_data)
	_game.world_data.place_block(Vector3i.LEFT, VoxelWorldData.Block.MINER)
	_game.logistics_data.set_direction(Vector3i.LEFT, Vector3i.RIGHT)
	_game.world_data.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT)
	_game.logistics_data.set_direction(Vector3i.ZERO, Vector3i.RIGHT)


func _position(id: int) -> Vector3:
	assert_bool(_game.logistics_view.item_render_pool.has_item(id)).is_true()
	return _game.logistics_view.item_render_pool.item_transform(id).origin


func test_belt_items_are_batched_without_per_item_nodes() -> void:
	_game.logistics_data.advance(1.125)
	_game.logistics_view.refresh_from_data()
	assert_int(_game.logistics_data.ore_count(Vector3i.ZERO)).is_equal(1)
	assert_int(_game.logistics_view.find_children(
		"BeltOre*", "MeshInstance3D", true, false
	).size()).is_equal(0)
	var batches: Array[Node] = _game.logistics_view.find_children(
		"ItemBatch*", "MultiMeshInstance3D", true, false
	)
	assert_int(batches.size()).is_equal(1)


func test_ore_moves_between_transport_events_while_quantity_stays_the_same() -> void:
	_game.logistics_data.advance(1.0)
	_game.logistics_view.refresh_from_data()
	var id: int = _game.logistics_data.belt_ores(Vector3i.ZERO)[0].id
	var before: Vector3 = _position(id)
	assert_int(_game.logistics_data.ore_count(Vector3i.ZERO)).is_equal(1)
	_game.logistics_data.advance(0.125)
	_game.logistics_view.refresh_from_data()
	assert_int(_game.logistics_data.ore_count(Vector3i.ZERO)).is_equal(1)
	assert_float(_position(id).x - before.x).is_equal_approx(0.125, 0.00001)
	assert_float(_position(id).y).is_equal_approx(0.12, 0.00001)


func test_crossing_belt_boundary_reuses_the_batch_and_preserves_identity() -> void:
	_game.world_data.place_block(Vector3i.RIGHT, VoxelWorldData.Block.BELT)
	_game.logistics_data.set_direction(Vector3i.RIGHT, Vector3i.RIGHT)
	_game.logistics_data.advance(1.499999)
	_game.logistics_view.refresh_from_data()
	var id: int = _game.logistics_data.belt_ores(Vector3i.ZERO)[0].id
	var batch: ItemRenderBatch = _game.logistics_view.item_render_pool.item_batch(id)
	var before: Vector3 = _position(id)
	_game.logistics_data.advance(0.000001)
	_game.logistics_view.refresh_from_data()
	assert_object(_game.logistics_view.item_render_pool.item_batch(id)).is_same(batch)
	assert_int(_game.logistics_data.belt_ores(Vector3i.RIGHT)[0].id).is_equal(id)
	assert_vector(_position(id)).is_equal_approx(before, Vector3.ONE * 0.00001)
	_game.logistics_data.advance(0.125)
	_game.logistics_view.refresh_from_data()
	assert_float(_position(id).x).is_equal_approx(0.625, 0.00001)
	assert_int(batch.find_children("*", "CollisionObject3D", true, false).size()).is_equal(0)


func test_hidden_view_resumes_at_current_position_without_replaying_entry() -> void:
	_game.logistics_data.advance(1.0)
	_game.logistics_view.refresh_from_data()
	_game.logistics_view.hide()
	_game.logistics_data.advance(0.2)
	_game.logistics_view.refresh_from_data()
	assert_int(_game.logistics_data.ore_count(Vector3i.ZERO)).is_equal(1)
	_game.logistics_view.show()
	_game.logistics_view.refresh_from_data()
	var id: int = _game.logistics_data.belt_ores(Vector3i.ZERO)[0].id
	assert_float(_position(id).x).is_equal_approx(0.2, 0.00001)


func test_culled_and_recreated_view_restore_current_snapshot() -> void:
	_game.logistics_data.advance(1.0)
	_game.logistics_view.refresh_from_data()
	var camera: Camera3D = _game.player.camera
	var camera_position: Vector3 = camera.global_position
	camera.global_position = Vector3(1000, 1000, 1000)
	_game.logistics_view.refresh_from_data()
	assert_int(_game.logistics_view.item_render_pool.stats()["visible_items"]).is_equal(0)
	_game.logistics_data.advance(0.125)
	camera.global_position = camera_position
	_game.logistics_view.refresh_from_data()
	var id: int = _game.logistics_data.belt_ores(Vector3i.ZERO)[0].id
	assert_float(_position(id).x).is_equal_approx(0.125, 0.00001)
	_game.logistics_view.free()
	_game.logistics_data.advance(0.125)
	var restored: LogisticsView = auto_free(LogisticsView.new()) as LogisticsView
	_game.add_child(restored)
	restored.set_process(false)
	restored.render_distance = _game.game_config.ore_render_distance
	restored.bind_logistics(_game.logistics_data, _game.world_data, camera)
	_game.logistics_view = restored
	restored.refresh_from_data()
	assert_float(_position(id).x).is_equal_approx(0.25, 0.00001)


func test_removing_belt_and_world_reset_clean_up_item_instances() -> void:
	_game.logistics_data.advance(1.1)
	_game.logistics_view.refresh_from_data()
	var id: int = _game.logistics_data.belt_ores(Vector3i.ZERO)[0].id
	assert_bool(_game.logistics_view.item_render_pool.has_item(id)).is_true()
	_game.world_data.break_block(Vector3i.ZERO)
	_game.logistics_view.refresh_from_data()
	assert_bool(_game.logistics_view.item_render_pool.has_item(id)).is_false()
	_game.world_data.generate_flat()
	assert_int(_game.logistics_view.item_render_pool.get_child_count()).is_equal(0)


func test_render_prediction_moves_without_changing_backend_or_crossing_deadline() -> void:
	_game.world_data.place_block(Vector3i.RIGHT, VoxelWorldData.Block.BELT)
	_game.logistics_data.set_direction(Vector3i.RIGHT, Vector3i.RIGHT)
	_game.logistics_data.advance(1.495)
	var id: int = _game.logistics_data.belt_ores(Vector3i.ZERO)[0].id
	_game.logistics_view.refresh_from_data(1.0 / 60.0)
	assert_float(_position(id).x).is_equal_approx(0.5, 0.00001)
	assert_float(_game.logistics_data.belt_ores(Vector3i.ZERO)[0].progress).is_equal_approx(
		0.99, 0.00001
	)
	assert_int(_game.logistics_data.ore_count(Vector3i.RIGHT)).is_equal(0)
	_game.logistics_data.advance(0.005)
	_game.logistics_view.refresh_from_data()
	assert_int(_game.logistics_data.belt_ores(Vector3i.RIGHT)[0].id).is_equal(id)
	assert_float(_position(id).x).is_equal_approx(0.5, 0.00001)


func test_reconnected_packed_line_moves_all_existing_visuals_at_the_same_speed() -> void:
	_game.logistics_data.configure_miners(0.1, 8)
	_game.world_data.break_block(Vector3i.LEFT)
	_game.world_data.place_block(Vector3i.LEFT, VoxelWorldData.Block.MINER)
	_game.logistics_data.set_direction(Vector3i.LEFT, Vector3i.RIGHT)
	for x: int in [1, 2]:
		_game.world_data.place_block(Vector3i(x, 0, 0), VoxelWorldData.Block.BELT)
		_game.logistics_data.set_direction(Vector3i(x, 0, 0), Vector3i.RIGHT)
	_game.logistics_data.advance(5.0)
	_game.logistics_view.refresh_from_data()
	var ids: Array[int] = []
	var positions: Array[Vector3] = []
	for cell: Vector3i in _game.logistics_data.machine_cells():
		for ore: LogisticsOre in _game.logistics_data.belt_ores(cell):
			ids.append(ore.id)
			positions.append(_position(ore.id))
	assert_int(ids.size()).is_equal(6)
	_game.world_data.place_block(Vector3i(3, 0, 0), VoxelWorldData.Block.BELT)
	_game.logistics_data.set_direction(Vector3i(3, 0, 0), Vector3i.RIGHT)
	_game.logistics_data.advance(0.125)
	_game.logistics_view.refresh_from_data()
	for index: int in range(ids.size()):
		assert_float(_position(ids[index]).x - positions[index].x).is_equal_approx(
			0.125, 0.00001
		)


func test_crossing_spatial_partition_keeps_position_and_retires_old_instance() -> void:
	_game.world_data.generate_flat()
	for x: int in [6, 7, 8]:
		_game.world_data.place_block(Vector3i(x, 0, 0),
			VoxelWorldData.Block.MINER if x == 6 else VoxelWorldData.Block.BELT
		)
		_game.logistics_data.set_direction(Vector3i(x, 0, 0), Vector3i.RIGHT)
	_game.logistics_data.advance(1.499999)
	_game.logistics_view.refresh_from_data()
	var id: int = _game.logistics_data.belt_ores(Vector3i(7, 0, 0))[0].id
	var before: Vector3 = _position(id)
	var old_batch: ItemRenderBatch = _game.logistics_view.item_render_pool.item_batch(id)
	_game.logistics_data.advance(0.000001)
	_game.logistics_view.refresh_from_data()
	assert_vector(_position(id)).is_equal_approx(before, Vector3.ONE * 0.00001)
	assert_object(_game.logistics_view.item_render_pool.item_batch(id)).is_not_same(old_batch)
	assert_int(old_batch.multimesh.visible_instance_count).is_equal(0)
	assert_int(_game.logistics_view.item_render_pool.stats()["visible_items"]).is_equal(1)
