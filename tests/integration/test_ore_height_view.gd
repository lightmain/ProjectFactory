extends GdUnitTestSuite
## Height is a display parameter relative to the current camera.

var _game: FactoryGame


func before_test() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_game = auto_free(scene.instantiate()) as FactoryGame
	_game.game_config = _game.game_config.duplicate() as GameConfig
	add_child(_game)
	_game.set_physics_process(false)
	_game.player.set_physics_process(false)
	_game.player.set_controls_captured(false)
	_game.logistics_view.set_process(false)
	_game.game_config.ore_render_distance = 100.0


func _set_height(value: float) -> bool:
	var current: Variant = _game.game_config.get("ore_render_max_height_above_camera")
	assert_bool(current is float).is_true()
	if not current is float:
		return false
	_game.game_config.set("ore_render_max_height_above_camera", value)
	return true


func _belt(cell: Vector3i, block: int = VoxelWorldData.Block.BELT) -> Array[LogisticsOre]:
	assert_bool(_game.world_data.place_block(cell, block)).is_true()
	assert_bool(_game.logistics_data.prefill_belts()).is_true()
	return _game.logistics_data.belt_ores(cell)


func _render_position(ore: LogisticsOre, cell: Vector3i, block: int) -> Vector3:
	return ore.surface_position(cell, _game.logistics_data.direction_at(cell), block) + Vector3.UP * 0.04


func test_height_parameter_has_explicit_persisted_default_and_independent_instances() -> void:
	var config: GameConfig = load("res://config/game_config.tres") as GameConfig
	var value: Variant = config.get("ore_render_max_height_above_camera")
	assert_bool(value is float).is_true()
	if not value is float:
		return
	assert_float(value).is_equal(2.0)
	assert_bool(FileAccess.get_file_as_string("res://config/game_config.tres").contains(
		"ore_render_max_height_above_camera = 2.0"
	)).is_true()
	if not _set_height(3.0):
		return
	assert_float(_game.logistics_view.get("ore_render_max_height_above_camera")).is_equal(3.0)
	assert_float(config.get("ore_render_max_height_above_camera")).is_equal(2.0)


func test_default_height_keeps_equal_render_centres_and_hides_above_without_hiding_facility() -> void:
	var cell: Vector3i = Vector3i(0, 4, 0)
	var ores: Array[LogisticsOre] = _belt(cell)
	assert_int(ores.size()).is_equal(2)
	if ores.size() != 2:
		return
	var position: Vector3 = _render_position(ores[0], cell, VoxelWorldData.Block.BELT)
	_game.player.camera.global_position = Vector3(position.x, position.y - 2.0, position.z)
	_game.logistics_view.refresh_from_data()
	assert_int(_game.logistics_view.item_render_pool.stats()["visible_items"]).is_equal(2)
	_game.player.camera.global_position.y -= 0.001
	_game.logistics_view.refresh_from_data()
	assert_int(_game.logistics_view.item_render_pool.stats()["visible_items"]).is_equal(0)
	assert_bool(_game.logistics_view.has_node("Machine_0_4_0")).is_true()
	assert_int(_game.logistics_data.ore_count(cell)).is_equal(2)


func test_zero_height_uses_current_camera_y_and_camera_switch_restores_identity() -> void:
	if not _set_height(0.0):
		return
	var ores: Array[LogisticsOre] = _belt(Vector3i.ZERO)
	assert_int(ores.size()).is_equal(2)
	if ores.size() != 2:
		return
	var position: Vector3 = _render_position(ores[0], Vector3i.ZERO, VoxelWorldData.Block.BELT)
	_game.player.camera.global_position = position
	_game.logistics_view.refresh_from_data()
	assert_int(_game.logistics_view.item_render_pool.stats()["visible_items"]).is_equal(2)
	var alternate: Camera3D = Camera3D.new()
	_game.add_child(alternate)
	alternate.global_position = position - Vector3.UP * 0.001
	_game.logistics_view.set_camera(alternate)
	_game.logistics_view.refresh_from_data()
	assert_int(_game.logistics_view.item_render_pool.stats()["visible_items"]).is_equal(0)
	_game.logistics_view.set_camera(_game.player.camera)
	_game.logistics_view.refresh_from_data()
	for ore: LogisticsOre in ores:
		assert_bool(_game.logistics_view.item_render_pool.has_item(ore.id)).is_true()
		if not _game.logistics_view.item_render_pool.has_item(ore.id):
			continue
		assert_vector(_game.logistics_view.item_render_pool.item_transform(ore.id).origin).is_equal_approx(
			_render_position(ore, Vector3i.ZERO, VoxelWorldData.Block.BELT), Vector3.ONE * 0.000001
		)


func test_runtime_height_changes_and_invalid_values_use_default_without_changing_snapshot() -> void:
	var cell: Vector3i = Vector3i(0, 4, 0)
	var ores: Array[LogisticsOre] = _belt(cell)
	assert_int(ores.size()).is_equal(2)
	if ores.size() != 2 or not _set_height(0.0):
		return
	var position: Vector3 = _render_position(ores[0], cell, VoxelWorldData.Block.BELT)
	_game.player.camera.global_position = Vector3(position.x, position.y - 2.0, position.z)
	var before: Dictionary = _game.logistics_data.save_state()
	_game.logistics_view.refresh_from_data()
	assert_int(_game.logistics_view.item_render_pool.stats()["visible_items"]).is_equal(0)
	for value: float in [2.0, 3.0, -1.0, NAN, INF, -INF]:
		assert_bool(_set_height(value)).is_true()
		_game.logistics_view.refresh_from_data()
		assert_int(_game.logistics_view.item_render_pool.stats()["visible_items"]).is_equal(2)
		assert_bool(_game.logistics_data.save_state() == before).is_true()
	_game.game_config.set("ore_render_max_height_above_camera", 0.0)
	_game.logistics_view.refresh_from_data()
	assert_int(_game.logistics_view.item_render_pool.stats()["visible_items"]).is_equal(0)


func test_all_slope_directions_filter_final_centres_across_threshold() -> void:
	if not _set_height(0.0):
		return
	for block: int in range(VoxelWorldData.Block.BELT_UP, VoxelWorldData.Block.BELT_DOWN_EAST + 1):
		_game.world_data.generate_flat()
		var ores: Array[LogisticsOre] = _belt(Vector3i.ZERO, block)
		assert_int(ores.size()).is_equal(2)
		if ores.size() != 2:
			return
		var first: Vector3 = _render_position(ores[0], Vector3i.ZERO, block)
		var second: Vector3 = _render_position(ores[1], Vector3i.ZERO, block)
		_game.player.camera.global_position = Vector3(0.25, (first.y + second.y) * 0.5, 0.25)
		var before: Dictionary = _game.logistics_data.save_state()
		_game.logistics_view.refresh_from_data()
		assert_int(_game.logistics_view.item_render_pool.stats()["visible_items"]).is_equal(1)
		for ore: LogisticsOre in ores:
			var position: Vector3 = _render_position(ore, Vector3i.ZERO, block)
			assert_bool(_game.logistics_view.item_render_pool.has_item(ore.id)).is_equal(
				position.y <= _game.player.camera.global_position.y
			)
		assert_bool(_game.logistics_view.has_node("Machine_0_0_0")).is_true()
		assert_bool(_game.logistics_data.save_state() == before).is_true()


func test_pure_height_parameter_boundary_validation() -> void:
	for value: float in [0.0, 0.001, 2.0, 100000000000000000000.0]:
		assert_float(GameConfig.validated_ore_render_height(value)).is_equal(value)
	for value: float in [-0.001, NAN, INF, -INF]:
		assert_float(GameConfig.validated_ore_render_height(value)).is_equal(2.0)


func test_wholly_high_belt_skips_prediction_but_inventory_and_decorations_remain() -> void:
	if not _set_height(0.0):
		return
	var belt: Vector3i = Vector3i(0, 8, 0)
	var chest: Vector3i = Vector3i.RIGHT
	assert_bool(_game.world_data.place_block(belt, VoxelWorldData.Block.BELT)).is_true()
	assert_bool(_game.world_data.place_block(chest, VoxelWorldData.Block.CHEST)).is_true()
	assert_bool(_game.logistics_data.prefill_belts()).is_true()
	var saved: Dictionary = _game.logistics_data.save_state()
	var rows: Array = saved["machines"]
	for row: Dictionary in rows:
		if row["cell"] == chest:
			row["quantity"] = 2
			row["eligible"] = 2
	assert_bool(_game.logistics_data.restore_state(saved)).is_true()
	_game.player.camera.global_position = Vector3(0.25, -2.0, 0.25)
	assert_int(_game.logistics_data.work_stats()["sample_solves"]).is_equal(0)
	_game.logistics_view.refresh_from_data()
	assert_int(_game.logistics_data.work_stats()["sample_solves"]).is_equal(0)
	assert_int(_game.logistics_view.item_render_pool.stats()["visible_items"]).is_equal(0)
	assert_bool(_game.logistics_view.has_node("Machine_0_8_0")).is_true()
	var first: MeshInstance3D = _game.logistics_view.get_node("Machine_1_0_0/Ore1") as MeshInstance3D
	var second: MeshInstance3D = _game.logistics_view.get_node("Machine_1_0_0/Ore2") as MeshInstance3D
	assert_bool(first.visible).is_true()
	assert_bool(second.visible).is_true()
	assert_bool(_game.logistics_data.save_state() == saved).is_true()


func test_sloped_predicted_centres_keep_exact_equality_and_cross_height_both_ways() -> void:
	if not _set_height(0.0):
		return
	var extra: float = LogisticsData.LOGIC_STEP * 0.5
	for block: int in range(9, 17):
		_game.world_data.generate_flat()
		_belt(Vector3i.ZERO, block)
		var saved: Dictionary = _game.logistics_data.save_state()
		var rows: Array = saved["machines"]
		var row: Dictionary = rows[0]
		var ores: Array = row["ores"]
		ores.resize(1)
		ores[0]["progress"] = 0.25
		row["quantity"] = 1
		row["eligible"] = 1
		assert_bool(_game.logistics_data.restore_state(saved)).is_true()
		var current: LogisticsOre = _game.logistics_data.belt_ores(Vector3i.ZERO)[0]
		var predicted: LogisticsOre = _game.logistics_data.belt_ores(Vector3i.ZERO, extra)[0]
		var current_position: Vector3 = _render_position(current, Vector3i.ZERO, block)
		var predicted_position: Vector3 = _render_position(predicted, Vector3i.ZERO, block)
		_game.player.camera.global_position = predicted_position
		_game.logistics_view.refresh_from_data(extra)
		assert_bool(_game.logistics_view.item_render_pool.has_item(predicted.id)).is_true()
		_game.player.camera.global_position.y -= 0.001
		_game.logistics_view.refresh_from_data(extra)
		assert_bool(_game.logistics_view.item_render_pool.has_item(predicted.id)).is_false()
		_game.player.camera.global_position.y = (current_position.y + predicted_position.y) * 0.5
		_game.logistics_view.refresh_from_data()
		assert_bool(_game.logistics_view.item_render_pool.has_item(current.id)).is_equal(
			VoxelWorldData.slope_rise(block) > 0
		)
		_game.logistics_view.refresh_from_data(extra)
		assert_bool(_game.logistics_view.item_render_pool.has_item(predicted.id)).is_equal(
			VoxelWorldData.slope_rise(block) < 0
		)
		assert_bool(_game.logistics_data.save_state() == saved).is_true()
