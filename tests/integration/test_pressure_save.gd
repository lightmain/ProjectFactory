extends GdUnitTestSuite


func test_named_pressure_file_and_actual_scene_restore() -> void:
	var builder: PressureSaveBuilder = PressureSaveBuilder.new()
	var snapshot: SessionSnapshot = builder.build(8, 6)
	var expected: Dictionary = snapshot.logistics.save_state()
	var store: SaveGameStore = SaveGameStore.new()
	store.directory = OS.get_cache_dir().path_join("factory_pressure_%d" % Time.get_ticks_usec())
	assert_bool(store.save_named(PressureSaveBuilder.state_for(snapshot), "压力存档")).is_true()
	var decoded: SessionSnapshot = SessionSnapshot.decode(store.load_named(store.latest_id()))
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


func _remove_empty_store(directory: String) -> void:
	DirAccess.remove_absolute(directory.path_join("snapshots"))
	DirAccess.remove_absolute(directory.path_join("index.bin"))
	DirAccess.remove_absolute(directory)
