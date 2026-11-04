class_name FactoryHud
extends Control

var _title: Label
var _target: Label
var _hint: Label
var _slots: Array[Label] = []
var _slot_blocks: Array[int] = [
	VoxelWorldData.Block.GRASS, VoxelWorldData.Block.DIRT, VoxelWorldData.Block.STONE,
	VoxelWorldData.Block.MINER, VoxelWorldData.Block.BELT, VoxelWorldData.Block.CHEST,
]
var _build_hint: Label
var _active_style: StyleBoxFlat
var _idle_style: StyleBoxFlat
var _notice: Label
var _notice_seconds: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title = _label(Vector2(28, 24), 24, Color("#edf3f3"))
	_title.text = "PROJECT / FACTORY"
	var subtitle: Label = _label(Vector2(29, 58), 13, Color("#b1c5c3"))
	subtitle.text = "BASIC LOGISTICS     /     0.5 m GRID"
	_target = _label(Vector2(28, 94), 14, Color("#d9e7e4"))
	_build_hint = _label(Vector2(28, 122), 14, Color("#b5ddb1"))
	var localized_font: FontFile = preload("res://assets/fonts/build_ui.ttf")
	_build_hint.add_theme_font_override("font", localized_font)
	_hint = _label(Vector2.ZERO, 15, Color("#edf3f3"))
	_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_hint.offset_left = 28
	_hint.offset_top = -64
	_hint.offset_bottom = -20
	_hint.text = "WASD  Move    SPACE  Jump    LMB  Break    RMB  Place\nI  Inventory    ESC  Cursor    1 - 6  Build tool    R  Rotate"
	_notice = _label(Vector2.ZERO, 19, Color("#ffaaa3"))
	_notice.add_theme_font_override("font", localized_font)
	_notice.name = "BuildNotice"
	_notice.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_notice.offset_left = -320
	_notice.offset_right = 320
	_notice.offset_top = -156
	_notice.offset_bottom = -120
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.hide()
	var hotbar: HBoxContainer = HBoxContainer.new()
	hotbar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hotbar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	hotbar.position = Vector2(-362, -104)
	hotbar.add_theme_constant_override("separation", 8)
	add_child(hotbar)
	_active_style = _slot_style(Color("#263939"), Color("#b5ddb1"), 2)
	_idle_style = _slot_style(Color("#1a242b"), Color("#435056"), 1)
	for text: String in ["1  GRASS", "2  DIRT", "3  STONE", "4  MINER", "5  BELT", "6  CHEST"]:
		var slot: Label = Label.new()
		slot.text = text
		slot.custom_minimum_size = Vector2(114, 48)
		slot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		slot.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		slot.add_theme_font_size_override("font_size", 14)
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hotbar.add_child(slot)
		_slots.append(slot)
	queue_redraw()


func _process(delta: float) -> void:
	_notice_seconds = maxf(0.0, _notice_seconds - delta)
	_notice.visible = _notice_seconds > 0.0


func show_build_notice(message: String) -> void:
	_notice.text = message
	_notice_seconds = 1.8
	_notice.show()


func update_status(
	block: int, hit: VoxelHit, world: VoxelWorldData, captured: bool,
	logistics: LogisticsData = null, direction: Vector3i = Vector3i.ZERO,
	belt_active: bool = false, locked_count: int = 0
) -> void:
	if hit == null:
		_target.text = "Aim at a block within 5 m"
	else:
		var cell: Vector3i = hit.cell
		_target.text = "%s  /  [%d, %d, %d]  /  %.1f m" % [
			VoxelWorldData.block_name(world.get_block(cell)), cell.x, cell.y, cell.z, hit.distance,
		]
		if logistics != null and LogisticsData.is_machine(world.get_block(cell)):
			_target.text += "  /  Iron ore: %d" % logistics.ore_count(cell)
	_build_hint.text = ""
	if LogisticsData.is_machine(block):
		var facing: String = "+X" if direction.x > 0 else "-X"
		if direction.z != 0:
			facing = "+Z" if direction.z > 0 else "-Z"
		_build_hint.text = "OUTPUT → %s    /    R Rotate    /    Belt: 2 ore/s" % facing
	if block == VoxelWorldData.Block.BELT:
		_build_hint.text = (
			"右键完成  /  C 锁定此前路径  /  左键取消  /  已锁定 %d 格" % locked_count
			if belt_active else "右键选起点，再右键选终点  /  自动绕障  /  R 转向"
		)
	if not captured:
		_target.text = "CURSOR RELEASED  /  Click to resume"
	for index: int in range(_slots.size()):
		var style: StyleBoxFlat = _active_style if _slot_blocks[index] == block else _idle_style
		_slots[index].add_theme_stylebox_override("normal", style)
		_slots[index].modulate = Color.WHITE if captured else Color(0.7, 0.7, 0.7)


func _draw() -> void:
	var center: Vector2 = size * 0.5
	draw_line(center - Vector2(7, 0), center + Vector2(7, 0), Color("#edf3f3"), 2.0)
	draw_line(center - Vector2(0, 7), center + Vector2(0, 7), Color("#edf3f3"), 2.0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _slot_style(background: Color, border: Color, border_width: int) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(background, 0.9)
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(5)
	return style


func _label(at: Vector2, font_size: int, color: Color) -> Label:
	var label: Label = Label.new()
	label.position = at
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 2)
	add_child(label)
	return label
