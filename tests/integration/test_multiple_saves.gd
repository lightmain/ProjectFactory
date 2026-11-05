extends GdUnitTestSuite

var _store: SaveGameStore
var _game: FactoryGame


func before_test() -> void:
	_store = SaveGameStore.new()
	_store.directory = OS.get_cache_dir().path_join("factory_catalog_%d" % Time.get_ticks_usec())
	_game = auto_free(load("res://scenes/main.tscn").instantiate()) as FactoryGame
	add_child(_game)
	_game.set_physics_process(false)
	_game.player.set_physics_process(false)


func after_test() -> void:
	_remove_directory(_store.directory)


func _state(world_id: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", world_name: String = "工厂") -> Dictionary:
	var state: Dictionary = _game.save_state()
	state["world_id"] = world_id
	state["world_name"] = world_name
	return state


func test_named_snapshots_are_independent_and_latest_survives_restart() -> void:
	# This public capability must exist before the old single-slot store can satisfy this test.
	assert_bool(_store.has_method("save_named")).is_true()
	if not _store.has_method("save_named"):
		return
	assert_bool(_store.call("save_named", _state(), "开局")).is_true()
	_game.world_data.break_block(Vector3i(0, -1, 0))
	assert_bool(_store.call("save_named", _state(), "挖矿之后")).is_true()
	var restarted: SaveGameStore = SaveGameStore.new()
	restarted.directory = _store.directory
	var saves: Array = restarted.call("list_saves")
	assert_int(saves.size()).is_equal(2)
	var latest: String = restarted.call("latest_id")
	var last: Dictionary = restarted.call("load_named", latest)
	var first: Dictionary = restarted.call("load_named", saves[1]["id"])
	assert_int(SessionSnapshot.decode(last).world.get_block(Vector3i(0, -1, 0))).is_equal(VoxelWorldData.Block.AIR)
	assert_int(SessionSnapshot.decode(first).world.get_block(Vector3i(0, -1, 0))).is_equal(VoxelWorldData.Block.GRASS)


func test_duplicate_requires_overwrite_and_failed_index_commit_preserves_snapshot() -> void:
	assert_bool(_store.has_method("save_named")).is_true()
	if not _store.has_method("save_named"):
		return
	assert_bool(_store.call("save_named", _state(), "../同名")).is_true()
	_game.world_data.break_block(Vector3i(0, -1, 0))
	assert_bool(_store.call("save_named", _state(), "../同名")).is_false()
	DirAccess.make_dir_absolute(_store.directory.path_join("index.tmp"))
	assert_bool(_store.call("save_named", _state(), "../同名", true)).is_false()
	var original: Dictionary = _store.call("load_named", _store.call("latest_id"))
	assert_int(SessionSnapshot.decode(original).world.get_block(Vector3i(0, -1, 0))).is_equal(VoxelWorldData.Block.GRASS)
	assert_bool(_store.call("delete_save", _store.call("latest_id"))).is_false()
	DirAccess.remove_absolute(_store.directory.path_join("index.tmp"))
	assert_bool(_store.call("save_named", _state(), "../同名", true)).is_true()
	var saves: Array = _store.call("list_saves")
	assert_int(saves.size()).is_equal(1)
	var overwritten: Dictionary = _store.call("load_named", saves[0]["id"])
	assert_int(SessionSnapshot.decode(overwritten).world.get_block(Vector3i(0, -1, 0))).is_equal(VoxelWorldData.Block.AIR)
	assert_bool(_store.call("delete_save", saves[0]["id"])).is_true()
	assert_int((_store.call("list_saves") as Array).size()).is_equal(0)


func test_automatic_rotation_is_per_world_and_preserves_manual_saves_on_failure() -> void:
	assert_bool(_store.has_method("save_named")).is_true()
	if not _store.has_method("save_named"):
		return
	assert_bool(_store.call("save_named", _state(), "手动")).is_true()
	for number: int in range(3):
		assert_bool(_store.call("save_named", _state(), "自动%d" % number, false, "auto", 2)).is_true()
	var other: Dictionary = _state("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "第二世界")
	assert_bool(_store.call("save_named", other, "另一世界", false, "auto", 2)).is_true()
	var saves: Array = _store.call("list_saves")
	assert_int(saves.size()).is_equal(4)
	assert_str(saves[3]["name"]).is_equal("手动")
	DirAccess.make_dir_absolute(_store.directory.path_join("index.tmp"))
	assert_bool(_store.call("save_named", _state(), "写入失败", false, "auto", 2)).is_false()
	assert_int((_store.call("list_saves") as Array).size()).is_equal(4)


func test_legacy_name_overwrite_requires_confirmation_and_does_not_leave_duplicate_rows() -> void:
	assert_bool(_store.save_game(_state())).is_true()
	assert_bool(_store.save_named(_state(), "旧世界存档")).is_false()
	assert_bool(_store.save_named(_state(), "旧世界存档", true)).is_true()
	assert_int(_store.list_saves().size()).is_equal(1)


func test_duplicate_payload_in_valid_checksum_index_is_rejected_before_deletion() -> void:
	assert_bool(_store.save_named(_state(), "原始")).is_true()
	var catalog: Dictionary = _store._read_catalog()
	var records: Array = catalog["saves"]
	var duplicate: Dictionary = records[0].duplicate(true)
	duplicate["id"] = SaveGameStore.new_id()
	duplicate["name"] = "非法别名"
	duplicate["sequence"] = 2
	catalog["sequence"] = 2
	records.append(duplicate)
	assert_bool(_store._commit_catalog(catalog)).is_true()
	assert_bool(_store.delete_save(duplicate["id"])).is_false()
	assert_bool(_store.list_saves().is_empty()).is_true()
	assert_bool(_store.last_error.is_empty()).is_false()


func _remove_directory(path: String) -> void:
	var folder: DirAccess = DirAccess.open(path)
	if folder == null:
		return
	for child: String in folder.get_directories():
		_remove_directory(path.path_join(child))
	for filename: String in folder.get_files():
		folder.remove(filename)
	DirAccess.remove_absolute(path)
