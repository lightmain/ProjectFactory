extends GdUnitTestSuite


func test_multiblock_file_roundtrip_retains_identity_rotation_and_whole_removal() -> void:
	var game: FactoryGame = auto_free(load("res://scenes/main.tscn").instantiate()) as FactoryGame
	add_child(game)
	game.set_physics_process(false)
	game.player.set_physics_process(false)
	game.world_data.place_structure(Vector3i(0, 27, 0), 3)
	game.selected_block = VoxelWorldData.Block.STRUCTURE
	var identity: Dictionary = game.world_data.structure_at(Vector3i(-1, 27, -1))
	var store: SaveGameStore = SaveGameStore.new()
	store.directory = OS.get_cache_dir().path_join("factory_save_test_%d" % Time.get_ticks_usec())
	assert_bool(store.save_game(game.save_state())).is_true()
	var snapshot: SessionSnapshot = SessionSnapshot.decode(store.load_game())
	assert_object(snapshot).is_not_null()
	if snapshot != null:
		assert_int(snapshot.selected_block).is_equal(VoxelWorldData.Block.STRUCTURE)
		assert_dict(snapshot.world.structure_at(Vector3i(1, 29, 1))).is_equal(identity)
		assert_bool(snapshot.world.break_block(Vector3i(1, 29, 1))).is_true()
		assert_bool(snapshot.world.structure_rows().is_empty()).is_true()
		assert_int(snapshot.world.chunk_deltas().size()).is_equal(0)
	_cleanup(store.directory)


func test_snapshot_rejects_orphan_missing_overlap_and_bad_structure_records() -> void:
	var game: FactoryGame = auto_free(load("res://scenes/main.tscn").instantiate()) as FactoryGame
	add_child(game)
	game.world_data.place_structure(Vector3i.ZERO)
	var state: Dictionary = game.save_state()
	assert_object(SessionSnapshot.decode(state)).is_not_null()
	for rows: Array in [
		[], [{"id": 1, "anchor": Vector3i.ZERO, "block": 8, "rotation": 4}],
		[{"id": 1, "anchor": Vector3i(1, 0, 0), "block": 8, "rotation": 0}],
		[{"id": 1, "anchor": Vector3i.ZERO, "block": 8, "rotation": 0},
		{"id": 2, "anchor": Vector3i.ZERO, "block": 8, "rotation": 0}],
	]:
		var invalid: Dictionary = state.duplicate(true)
		invalid["structures"] = rows
		assert_object(SessionSnapshot.decode(invalid)).is_null()
	var missing: Dictionary = state.duplicate(true)
	missing["chunks"] = {}
	assert_object(SessionSnapshot.decode(missing)).is_null()
	var absent: Dictionary = state.duplicate(true)
	absent.erase("structures")
	assert_object(SessionSnapshot.decode(absent)).is_null()


func test_version_one_without_structures_still_loads() -> void:
	var game: FactoryGame = auto_free(load("res://scenes/main.tscn").instantiate()) as FactoryGame
	add_child(game)
	var state: Dictionary = game.save_state()
	state["version"] = 1
	state.erase("structures")
	assert_object(SessionSnapshot.decode(state)).is_not_null()


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
