class_name SessionMenu
extends Control
## One shared file list; menus emit intentions and never touch game state.

signal new_requested
signal new_confirmed(world_name: String)
signal continue_requested
signal load_requested
signal load_confirmed(save_id: String)
signal quit_requested
signal resume_requested
signal save_requested
signal save_confirmed(save_name: String, overwrite: bool)
signal delete_confirmed(save_id: String)
signal return_requested

var _panel: PanelContainer
var _home: VBoxContainer
var _main: VBoxContainer
var _pause: VBoxContainer
var _files: VBoxContainer
var _naming: VBoxContainer
var _title: Label
var _world_label: Label
var _message: Label
var _continue: Button
var _main_load: Button
var _pause_load: Button
var _file_title: Label
var _name_row: VBoxContainer
var _save_name: LineEdit
var _world_name: LineEdit
var _rows: VBoxContainer
var _scroll: ScrollContainer
var _confirm: Button
var _dialog: ConfirmationDialog
var _records: Array[Dictionary] = []
var _row_buttons: Dictionary[String, Button] = {}
var _selected: String = ""
var _saving: bool = false
var _paused: bool = false
var _has_save: bool = false
var _current_world: String = ""
var _pending: Callable


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = _theme()
	resized.connect(_resize_panel)
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", _style("#202020", "#484848", 28))
	center.add_child(_panel)
	var column: VBoxContainer = _column(18)
	_panel.add_child(column)
	_home = _column(24)
	column.add_child(_home)
	_home.add_child(_label("PREALPHA  /  01", 12, "#949494"))
	_title = _label("PROJECT\nFACTORY", 38)
	_home.add_child(_title)
	_main = _column(10)
	_home.add_child(_main)
	_main.add_child(_button("新游戏", func() -> void: new_requested.emit(), true))
	_continue = _button("继续", func() -> void: continue_requested.emit())
	_main.add_child(_continue)
	_main_load = _button("载入游戏", func() -> void: load_requested.emit())
	_main.add_child(_main_load)
	_main.add_child(_button("退出游戏", func() -> void: quit_requested.emit()))
	_pause = _column(10)
	_home.add_child(_pause)
	_world_label = _label("", 16, "#b0b0b0")
	_world_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_world_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_pause.add_child(_world_label)
	_pause.add_child(_button("继续  [Esc]", func() -> void: resume_requested.emit(), true))
	_pause_load = _button("载入游戏", func() -> void: load_requested.emit())
	_pause.add_child(_pause_load)
	_pause.add_child(_button("保存游戏", func() -> void: save_requested.emit()))
	_pause.add_child(_button("保存并退出", func() -> void: return_requested.emit()))
	_files = _column(16)
	column.add_child(_files)
	_file_title = _label("", 28)
	_files.add_child(_file_title)
	_name_row = _column(8)
	_name_row.add_child(_label("存档名称", 14, "#aaaaaa"))
	_save_name = _line_edit()
	_save_name.max_length = 160
	_save_name.name = "SaveName"
	_name_row.add_child(_save_name)
	_files.add_child(_name_row)
	_save_name.text_changed.connect(func(_text: String) -> void: _update_confirm())
	_save_name.text_submitted.connect(func(_text: String) -> void: _confirm_file())
	_files.add_child(_label("存档  /  按保存时间排序", 13, "#aaaaaa"))
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_files.add_child(_scroll)
	_rows = _column(8)
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_rows)
	var actions: HBoxContainer = HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 12)
	actions.add_child(_button("返回", close_panel))
	_confirm = _button("确认", _confirm_file, true)
	_confirm.custom_minimum_size.x = 130
	actions.add_child(_confirm)
	_files.add_child(actions)
	_naming = _column(16)
	column.add_child(_naming)
	_naming.add_child(_label("新游戏", 28))
	_naming.add_child(_label("世界名称", 14, "#aaaaaa"))
	_world_name = _line_edit()
	_world_name.name = "WorldName"
	_naming.add_child(_world_name)
	_world_name.text_submitted.connect(func(_text: String) -> void: _confirm_name())
	var name_actions: HBoxContainer = HBoxContainer.new()
	name_actions.alignment = BoxContainer.ALIGNMENT_END
	name_actions.add_theme_constant_override("separation", 12)
	name_actions.add_child(_button("返回", close_panel))
	name_actions.add_child(_button("确认", _confirm_name, true))
	_naming.add_child(name_actions)
	_message = _label("", 13, "#aaaaaa")
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.custom_minimum_size.y = 20
	column.add_child(_message)
	_dialog = ConfirmationDialog.new()
	_dialog.dialog_autowrap = true
	_dialog.ok_button_text = "确认"
	_dialog.cancel_button_text = "取消"
	_dialog.confirmed.connect(func() -> void:
		if _pending.is_valid():
			_pending.call()
		_pending = Callable()
	)
	add_child(_dialog)
	show_menu(false, false)


func show_menu(paused: bool, has_save: bool, world_name: String = "") -> void:
	_paused = paused
	_has_save = has_save
	_current_world = world_name
	_home.show()
	_files.hide()
	_naming.hide()
	_main.visible = not paused
	_pause.visible = paused
	_title.text = "游戏已暂停" if paused else "PROJECT\nFACTORY"
	_title.add_theme_font_size_override("font_size", 28 if paused else 38)
	_world_label.text = world_name
	_continue.disabled = not has_save
	_main_load.disabled = not has_save
	_pause_load.disabled = not has_save
	set_message("")
	show()
	_resize_panel()
	var first: Button = _pause.get_child(1) as Button if paused else _main.get_child(0) as Button
	first.grab_focus()


func show_name(default_name: String = "新世界") -> void:
	_home.hide()
	_files.hide()
	_naming.show()
	_world_name.text = default_name
	set_message("")
	_resize_panel()
	_world_name.grab_focus()
	_world_name.select_all()


func show_files(saving: bool, records: Array[Dictionary], default_name: String = "") -> void:
	_saving = saving
	_records = records
	_selected = ""
	_home.hide()
	_naming.hide()
	_files.show()
	_file_title.text = "保存游戏" if saving else "载入游戏"
	_name_row.visible = saving
	_save_name.text = default_name
	set_message("单击选择，双击载入。" if not saving else "选择已有存档可使用它的名称。")
	_refresh_rows()
	_update_confirm()
	_resize_panel()
	if saving:
		_save_name.grab_focus()
		_save_name.caret_column = _save_name.text.length()


func replace_records(records: Array[Dictionary]) -> void:
	_records = records
	_selected = ""
	_refresh_rows()
	_update_confirm()
	_has_save = not records.is_empty()


func close_panel() -> bool:
	if _dialog.visible:
		_dialog.hide()
		_pending = Callable()
		return true
	if _files.visible or _naming.visible:
		show_menu(_paused, _has_save, _current_world)
		return true
	return false


func confirmation_visible() -> bool:
	return _dialog.visible


func confirm_overwrite(save_name: String, action: Callable) -> void:
	_ask("覆盖存档", "与现有存档名称重复，是否覆盖\n“%s”" % save_name, action)


func set_message(message: String, _failed: bool = false) -> void:
	_message.text = message


func _confirm_name() -> void:
	var world_name: String = _world_name.text.strip_edges()
	if world_name.is_empty():
		set_message("请输入世界名称。")
		return
	new_confirmed.emit(world_name)


func _confirm_file() -> void:
	if not _saving:
		if not _selected.is_empty():
			load_confirmed.emit(_selected)
		return
	var save_name: String = _save_name.text.strip_edges()
	if save_name.is_empty():
		return
	for record: Dictionary in _records:
		if record["name"] == save_name:
			confirm_overwrite(save_name,
				func() -> void: save_confirmed.emit(save_name, true))
			return
	save_confirmed.emit(save_name, false)


func _select(record: Dictionary) -> void:
	_selected = record["id"]
	if _saving:
		_save_name.text = record["name"]
	for save_id: String in _row_buttons:
		var button: Button = _row_buttons[save_id]
		button.add_theme_stylebox_override("normal", _style(
			"#393939" if save_id == _selected else "#282828",
			"#aaaaaa" if save_id == _selected else "#414141", 0))
	_update_confirm()


func _refresh_rows() -> void:
	for child: Node in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	_row_buttons.clear()
	if _records.is_empty():
		_rows.add_child(_label("暂无存档", 16, "#949494"))
	for record: Dictionary in _records:
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_rows.add_child(row)
		var choose: Button = _button("", func() -> void: _select(record))
		choose.custom_minimum_size.y = 68
		choose.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		choose.gui_input.connect(func(event: InputEvent) -> void:
			var click: InputEventMouseButton = event as InputEventMouseButton
			if click != null and click.button_index == MOUSE_BUTTON_LEFT and click.pressed and click.double_click:
				_select(record)
				if not _saving:
					_confirm_file()
					choose.accept_event()
		)
		row.add_child(choose)
		_row_buttons[record["id"]] = choose
		var inset: MarginContainer = MarginContainer.new()
		inset.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		inset.add_theme_constant_override("margin_left", 14)
		inset.add_theme_constant_override("margin_right", 14)
		inset.add_theme_constant_override("margin_top", 8)
		inset.mouse_filter = Control.MOUSE_FILTER_IGNORE
		choose.add_child(inset)
		var labels: VBoxContainer = _column(4)
		labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inset.add_child(labels)
		var save_name: String = record["name"]
		var name_label: Label = _label(save_name, 17)
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		labels.add_child(name_label)
		var kind: String = "自动" if record["kind"] == "auto" else ("退出" if record["kind"] == "exit" else "手动")
		var saved_at: float = record["saved_at"]
		var timezone: Dictionary = Time.get_time_zone_from_system()
		var bias: int = timezone["bias"]
		var date: String = Time.get_datetime_string_from_unix_time(int(saved_at) + bias * 60).replace("T", "  ")
		var details: Label = _label("%s  ·  %s  ·  %s" % [record["world_name"], date, kind], 12, "#aaaaaa")
		details.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		details.mouse_filter = Control.MOUSE_FILTER_IGNORE
		labels.add_child(details)
		choose.tooltip_text = "%s\n%s" % [record["name"], details.text]
		var delete: Button = _button("删除", func() -> void:
			_ask("删除存档", "确定删除“%s”？" % record["name"],
				func() -> void: delete_confirmed.emit(record["id"]))
		)
		delete.custom_minimum_size = Vector2(72, 68)
		row.add_child(delete)


func _update_confirm() -> void:
	_confirm.disabled = _save_name.text.strip_edges().is_empty() if _saving else _selected.is_empty()


func _ask(title: String, message: String, action: Callable) -> void:
	_pending = action
	_dialog.title = title
	_dialog.dialog_text = message
	_dialog.popup_centered(Vector2i(440, 160))


func _resize_panel() -> void:
	if _panel == null:
		return
	_panel.custom_minimum_size.x = minf(740.0 if _files.visible else 420.0, maxf(280.0, size.x - 48.0))
	_scroll.custom_minimum_size.y = clampf(size.y - (360.0 if _saving else 280.0), 140.0, 340.0)
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.04, 0.04, 0.04, 0.88) if _paused else Color("#151515"))
	if not _paused:
		for x: int in range(0, int(size.x), 64):
			draw_line(Vector2(x, 0), Vector2(x, size.y), Color(1, 1, 1, 0.025))
		for y: int in range(0, int(size.y), 64):
			draw_line(Vector2(0, y), Vector2(size.x, y), Color(1, 1, 1, 0.025))


static func _column(separation: int) -> VBoxContainer:
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", separation)
	return column


static func _label(text: String, font_size: int, color: String = "#eeeeee") -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color(color))
	return label


static func _line_edit() -> LineEdit:
	var edit: LineEdit = LineEdit.new()
	edit.custom_minimum_size.y = 44
	edit.max_length = 80
	return edit


static func _style(background: String, border: String, margin: int) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(background)
	style.border_color = Color(border)
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.content_margin_left = margin
	style.content_margin_right = margin
	style.content_margin_top = margin
	style.content_margin_bottom = margin
	return style


static func _button(text: String, action: Callable, primary: bool = false) -> Button:
	var button: Button = Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(96, 44)
	if primary:
		button.add_theme_color_override("font_color", Color("#191919"))
		button.add_theme_color_override("font_hover_color", Color("#191919"))
		button.add_theme_color_override("font_pressed_color", Color("#191919"))
		button.add_theme_color_override("font_focus_color", Color("#191919"))
		for state: String in ["normal", "hover", "pressed"]:
			button.add_theme_stylebox_override(state, _style("#dddddd" if state == "normal" else "#f0f0f0", "#eeeeee", 8))
	button.pressed.connect(action)
	return button


static func _theme() -> Theme:
	var result: Theme = Theme.new()
	result.default_font = preload("res://assets/fonts/build_ui.ttf")
	result.default_font_size = 16
	for state: String in ["normal", "hover", "pressed", "disabled"]:
		result.set_stylebox(state, "Button", _style("#282828" if state in ["normal", "disabled"] else "#3a3a3a", "#484848", 8))
	result.set_stylebox("focus", "Button", _style("#ffffff00", "#aaaaaa", 0))
	result.set_color("font_color", "Button", Color("#dddddd"))
	result.set_color("font_hover_color", "Button", Color("#ffffff"))
	result.set_color("font_pressed_color", "Button", Color("#ffffff"))
	result.set_color("font_focus_color", "Button", Color("#ffffff"))
	result.set_color("font_disabled_color", "Button", Color("#777777"))
	result.set_stylebox("normal", "LineEdit", _style("#171717", "#555555", 10))
	result.set_stylebox("focus", "LineEdit", _style("#ffffff00", "#aaaaaa", 10))
	result.set_color("font_color", "LineEdit", Color("#eeeeee"))
	result.set_color("caret_color", "LineEdit", Color("#eeeeee"))
	result.set_color("selection_color", "LineEdit", Color("#555555"))
	result.set_stylebox("panel", "AcceptDialog", _style("#252525", "#777777", 20))
	result.set_stylebox("embedded_border", "Window", _style("#252525", "#777777", 10))
	result.set_color("title_color", "Window", Color("#eeeeee"))
	return result
