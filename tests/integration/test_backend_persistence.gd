extends GdUnitTestSuite
## Real native checkpoints: UI/session handoff, failure isolation and continuation.

var _game: Node3D
var _root: String


func before(_do_skip: bool = not ClassDB.class_exists(&"FactoryBackend"),
		_skip_reason: String = "Install FactoryBackend to validate native checkpoints.") -> void:
	pass


func before_test() -> void:
	_root = "user://test_backend_" + SaveGameStore.new_id()
	var scene: PackedScene = load("res://scenes/factory_playground.tscn") as PackedScene
	_game = auto_free(scene.instantiate()) as Node3D
	_game.set("background_runtime", false)
	_game.set("save_root", _root)
	add_child(_game)
	_game.set_physics_process(false)
	_game.set_process(false)
	var player: FactoryPlayer = _game.get("player") as FactoryPlayer
	player.set_physics_process(false)
	await _settle()


func after_test() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var directory: DirAccess = DirAccess.open(_root)
	if directory != null:
		for file: String in directory.get_files():
			directory.remove(file)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_root))


func _settle() -> void:
	for frame: int in range(600):
		_game.call("poll_persistence")
		if _game.get("_job_id") == 0:
			return
		await get_tree().process_frame
	assert_int(_game.get("_job_id")).is_equal(0)


func test_both_rules_restore_player_world_and_continue_identically() -> void:
	for ruleset: String in ["legacy_discrete_v1", "conveyor_continuous_v1"]:
		_game.call("start_factory", ruleset)
		var player: FactoryPlayer = _game.get("player") as FactoryPlayer
		player.position = Vector3(1.25, 3.0, -2.5)
		player.velocity = Vector3(0.5, -1.25, 0.75)
		player.spawn_position = Vector3(2.5, 0.05, 3.5)
		player.camera.rotation = Vector3(-0.5, 0.8, 0)
		_game.call("_select", VoxelWorldData.Block.BELT_UP)
		_game.set("_facing", 3)
		if not _game.get("free_view"):
			_game.call("_toggle_view")
		var camera: Camera3D = _game.get("_free_camera") as Camera3D
		camera.position = Vector3(3, 8, 4)
		camera.rotation = Vector3(-0.7, 0.4, 0)
		_game.call("advance", 2.15)
		_game.call("save_game", "往返", false)
		await _settle()
		var records: Array = _game.get("_save_records")
		assert_int(records.size()).is_equal(1)
		if records.is_empty():
			return
		var checkpoint: Dictionary = _game.call("snapshot")
		_game.call("advance", 3.25)
		var expected: Dictionary = _game.call("snapshot")
		player.position = Vector3.ZERO
		player.velocity = Vector3.ZERO
		_game.call("load_game", records[0].id)
		await _settle()
		var actual: Dictionary = _game.call("snapshot")
		assert_int(actual.tick).is_equal(checkpoint.tick)
		assert_vector(player.position).is_equal(Vector3(1.25, 3.0, -2.5))
		assert_vector(player.velocity).is_equal(Vector3(0.5, -1.25, 0.75))
		assert_vector(player.spawn_position).is_equal(Vector3(2.5, 0.05, 3.5))
		assert_vector(player.camera.rotation).is_equal(Vector3(-0.5, 0.8, 0))
		assert_int(_game.get("_selected")).is_equal(VoxelWorldData.Block.BELT_UP)
		assert_int(_game.get("_facing")).is_equal(3)
		assert_bool(_game.get("free_view")).is_true()
		assert_vector(camera.position).is_equal(Vector3(3, 8, 4))
		_game.call("set_paused", false)
		# Manually driven scene: keep physics disabled after resuming.
		player.set_physics_process(false)
		_game.call("advance", 3.25)
		actual = _game.call("snapshot")
		assert_int(actual.tick).is_equal(expected.tick)
		assert_int(actual.produced).is_equal(expected.produced)
		assert_array(actual.machines).is_equal(expected.machines)
		assert_array(Array(actual.ores)).is_equal(Array(expected.ores))
		_game.call("delete_save", records[0].id)
		await _settle()


func test_corrupt_payload_preserves_active_world_and_collision_nodes() -> void:
	_game.call("save_game", "损坏保护", false)
	await _settle()
	var records: Array = _game.get("_save_records")
	assert_int(records.size()).is_equal(1)
	if records.is_empty():
		return
	var before: Dictionary = _game.call("snapshot")
	var world: Node3D = _game.get("_world_view") as Node3D
	var identity: int = world.get_instance_id()
	var payload: String = ""
	for name: String in DirAccess.get_files_at(_root):
		if name.ends_with(".pfs"):
			payload = name
	assert_str(payload).is_not_empty()
	var file: FileAccess = FileAccess.open(_root.path_join(payload), FileAccess.WRITE)
	assert_object(file).is_not_null()
	if file == null:
		return
	file.store_buffer(PackedByteArray([1, 2, 3]))
	file.close()
	_game.call("load_game", records[0].id)
	await _settle()
	assert_int((_game.get("_world_view") as Node3D).get_instance_id()).is_equal(identity)
	assert_int((_game.call("snapshot") as Dictionary).tick).is_equal(before.tick)
	assert_bool(_game.get("ready_for_play")).is_true()
	assert_bool(_game.get("_paused")).is_false()


func test_auto_retention_and_file_panel_return_keep_backend_menu() -> void:
	_game.set("autosave_minutes", 0.01)
	_game.set("autosave_retention", 2)
	for index: int in range(3):
		_game.call("advance_autosave", 0.7)
		await _settle()
	var records: Array = _game.get("_save_records")
	assert_int(records.size()).is_equal(2)
	for record: Dictionary in records:
		assert_str(record.kind).is_equal("auto")
	_game.call("set_paused", true)
	_game.call("open_save_files", true)
	await _settle()
	var menu: SessionMenu = _game.find_child("SessionMenu", true, false) as SessionMenu
	assert_bool(menu.close_panel()).is_true()
	assert_bool((menu.get("_pause_save") as Button).disabled).is_false()
	assert_bool((menu.get("_transport") as OptionButton).visible).is_true()


func test_exit_save_blocks_resume_until_terminal() -> void:
	_game.call("set_paused", true)
	_game.call("save_and_return")
	assert_int(_game.get("_job_id")).is_greater(0)
	_game.call("set_paused", false)
	# Claim the real result as an ordinary save to avoid replacing the test scene.
	_game.set("_job_operation", "save")
	assert_bool(_game.get("_paused")).is_true()
	await _settle()


func test_failed_save_does_not_later_report_success() -> void:
	_game.set("_save_sequence", 999)
	_game.call("save_game", "序列过期", false)
	await _settle()
	_game.call("open_save_files", false)
	await _settle()
	var menu: SessionMenu = _game.find_child("SessionMenu", true, false) as SessionMenu
	assert_str((menu.get("_message") as Label).text).not_contains("保存完成")


func test_exit_save_confirms_manual_name_collision() -> void:
	_game.call("save_game", "退出存档", false)
	await _settle()
	_game.call("set_paused", true)
	_game.call("save_and_return")
	var menu: SessionMenu = _game.find_child("SessionMenu", true, false) as SessionMenu
	var pending: int = _game.get("_job_id")
	if pending != 0:
		_game.set("_job_operation", "save")
		await _settle()
	assert_bool(menu.confirmation_visible()).is_true()
	assert_int(pending).is_equal(0)
	menu.close_panel()
