extends GdUnitTestSuite

const Replay = preload("res://tests/support/logistics_replay.gd")
const Reference = preload("res://tests/support/logistics_t03_reference.gd")
const STEP: float = LogisticsData.LOGIC_STEP


func test_real_files_legacy_and_current_formats_keep_pending_transport_after_scene_adoption() -> void:
	for version: int in [1, 2, 3, 4]:
		for packed: bool in ([false, true] if version == 4 else [false]):
			var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
			var game: FactoryGame = auto_free(scene.instantiate()) as FactoryGame
			add_child(game)
			_pause_updates(game)
			game.logistics_data.configure_miners(0.05, 2)
			for x: int in range(-1, 5):
				var block: int = VoxelWorldData.Block.MINER if x == -1 else (
					VoxelWorldData.Block.CHEST if x == 4 else VoxelWorldData.Block.BELT)
				var cell: Vector3i = Vector3i(x, 0, 0)
				game.world_data.place_block(cell, block)
				game.logistics_data.set_direction(cell, Vector3i.RIGHT)
			game.logistics_data.advance(0.2)
			assert_bool(game.logistics_data.enable_transport_lines()).is_true()
			game.logistics_data.advance(0.213)
			game.logistics_data.set_direction(Vector3i.RIGHT, Vector3i.BACK)
			var before: Dictionary = game.logistics_data.save_state()
			var state: Dictionary = game.save_state(packed)
			state["version"] = version
			if version == 1:
				state.erase("structures")
			var store: SaveGameStore = SaveGameStore.new()
			store.directory = OS.get_cache_dir().path_join("factory_line_save_%d" % Time.get_ticks_usec())
			assert_bool(store.save_game(state)).is_true()
			var before_decodes: int = store.snapshot_decodes
			var snapshot: SessionSnapshot = store.load_snapshot()
			assert_int(store.snapshot_decodes - before_decodes).is_equal(1)
			assert_object(snapshot).is_not_null()
			if snapshot != null:
				assert_bool(snapshot.logistics.enable_transport_lines()).is_true()
				_compare(snapshot.logistics.save_state(), before)
				var loaded: FactoryGame = auto_free(scene.instantiate()) as FactoryGame
				loaded.initial_snapshot = snapshot
				add_child(loaded)
				_pause_updates(loaded)
				assert_object(loaded.initial_snapshot).is_null()
				assert_object(loaded.logistics_data).is_same(snapshot.logistics)
				var reference: RefCounted = Reference.new()
				reference.call("bind_world", game.world_data)
				assert_bool(reference.call("restore_state", before)).is_true()
				for tick: int in range(120):
					game.logistics_data.advance(STEP)
					loaded.logistics_data.advance(STEP)
					reference.call("advance", STEP)
					_compare(game.logistics_data.save_state(), reference.call("save_state"))
					_compare(loaded.logistics_data.save_state(), reference.call("save_state"))
				assert_int(loaded.logistics_data.work_stats()["pure_segment_count"]).is_greater(0)
			_cleanup(store.directory)


func _pause_updates(game: FactoryGame) -> void:
	game.set_physics_process(false)
	game.set_process(false)
	game.player.set_physics_process(false)
	game.logistics_view.set_process(false)


func _compare(left: Dictionary, right: Dictionary) -> void:
	var difference: Dictionary = Replay.first_difference(
		Replay.canonical_state(left), Replay.canonical_state(right))
	assert_bool(difference.is_empty()).override_failure_message(var_to_str(difference)).is_true()


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
