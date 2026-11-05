extends GdUnitTestSuite


func test_chunk_files_round_trip_and_reverted_chunk_is_not_saved() -> void:
	var game: FactoryGame = auto_free(load("res://scenes/main.tscn").instantiate()) as FactoryGame
	add_child(game)
	game.set_physics_process(false)
	game.player.set_physics_process(false)
	game.world_data.break_block(Vector3i(0, -1, 0))
	game.world_data.place_block(Vector3i(0, 32, 0), VoxelWorldData.Block.STONE)
	var store: SaveGameStore = SaveGameStore.new()
	store.directory = OS.get_cache_dir().path_join("factory_save_test_%d" % Time.get_ticks_usec())
	assert_bool(store.save_game(game.save_state())).is_true()
	var state: Dictionary = store.load_game()
	var snapshot: SessionSnapshot = SessionSnapshot.decode(state)
	assert_object(snapshot).is_not_null()
	assert_int(snapshot.world.get_block(Vector3i(0, -1, 0))).is_equal(VoxelWorldData.Block.AIR)
	assert_int(snapshot.world.get_block(Vector3i(0, 32, 0))).is_equal(VoxelWorldData.Block.STONE)
	assert_int(snapshot.world.chunk_deltas().size()).is_equal(2)
	game.world_data.break_block(Vector3i(0, 32, 0))
	assert_bool(store.save_game(game.save_state())).is_true()
	snapshot = SessionSnapshot.decode(store.load_game())
	assert_int(snapshot.world.chunk_deltas().size()).is_equal(1)
	_cleanup(store.directory)


func test_corrupt_active_save_is_rejected_and_previous_generation_survives_failed_write() -> void:
	var game: FactoryGame = auto_free(load("res://scenes/main.tscn").instantiate()) as FactoryGame
	add_child(game)
	game.set_physics_process(false)
	game.player.set_physics_process(false)
	var store: SaveGameStore = SaveGameStore.new()
	store.directory = OS.get_cache_dir().path_join("factory_save_test_%d" % Time.get_ticks_usec())
	assert_bool(store.save_game(game.save_state())).is_true()
	# Blocking the inactive generation prevents committing a partial overwrite.
	var blocker: FileAccess = FileAccess.open(store.directory.path_join("b"), FileAccess.WRITE)
	blocker.store_8(1)
	blocker.close()
	assert_bool(store.save_game(game.save_state())).is_false()
	assert_object(SessionSnapshot.decode(store.load_game())).is_not_null()
	DirAccess.remove_absolute(store.directory.path_join("b"))
	var corrupt: FileAccess = FileAccess.open(store.directory.path_join("a/session.bin"), FileAccess.WRITE)
	corrupt.store_buffer(PackedByteArray([1, 2, 3]))
	corrupt.close()
	assert_bool(store.load_game().is_empty()).is_true()
	assert_bool(store.last_error.is_empty()).is_false()
	_cleanup(store.directory)


func _cleanup(directory: String) -> void:
	for bank: String in ["a", "b"]:
		var path: String = directory.path_join(bank)
		var folder: DirAccess = DirAccess.open(path)
		if folder != null:
			for filename: String in folder.get_files():
				folder.remove(filename)
			DirAccess.remove_absolute(path)
	for filename: String in ["current", "current.tmp"]:
		DirAccess.remove_absolute(directory.path_join(filename))
	DirAccess.remove_absolute(directory)
