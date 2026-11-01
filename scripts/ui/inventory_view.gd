class_name InventoryView
extends Control

signal close_requested

var slot_grid: GridContainer
var close_button: Button
var detail_label: Label
var selected_slot: int = -1

var _inventory: InventoryData
var _count: Label
var _buttons: Array[Button] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade: ColorRect = ColorRect.new()
	shade.color = Color(0.035, 0.055, 0.07, 0.78)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(center)
	var panel: PanelContainer = PanelContainer.new()
	panel.custom_minimum_size = Vector2(660, 480)
	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = Color("#17252d")
	panel_style.border_color = Color("#435f67")
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(12)
	panel_style.content_margin_left = 28
	panel_style.content_margin_right = 28
	panel_style.content_margin_top = 24
	panel_style.content_margin_bottom = 24
	panel.add_theme_stylebox_override("panel", panel_style)
	center.add_child(panel)
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	panel.add_child(column)
	var header: HBoxContainer = HBoxContainer.new()
	column.add_child(header)
	var title: Label = Label.new()
	title.text = "INVENTORY"
	title.add_theme_font_size_override("font_size", 26)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	close_button = Button.new()
	close_button.text = "Close  [I / Esc]"
	close_button.pressed.connect(func() -> void: close_requested.emit())
	header.add_child(close_button)
	_count = Label.new()
	_count.modulate = Color("#aac4c8")
	column.add_child(_count)
	slot_grid = GridContainer.new()
	slot_grid.columns = 6
	slot_grid.add_theme_constant_override("h_separation", 8)
	slot_grid.add_theme_constant_override("v_separation", 8)
	column.add_child(slot_grid)
	detail_label = Label.new()
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_label.custom_minimum_size = Vector2(0, 56)
	detail_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_label.modulate = Color("#c1d2d5")
	column.add_child(detail_label)
	visible = false


func bind_inventory(inventory: InventoryData) -> void:
	if _inventory != null:
		_inventory.changed.disconnect(_refresh)
	_inventory = inventory
	_inventory.changed.connect(_refresh)
	for button: Button in _buttons:
		button.free()
	_buttons.clear()
	selected_slot = -1
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color("#22343e")
	style.border_color = Color("#3d5560")
	style.set_border_width_all(1)
	style.set_corner_radius_all(5)
	for index: int in range(_inventory.capacity()):
		var button: Button = Button.new()
		button.custom_minimum_size = Vector2(94, 64)
		button.add_theme_stylebox_override("normal", style)
		button.add_theme_font_size_override("font_size", 13)
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.pressed.connect(_select_slot.bind(index))
		slot_grid.add_child(button)
		_buttons.append(button)
	_refresh()


func _select_slot(index: int) -> void:
	selected_slot = index
	_refresh()


func _refresh() -> void:
	_count.text = "%d / %d slots used" % [_inventory.used_slots(), _inventory.capacity()]
	for index: int in range(_buttons.size()):
		var stack: ItemStack = _inventory.get_slot(index)
		_buttons[index].text = "%02d\n—" % (index + 1) if stack == null else "%s\nx%d" % [
			stack.definition.display_name, stack.quantity,
		]
		_buttons[index].tooltip_text = "Empty slot" if stack == null else stack.definition.display_name
	if selected_slot < 0:
		detail_label.text = "Your inventory is empty. Select a slot to inspect it." if _inventory.used_slots() == 0 else "Select a slot to inspect its contents."
	else:
		var selected: ItemStack = _inventory.get_slot(selected_slot)
		detail_label.text = "Slot %02d  /  Empty" % (selected_slot + 1) if selected == null else "%s  /  %d\n%s" % [
			selected.definition.display_name, selected.quantity, selected.definition.description,
		]
