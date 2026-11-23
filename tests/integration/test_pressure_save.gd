extends GdUnitTestSuite

const NATIVE_BENCHMARK: GDScript = preload("res://scripts/pressure_native_benchmark.gd")


func test_benchmark_rejects_gameplay_input_but_allows_explicit_ticks() -> void:
	var game: FactoryGame = auto_free(load("res://scenes/main.tscn").instantiate()) as FactoryGame
	game.initial_snapshot = PressureSaveBuilder.new().build(8, 6)
	add_child(game)
	NATIVE_BENCHMARK.isolate_game(game)
	var before_tick: int = game.logistics_data.logic_tick()
	var before_camera: Transform3D = game.player.camera.global_transform
	var before_direction: Vector3i = game.build_direction()
	var before_selected: int = game.selected_block
	for action: String in ["select_belt", "rotate_build", "toggle_inventory", "toggle_view"]:
		var event: InputEventAction = InputEventAction.new()
		event.action = action
		event.pressed = true
		# This public boundary remains deterministic in headless GdUnit4.
		game.player.handle_input(event)
	assert_int(game.selected_block).is_equal(before_selected)
	assert_bool(game.build_direction() == before_direction).is_true()
	assert_bool(game.inventory_view.visible).is_false()
	assert_bool(game.free_camera.active).is_false()
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.relative = Vector2(30, 20)
	game.player.handle_input(motion)
	assert_bool(game.player.camera.global_transform.is_equal_approx(before_camera)).is_true()
	assert_bool(game.is_processing_input()).is_false()
	assert_bool(game.player.is_processing_unhandled_input()).is_false()
	# Check GUI isolation without leaking the setting to other test suites.
	var gui_disabled: bool = game.get_viewport().gui_disable_input
	game.get_viewport().gui_disable_input = false
	assert_bool(gui_disabled).is_true()
	game.logistics_data.advance(LogisticsData.LOGIC_STEP)
	assert_int(game.logistics_data.logic_tick()).is_equal(before_tick + 1)


func test_named_pressure_file_and_actual_scene_restore() -> void:
	var builder: PressureSaveBuilder = PressureSaveBuilder.new()
	var snapshot: SessionSnapshot = builder.build(8, 6)
	var expected: Dictionary = snapshot.logistics.save_state()
	var store: SaveGameStore = SaveGameStore.new()
	store.directory = OS.get_cache_dir().path_join("factory_pressure_%d" % Time.get_ticks_usec())
	assert_bool(store.save_named(PressureSaveBuilder.state_for(snapshot), "压力存档")).is_true()
	var before_decodes: int = store.snapshot_decodes
	var decoded: SessionSnapshot = store.load_named_snapshot(store.latest_id())
	assert_int(store.snapshot_decodes - before_decodes).is_equal(1)
	assert_object(decoded).is_not_null()
	if decoded != null:
		assert_bool(decoded.logistics.save_state() == expected).is_true()
		var game: FactoryGame = auto_free(load("res://scenes/main.tscn").instantiate()) as FactoryGame
		game.initial_snapshot = decoded
		add_child(game)
		game.set_physics_process(false)
		game.player.set_physics_process(false)
		assert_bool(game.world_data.is_in_bounds(Vector3i(3, 4, 3))).is_true()
		assert_int(game.world_data.floor_depth).is_equal(1)
		assert_bool(game.logistics_data.save_state() == expected).is_true()
		assert_int(game.world_view.get_child_count()).is_greater(0)
		assert_bool(game.player.position.is_equal_approx(decoded.position)).is_true()
	# Delete only this test's unique snapshot through the production catalog.
	assert_bool(store.delete_save(store.latest_id())).is_true()
	_remove_empty_store(store.directory)


func test_ready_adopts_validated_snapshot_once_and_continues_identically() -> void:
	var builder: PressureSaveBuilder = PressureSaveBuilder.new()
	var snapshot: SessionSnapshot = builder.build(8, 6)
	snapshot.logistics.advance(0.125)
	assert_bool(snapshot.logistics.set_direction(Vector3i(-4, 0, -4), Vector3i.BACK)).is_true()
	var state: Dictionary = PressureSaveBuilder.state_for(snapshot)
	var expected: SessionSnapshot = SessionSnapshot.decode(state)
	assert_object(expected).is_not_null()
	if expected == null:
		return
	var game: FactoryGame = auto_free(load("res://scenes/main.tscn").instantiate()) as FactoryGame
	game.initial_snapshot = snapshot
	add_child(game)
	game.set_physics_process(false)
	game.player.set_physics_process(false)
	assert_bool(is_same(game.world_data, snapshot.world)).is_true()
	assert_bool(is_same(game.logistics_data, snapshot.logistics)).is_true()
	assert_bool(is_same(game.inventory, snapshot.inventory)).is_true()
	assert_object(game.initial_snapshot).is_null()
	assert_bool(game.logistics_data.save_state() == expected.logistics.save_state()).is_true()
	for delta: float in [0.007, 0.1, 0.43]:
		game.logistics_data.sample_cells([Vector3i(-4, 0, -4)], 100.0)
		game.logistics_data.advance(delta)
		expected.logistics.advance(delta)
		assert_bool(game.logistics_data.save_state() == expected.logistics.save_state()).is_true()


func _remove_empty_store(directory: String) -> void:
	DirAccess.remove_absolute(directory.path_join("snapshots"))
	DirAccess.remove_absolute(directory.path_join("index.bin"))
	DirAccess.remove_absolute(directory)
