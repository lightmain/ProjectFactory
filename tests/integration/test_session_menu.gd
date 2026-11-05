extends GdUnitTestSuite

var _session: FactorySession


func before_test() -> void:
	_session = auto_free(FactorySession.new())
	_session.store.directory = OS.get_cache_dir().path_join("factory_menu_%d" % Time.get_ticks_usec())
	add_child(_session)


func after_test() -> void:
	get_tree().paused = false
	await get_tree().process_frame
	SaveGameStore._remove_directory(_session.store.directory)


func test_pause_menu_has_no_world_rename_entry() -> void:
	_session.start_new("钢铁工厂")
	_session.pause_game()
	assert_object(_button("改名")).is_null()
	assert_object(_button("继续  [Esc]")).is_not_null()
	assert_object(_button("保存游戏")).is_not_null()
	assert_str(_session.game.world_name).is_equal("钢铁工厂")


func test_new_game_requires_name_and_main_continue_loads_latest_snapshot() -> void:
	_button("新游戏").pressed.emit()
	assert_object(_session.game).is_null()
	var name_edit: LineEdit = _session.menu.find_child("WorldName", true, false) as LineEdit
	name_edit.text = "铜矿工厂"
	_button("确认").pressed.emit()
	assert_str(_session.game.world_name).is_equal("铜矿工厂")
	_session.pause_game()
	assert_bool(_session.save_game("开局")).is_true()
	_session.game.world_data.break_block(Vector3i(0, -1, 0))
	assert_bool(_session.save_and_return()).is_true()
	_button("继续").pressed.emit()
	assert_int(_session.game.world_data.get_block(Vector3i(0, -1, 0))).is_equal(VoxelWorldData.Block.AIR)


func test_default_save_name_row_selection_and_confirmed_overwrite() -> void:
	_session.start_new("钢铁")
	_session.pause_game()
	_button("保存游戏").pressed.emit()
	var name_edit: LineEdit = _session.menu.find_child("SaveName", true, false) as LineEdit
	assert_bool(name_edit.text.begins_with("钢铁_")).is_true()
	assert_int(name_edit.text.length()).is_equal(17)
	name_edit.text = "生产线"
	_button("确认").pressed.emit()
	assert_int(_session.store.list_saves().size()).is_equal(1)
	_session.game.world_data.break_block(Vector3i(0, -1, 0))
	_button("保存游戏").pressed.emit()
	_row("生产线").pressed.emit()
	assert_str(name_edit.text).is_equal("生产线")
	_button("确认").pressed.emit()
	assert_bool(_session.menu.confirmation_visible()).is_true()
	var old: Dictionary = _session.store.load_named(_session.store.latest_id())
	assert_int(SessionSnapshot.decode(old).world.get_block(Vector3i(0, -1, 0))).is_equal(VoxelWorldData.Block.GRASS)
	_confirm_dialog()
	assert_int(_session.store.list_saves().size()).is_equal(1)
	var updated: Dictionary = _session.store.load_named(_session.store.latest_id())
	assert_int(SessionSnapshot.decode(updated).world.get_block(Vector3i(0, -1, 0))).is_equal(VoxelWorldData.Block.AIR)


func test_single_click_requires_confirm_and_double_click_loads_immediately() -> void:
	_session.start_new()
	_session.pause_game()
	_session.save_game("原始")
	var original: FactoryGame = _session.game
	original.world_data.break_block(Vector3i(0, -1, 0))
	_button("载入游戏").pressed.emit()
	_row("原始").pressed.emit()
	assert_bool(_session.game == original).is_true()
	assert_bool(get_tree().paused).is_true()
	_button("确认").pressed.emit()
	assert_int(_session.game.world_data.get_block(Vector3i(0, -1, 0))).is_equal(VoxelWorldData.Block.GRASS)
	_session.pause_game()
	_button("载入游戏").pressed.emit()
	var double_click: InputEventMouseButton = InputEventMouseButton.new()
	double_click.button_index = MOUSE_BUTTON_LEFT
	double_click.pressed = true
	double_click.double_click = true
	_row("原始").gui_input.emit(double_click)
	assert_bool(get_tree().paused).is_false()
	assert_bool(_session.menu.visible).is_false()


func test_delete_confirmation_and_escape_returns_to_pause_before_resuming() -> void:
	_session.start_new()
	_session.pause_game()
	_session.save_game("暂存")
	_button("载入游戏").pressed.emit()
	_button("删除").pressed.emit()
	assert_bool(_session.menu.confirmation_visible()).is_true()
	assert_int(_session.store.list_saves().size()).is_equal(1)
	_session.menu.close_panel()
	assert_int(_session.store.list_saves().size()).is_equal(1)
	_button("删除").pressed.emit()
	_confirm_dialog()
	assert_int(_session.store.list_saves().size()).is_equal(0)
	var escape: InputEventKey = InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.physical_keycode = KEY_ESCAPE
	escape.pressed = true
	_session._input(escape)
	assert_bool(get_tree().paused).is_true()
	assert_object(_button("保存游戏")).is_not_null()
	_session._input(escape)
	assert_bool(get_tree().paused).is_false()


func test_save_and_exit_confirms_before_overwriting_a_manual_save_with_the_fixed_name() -> void:
	_session.start_new("第一世界")
	_session.pause_game()
	assert_bool(_session.save_game("退出存档")).is_true()
	var first_id: String = _session.game.world_id
	_session.start_new("第二世界")
	_session.pause_game()
	_button("保存并退出").pressed.emit()
	assert_bool(_session.menu.confirmation_visible()).is_true()
	assert_object(_session.game).is_not_null()
	assert_str(_session.store.load_named(_session.store.latest_id())["world_id"]).is_equal(first_id)
	_confirm_dialog()
	assert_object(_session.game).is_null()
	assert_str(_session.store.load_named(_session.store.latest_id())["world_name"]).is_equal("第二世界")


func test_long_save_name_confirmation_stays_inside_viewport() -> void:
	_session.start_new()
	_session.pause_game()
	var save_name: String = "工业工厂".repeat(30)
	assert_bool(_session.save_game(save_name)).is_true()
	_button("保存游戏").pressed.emit()
	_row(save_name).pressed.emit()
	_button("确认").pressed.emit()
	await get_tree().process_frame
	for child: Node in _session.menu.get_children():
		var dialog: ConfirmationDialog = child as ConfirmationDialog
		if dialog != null:
			assert_int(dialog.size.x).is_less_equal(int(_session.menu.size.x) - 48)


func _confirm_dialog() -> void:
	for child: Node in _session.menu.get_children():
		var dialog: ConfirmationDialog = child as ConfirmationDialog
		if dialog != null:
			dialog.confirmed.emit()
			dialog.hide()
			return


func _button(text: String) -> Button:
	return _find_button(_session.menu, text)


func _find_button(node: Node, text: String) -> Button:
	var button: Button = node as Button
	if button != null and button.text == text and button.is_visible_in_tree():
		return button
	for child: Node in node.get_children():
		var found: Button = _find_button(child, text)
		if found != null:
			return found
	return null


func _row(name_text: String) -> Button:
	return _find_row(_session.menu, name_text)


func _find_row(node: Node, name_text: String) -> Button:
	var button: Button = node as Button
	if button != null and button.tooltip_text.begins_with(name_text + "\n"):
		return button
	for child: Node in node.get_children():
		var found: Button = _find_row(child, name_text)
		if found != null:
			return found
	return null
