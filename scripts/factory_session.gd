class_name FactorySession
extends Node
## The always-running session owns a pausable world and named snapshots.

const GAME_SCENE: PackedScene = preload("res://scenes/main.tscn")

var game: FactoryGame
var store: SaveGameStore = SaveGameStore.new()
var menu: SessionMenu
var _capture_before_pause: bool = false
var _autosave_seconds: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var layer: CanvasLayer = CanvasLayer.new()
	layer.name = "SessionInterface"
	layer.layer = 10
	add_child(layer)
	menu = SessionMenu.new()
	menu.name = "SessionMenu"
	layer.add_child(menu)
	menu.new_requested.connect(_request_new)
	menu.new_confirmed.connect(start_new)
	menu.continue_requested.connect(func() -> void: load_game())
	menu.load_requested.connect(_open_load)
	menu.load_confirmed.connect(func(save_id: String) -> void: load_game(save_id))
	menu.resume_requested.connect(resume_game)
	menu.save_requested.connect(_open_save)
	menu.save_confirmed.connect(func(save_name: String, overwrite: bool) -> void: save_game(save_name, overwrite))
	menu.delete_confirmed.connect(_delete_save)
	menu.return_requested.connect(save_and_return)
	menu.quit_requested.connect(func() -> void: get_tree().quit())
	_show_menu()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _exit_tree() -> void:
	get_tree().paused = false


func _input(event: InputEvent) -> void:
	if game != null and get_tree().paused and event.is_action_pressed("toggle_mouse") and not event.is_echo():
		if not menu.close_panel():
			resume_game()
		get_viewport().set_input_as_handled()
	elif game == null and event.is_action_pressed("toggle_mouse") and not event.is_echo():
		menu.close_panel()
		get_viewport().set_input_as_handled()


func _request_new() -> void:
	menu.show_name()


func start_new(world_name: String = "新世界") -> void:
	world_name = world_name.strip_edges()
	if world_name.is_empty() or world_name.length() > 80:
		menu.set_message("请输入世界名称，最多 80 字。")
		return
	_mount_game(null)
	game.world_name = world_name


func _process(delta: float) -> void:
	advance_autosave(delta)


func advance_autosave(delta: float) -> void:
	if game == null or get_tree().paused:
		return
	var interval: float = game.game_config.autosave_interval_minutes * 60.0
	var retention: int = game.game_config.autosave_retention
	if not is_finite(interval) or interval <= 0.0 or retention < 1:
		return
	_autosave_seconds += delta
	if _autosave_seconds < interval:
		return
	_autosave_seconds = 0.0
	var save_name: String = "%s_自动_%s" % [_default_save_name(), SaveGameStore.new_id().substr(0, 6)]
	if not store.save_named(game.save_state(), save_name, false, "auto", retention):
		game.hud.show_build_notice("自动保存失败：" + store.last_error)


func _show_menu() -> void:
	var has_save: bool = not store.latest_id().is_empty()
	menu.show_menu(game != null, has_save, "" if game == null else game.world_name)
	if not store.last_error.is_empty():
		menu.set_message(store.last_error, true)


func _open_load() -> void:
	menu.show_files(false, store.list_saves())
	if not store.last_error.is_empty():
		menu.set_message(store.last_error, true)


func _open_save() -> void:
	if game == null:
		return
	menu.show_files(true, store.list_saves(), _default_save_name())
	if not store.last_error.is_empty():
		menu.set_message(store.last_error, true)


func _default_save_name() -> String:
	var timestamp: String = Time.get_datetime_string_from_system().replace("-", "").replace(":", "").replace("T", "")
	return game.world_name + "_" + timestamp


func _delete_save(save_id: String) -> void:
	if not store.delete_save(save_id):
		menu.set_message(store.last_error, true)
		return
	menu.replace_records(store.list_saves())
	menu.set_message("存档已删除。")


func pause_game() -> void:
	if game == null or get_tree().paused:
		return
	_capture_before_pause = game.player.controls_captured()
	game.player.set_session_paused(true)
	game.free_camera.set_input_enabled(false)
	get_tree().paused = true
	_show_menu()


func resume_game() -> void:
	if game == null or not get_tree().paused:
		return
	menu.hide()
	game.player.set_session_paused(false)
	game.player.set_controls_captured(_capture_before_pause)
	game.free_camera.set_input_enabled(game.player.controls_enabled())
	get_tree().paused = false


func save_game(save_name: String = "", overwrite: bool = false) -> bool:
	if game == null:
		return false
	if save_name.is_empty():
		save_name = _default_save_name()
	if not store.save_named(game.save_state(), save_name, overwrite):
		menu.set_message(store.last_error, true)
		return false
	_show_menu()
	menu.set_message("游戏已保存。")
	return true


func load_game(save_id: String = "") -> bool:
	if save_id.is_empty():
		save_id = store.latest_id()
	var snapshot: SessionSnapshot = SessionSnapshot.decode(store.load_named(save_id))
	if snapshot == null:
		menu.set_message(store.last_error if not store.last_error.is_empty() else "存档内容无效。", true)
		return false
	_mount_game(snapshot)
	return true


func save_and_return(overwrite_manual: bool = false) -> bool:
	if game == null:
		return false
	if not overwrite_manual:
		for record: Dictionary in store.list_saves():
			if record["name"] == "退出存档" and record["kind"] != "exit":
				menu.confirm_overwrite("退出存档", func() -> void: save_and_return(true))
				return false
	if not store.save_named(game.save_state(), "退出存档", true, "exit"):
		menu.set_message(store.last_error, true)
		return false
	_remove_game()
	_show_menu()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	return true


func _mount_game(snapshot: SessionSnapshot) -> void:
	_remove_game()
	_autosave_seconds = 0.0
	game = GAME_SCENE.instantiate() as FactoryGame
	game.name = "WorldSession"
	game.process_mode = Node.PROCESS_MODE_PAUSABLE
	game.initial_snapshot = snapshot
	add_child(game)
	game.player.pause_requested.connect(pause_game)
	menu.hide()
	game.player.set_controls_captured(true)


func _remove_game() -> void:
	get_tree().paused = false
	if game != null:
		remove_child(game)
		game.free()
		game = null
