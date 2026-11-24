extends GdUnitTestSuite


func test_phase_observer_keeps_disk_validation_and_balances_failed_reads() -> void:
	var store: SaveGameStore = SaveGameStore.new()
	assert_bool("phase_observer" in store).is_true()
	if not "phase_observer" in store:
		return
	var events: Array[String] = []
	store.set("phase_observer", func(phase: String, entering: bool) -> void:
		events.append(("+" if entering else "-") + phase))
	store.directory = OS.get_cache_dir().path_join("factory_phase_test_%d" % Time.get_ticks_usec())
	var state: Dictionary = PressureSaveBuilder.state_for(PressureSaveBuilder.new().build(8, 6))
	assert_bool(store.save_game(state)).is_true()
	assert_int(store.snapshot_decodes).is_equal(0)
	assert_int(events.count("+snapshot_decode")).is_equal(0)
	assert_int(events.count("+world_restore")).is_equal(0)
	assert_int(events.count("+default_logistics_bind")).is_equal(0)
	assert_int(events.count("+logistics_restore")).is_equal(0)
	assert_int(events.count("+compress")).is_greater(0)
	assert_int(events.count("+disk_read")).is_greater(0)
	_assert_balanced_phases(events)
	events.clear()
	var loaded: SessionSnapshot = store.load_snapshot()
	assert_object(loaded).is_not_null()
	assert_bool(PressureSaveBuilder.state_for(loaded) == state).is_true()
	assert_int(events.count("+snapshot_decode")).is_equal(1)
	_assert_balanced_phases(events)
	events.clear()
	var corrupt: FileAccess = FileAccess.open(store.directory.path_join("a/session.bin"), FileAccess.WRITE)
	corrupt.store_buffer(PackedByteArray([1, 2, 3]))
	corrupt.close()
	assert_object(store.load_snapshot()).is_null()
	assert_int(events.count("+disk_read")).is_equal(1)
	assert_int(events.count("+snapshot_decode")).is_equal(0)
	_assert_balanced_phases(events)
	_cleanup(store.directory)


func test_named_save_kinds_and_overwrite_do_not_reconstruct_factory() -> void:
	var store: SaveGameStore = SaveGameStore.new()
	store.directory = OS.get_cache_dir().path_join("factory_named_no_restore_%d" % Time.get_ticks_usec())
	var state: Dictionary = PressureSaveBuilder.state_for(PressureSaveBuilder.new().build(8, 6))
	for kind: String in ["manual", "auto", "exit"]:
		assert_bool(store.save_named(state, kind, false, kind)).is_true()
	assert_bool(store.save_named(state, "manual", true)).is_true()
	assert_int(store.snapshot_decodes).is_equal(0)
	var records: Array[Dictionary] = store.list_saves()
	assert_int(records.size()).is_equal(3)
	for record: Dictionary in records:
		var loaded: SessionSnapshot = store.load_named_snapshot(record["id"])
		assert_object(loaded).is_not_null()
		if loaded != null:
			assert_bool(PressureSaveBuilder.state_for(loaded) == state).is_true()
	assert_int(store.snapshot_decodes).is_equal(3)
	SaveGameFiles.remove_directory(store.directory)


func test_save_defers_logistics_semantic_validation_until_load() -> void:
	var store: SaveGameStore = SaveGameStore.new()
	store.directory = OS.get_cache_dir().path_join("factory_deferred_validation_%d" % Time.get_ticks_usec())
	var state: Dictionary = PressureSaveBuilder.state_for(PressureSaveBuilder.new().build(8, 6))
	var logistics: Dictionary = state["logistics"]
	logistics["tick"] = -1
	assert_bool(store.save_game(state)).is_true()
	assert_int(store.snapshot_decodes).is_equal(0)
	assert_object(store.load_snapshot()).is_null()
	assert_int(store.snapshot_decodes).is_equal(1)
	assert_bool(store.last_error.is_empty()).is_false()
	_cleanup(store.directory)


func test_readback_corruption_prevents_committing_new_generation() -> void:
	var store: SaveGameStore = SaveGameStore.new()
	store.directory = OS.get_cache_dir().path_join("factory_readback_failure_%d" % Time.get_ticks_usec())
	var state: Dictionary = PressureSaveBuilder.state_for(PressureSaveBuilder.new().build(8, 6))
	assert_bool(store.save_game(state)).is_true()
	var reads: Array[int] = [0]
	store.phase_observer = func(phase: String, entering: bool) -> void:
		if phase == "disk_read" and entering:
			reads[0] += 1
			if reads[0] == 1:
				var corrupt: FileAccess = FileAccess.open(
					store.directory.path_join("b/session.bin"), FileAccess.WRITE)
				corrupt.store_buffer(PackedByteArray([1, 2, 3]))
				corrupt.close()
	assert_bool(store.save_game(state)).is_false()
	assert_int(reads[0]).is_greater(0)
	assert_int(store.snapshot_decodes).is_equal(0)
	store.phase_observer = Callable()
	var loaded: SessionSnapshot = store.load_snapshot()
	assert_object(loaded).is_not_null()
	if loaded != null:
		assert_bool(PressureSaveBuilder.state_for(loaded) == state).is_true()
	_cleanup(store.directory)


func test_invalid_write_chunks_leave_previous_generation_loadable() -> void:
	var store: SaveGameStore = SaveGameStore.new()
	store.directory = OS.get_cache_dir().path_join("factory_invalid_write_chunks_%d" % Time.get_ticks_usec())
	var state: Dictionary = PressureSaveBuilder.state_for(PressureSaveBuilder.new().build(8, 6))
	assert_bool(store.save_game(state)).is_true()
	for chunks: Variant in [
		null, [], {"../outside": PackedByteArray([0, 0, 1])},
		{Vector3i(-1, 0, 0): PackedByteArray([0, 0, 1])},
		{Vector3i(4, 0, 0): PackedByteArray([0, 0, 1])},
		{Vector3i.ZERO: []}, {Vector3i.ZERO: PackedByteArray()},
		{Vector3i.ZERO: PackedByteArray([0, 0])},
	]:
		var invalid: Dictionary = state.duplicate(true)
		invalid["chunks"] = chunks
		assert_bool(store.save_game(invalid)).is_false()
	assert_int(store.snapshot_decodes).is_equal(0)
	var loaded: SessionSnapshot = store.load_snapshot()
	assert_object(loaded).is_not_null()
	if loaded != null:
		assert_bool(PressureSaveBuilder.state_for(loaded) == state).is_true()
	_cleanup(store.directory)


func test_readback_checksum_and_missing_chunk_preserve_previous_generation() -> void:
	for damage: String in ["session_checksum", "chunk_checksum", "missing_chunk"]:
		var store: SaveGameStore = SaveGameStore.new()
		store.directory = OS.get_cache_dir().path_join(
			"factory_readback_%s_%d" % [damage, Time.get_ticks_usec()])
		var state: Dictionary = PressureSaveBuilder.state_for(PressureSaveBuilder.new().build(8, 6))
		assert_bool(store.save_game(state)).is_true()
		var chunks: Dictionary = state["chunks"]
		var keys: Array = chunks.keys()
		assert_bool(keys.is_empty()).is_false()
		var chunk: Vector3i = keys[0]
		var filename: String = "session.bin" if damage == "session_checksum" else (
			"chunk_%d_%d_%d.bin" % [chunk.x, chunk.y, chunk.z])
		var target: String = store.directory.path_join("b").path_join(filename)
		var reads: Array[int] = [0]
		store.phase_observer = func(phase: String, entering: bool) -> void:
			if phase == "disk_read" and entering:
				reads[0] += 1
				if reads[0] == 1:
					if damage == "missing_chunk":
						assert_int(DirAccess.remove_absolute(target)).is_equal(OK)
					else:
						var file: FileAccess = FileAccess.open(target, FileAccess.READ_WRITE)
						file.seek(8)
						var checksum_byte: int = file.get_8()
						file.seek(8)
						file.store_8(checksum_byte ^ 1)
						file.close()
		assert_bool(store.save_game(state)).is_false()
		assert_int(store.snapshot_decodes).is_equal(0)
		assert_bool(store.last_error.is_empty()).is_false()
		store.phase_observer = Callable()
		var loaded: SessionSnapshot = store.load_snapshot()
		assert_object(loaded).is_not_null()
		if loaded != null:
			assert_bool(PressureSaveBuilder.state_for(loaded) == state).is_true()
		_cleanup(store.directory)


func _assert_balanced_phases(events: Array[String]) -> void:
	var stack: Array[String] = []
	for event: String in events:
		if event.begins_with("+"):
			stack.append(event.substr(1))
		else:
			assert_bool(stack.is_empty()).is_false()
			if not stack.is_empty():
				assert_str(stack.pop_back()).is_equal(event.substr(1))
	assert_array(stack).is_empty()


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
