extends GdUnitTestSuite

var _session: FactorySession
var _directory: String


func before_test() -> void:
	_session = auto_free(FactorySession.new())
	_session.store.directory = OS.get_cache_dir().path_join("factory_session_%d" % Time.get_ticks_usec())
	_directory = _session.store.directory
	add_child(_session)


func after_test() -> void:
	get_tree().paused = false
	_remove_directory(_directory)


func _remove_directory(path: String) -> void:
	var folder: DirAccess = DirAccess.open(path)
	if folder == null:
		return
	for child: String in folder.get_directories():
		_remove_directory(path.path_join(child))
	for filename: String in folder.get_files():
		folder.remove(filename)
	DirAccess.remove_absolute(path)


func _key(code: Key) -> InputEventKey:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	return event


func test_menu_starts_without_game_and_escape_closes_inventory_before_pausing() -> void:
	assert_object(_session.game).is_null()
	_session.start_new()
	assert_object(_session.game).is_not_null()
	_session.game.player.handle_input(_key(KEY_I))
	_session.game.player.handle_input(_key(KEY_ESCAPE))
	assert_bool(get_tree().paused).is_false()
	assert_bool(_session.game.inventory_view.visible).is_false()
	_session.game.player.handle_input(_key(KEY_ESCAPE))
	assert_bool(get_tree().paused).is_true()
	assert_bool(_session.game.player.controls_enabled()).is_false()
	_session.game.player.handle_input(_key(KEY_I))
	_session.game.player.handle_input(_key(KEY_TAB))
	assert_bool(_session.game.inventory_view.visible).is_false()
	assert_bool(_session.game.free_camera.active).is_false()
	_session.resume_game()
	assert_bool(get_tree().paused).is_false()
	assert_bool(_session.game.player.controls_captured()).is_true()


func test_pause_stops_logistics_and_free_camera_and_preserves_view_on_resume() -> void:
	_session.start_new()
	var game: FactoryGame = _session.game
	game.world_data.place_block(Vector3i.ZERO, VoxelWorldData.Block.MINER)
	game.player.handle_input(_key(KEY_TAB))
	await get_tree().physics_frame
	_session.pause_game()
	var state: Dictionary = game.logistics_data.save_state()
	var camera_position: Vector3 = game.free_camera.global_position
	var rotation: Vector3 = game.free_camera.camera.rotation
	Input.action_press("move_forward")
	for frame: int in range(8):
		await get_tree().process_frame
	Input.action_release("move_forward")
	assert_bool(game.logistics_data.save_state() == state).is_true()
	assert_vector(game.free_camera.global_position).is_equal(camera_position)
	_session.resume_game()
	assert_bool(game.free_camera.active).is_true()
	assert_vector(game.free_camera.camera.rotation).is_equal(rotation)
	assert_bool(game.player.controls_captured()).is_false()


func test_save_return_load_restores_world_player_inventory_and_clock() -> void:
	_session.start_new()
	var game: FactoryGame = _session.game
	game.game_config = game.game_config.duplicate() as GameConfig
	game.game_config.mining_interval = 0.17
	game.game_config.mining_amount = 2
	game._apply_game_config()
	game.world_data.break_block(Vector3i(0, -1, 0))
	game.world_data.place_block(Vector3i(0, 32, 0), VoxelWorldData.Block.MINER)
	game.logistics_data.advance(0.23)
	var item: ItemDefinition = ItemDefinition.new()
	item.item_id = &"iron_ore"
	item.display_name = "Iron Ore"
	item.description = "Test ore"
	item.max_stack = 100
	game.inventory.add_item(item, 137)
	game.player.position = Vector3(2.25, 3, 4.25)
	game.player.camera.rotation = Vector3(-0.3, 0.8, 0)
	game.player.handle_input(_key(KEY_5))
	game.player.handle_input(_key(KEY_R))
	var state: Dictionary = game.save_state()
	_session.pause_game()
	assert_bool(_session.save_and_return()).is_true()
	assert_object(_session.game).is_null()
	assert_bool(get_tree().paused).is_false()
	assert_bool(_session.load_game()).is_true()
	assert_bool(_session.game.save_state() == state).is_true()
	assert_bool(_session.game.player.camera.is_current()).is_true()


func test_new_world_name_and_identity_do_not_replace_existing_snapshot() -> void:
	_session.start_new()
	_session.game.world_data.break_block(Vector3i(0, -1, 0))
	_session.pause_game()
	assert_bool(_session.save_and_return()).is_true()
	_session.menu.new_requested.emit()
	assert_object(_session.game).is_null()
	_session.menu.new_confirmed.emit("第二世界")
	assert_int(_session.game.world_data.get_block(Vector3i(0, -1, 0))).is_equal(VoxelWorldData.Block.GRASS)
	_session.pause_game()
	assert_bool(_session.load_game()).is_true()
	assert_int(_session.game.world_data.get_block(Vector3i(0, -1, 0))).is_equal(VoxelWorldData.Block.AIR)


func test_world_identity_and_name_survive_save_and_loading_an_older_snapshot() -> void:
	_session.start_new("钢铁工厂")
	var identity: String = _session.game.world_id
	_session.pause_game()
	assert_bool(_session.save_game("开始")).is_true()
	var first: String = _session.store.latest_id()
	_session.game.world_data.break_block(Vector3i(0, -1, 0))
	assert_bool(_session.save_game("后来")).is_true()
	assert_bool(_session.load_game(first)).is_true()
	assert_str(_session.game.world_id).is_equal(identity)
	assert_str(_session.game.world_name).is_equal("钢铁工厂")
	assert_int(_session.game.world_data.get_block(Vector3i(0, -1, 0))).is_equal(VoxelWorldData.Block.GRASS)
	_session.start_new("另一个工厂")
	assert_str(_session.game.world_id).is_not_equal(identity)


func test_autosave_timer_ignores_paused_time_and_rotates_each_world() -> void:
	assert_bool(_session.has_method("advance_autosave")).is_true()
	if not _session.has_method("advance_autosave"):
		return
	_session.start_new()
	_session.game.game_config = _session.game.game_config.duplicate() as GameConfig
	_session.game.game_config.set("autosave_interval_minutes", 0.01)
	_session.game.game_config.set("autosave_retention", 2)
	_session.pause_game()
	_session.call("advance_autosave", 60.0)
	assert_int((_session.store.call("list_saves") as Array).size()).is_equal(0)
	_session.resume_game()
	for number: int in range(3):
		_session.call("advance_autosave", 0.61)
	assert_int((_session.store.call("list_saves") as Array).size()).is_equal(2)


func test_failed_load_or_save_keeps_paused_live_world() -> void:
	_session.start_new()
	_session.pause_game()
	var original: FactoryGame = _session.game
	assert_bool(_session.load_game()).is_false()
	assert_bool(_session.game == original).is_true()
	assert_bool(get_tree().paused).is_true()
	_session.store.directory = "res://project.godot/save"
	assert_bool(_session.save_and_return()).is_false()
	assert_bool(_session.game == original).is_true()
	assert_bool(get_tree().paused).is_true()


func test_pause_discards_held_jump_until_release_and_next_press() -> void:
	_session.start_new()
	for frame: int in range(16):
		await get_tree().physics_frame
	var player: FactoryPlayer = _session.game.player
	var height: float = player.position.y
	_session.pause_game()
	Input.action_press("jump")
	_session.resume_game()
	for frame: int in range(8):
		await get_tree().physics_frame
	assert_float(player.position.y).is_equal_approx(height, 0.002)
	Input.action_release("jump")
	for frame: int in range(4):
		await get_tree().physics_frame
	Input.action_press("jump")
	for frame: int in range(6):
		await get_tree().physics_frame
	Input.action_release("jump")
	assert_float(player.position.y).is_greater(height + 0.1)


func test_valid_checksum_but_illegal_version_does_not_replace_paused_game() -> void:
	_session.start_new()
	_session.pause_game()
	assert_bool(_session.save_game()).is_true()
	var original: FactoryGame = _session.game
	var manifest: Dictionary = original.save_state()
	manifest["version"] = 99
	manifest["chunks"] = []
	var bytes: PackedByteArray = var_to_bytes(manifest)
	var hash: HashingContext = HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	var records: Array = _session.store.call("list_saves")
	var path: String = _directory.path_join("snapshots").path_join(records[0]["payload"]).path_join("a/session.bin")
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_32(SaveGameStore.MAGIC)
	file.store_32(bytes.size())
	file.store_buffer(hash.finish())
	file.store_buffer(bytes.compress(FileAccess.COMPRESSION_DEFLATE))
	file.close()
	assert_bool(_session.load_game()).is_false()
	assert_bool(_session.game == original).is_true()
	assert_bool(get_tree().paused).is_true()
