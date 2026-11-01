class_name FactoryGame
extends Node3D
## Composition root: connects rules, input and presentation explicitly.

const REACH: float = 5.0

@onready var player: FactoryPlayer = $Player
@onready var world_view: VoxelWorldView = $World
@onready var hud: FactoryHud = $Interface/Hud
@onready var target_outline: MeshInstance3D = $TargetOutline
@onready var inventory_view: InventoryView = $Interface/InventoryView

var world_data: VoxelWorldData = VoxelWorldData.new()
var selected_block: int = VoxelWorldData.Block.STONE
var inventory: InventoryData = InventoryData.new()
var _capture_before_inventory: bool = false


func _ready() -> void:
	world_data.generate_flat()
	world_view.bind_world(world_data)
	player.break_requested.connect(_break_target)
	player.place_requested.connect(_place_target)
	player.block_selected.connect(_select_block)
	player.respawn_requested.connect(_respawn_player)
	player.inventory_requested.connect(_toggle_inventory)
	player.focus_lost.connect(_on_player_focus_lost)
	inventory_view.bind_inventory(inventory)
	inventory_view.close_requested.connect(_close_inventory)
	_build_target_outline()


func _process(_delta: float) -> void:
	var hit: VoxelHit = current_hit()
	target_outline.visible = hit != null and player.controls_captured()
	if hit != null:
		target_outline.position = VoxelWorldData.cell_center(hit.cell)
	hud.update_status(selected_block, hit, world_data, player.controls_captured())


func _input(event: InputEvent) -> void:
	# Handle modal shortcuts before focused buttons consume GUI input.
	if event.is_action_pressed("toggle_inventory") or (
		inventory_view.visible and event.is_action_pressed("toggle_mouse")
	):
		player.handle_input(event)
		get_viewport().set_input_as_handled()


func _toggle_inventory() -> void:
	if inventory_view.visible:
		_close_inventory()
	else:
		_capture_before_inventory = player.controls_captured()
		inventory_view.show()
		player.set_inventory_open(true)
		inventory_view.close_button.grab_focus()


func _close_inventory() -> void:
	inventory_view.hide()
	player.set_inventory_open(false)
	player.set_controls_captured(_capture_before_inventory)


func _on_player_focus_lost() -> void:
	_capture_before_inventory = false


func current_hit() -> VoxelHit:
	return VoxelRaycast.cast(
		world_data, player.camera.global_position, -player.camera.global_basis.z, REACH
	)


func _break_target() -> void:
	if inventory_view.visible:
		return
	var hit: VoxelHit = current_hit()
	if hit != null:
		world_data.break_block(hit.cell)


func _place_target() -> void:
	if inventory_view.visible:
		return
	var hit: VoxelHit = current_hit()
	if hit != null and hit.normal != Vector3i.ZERO:
		world_data.place_block(hit.adjacent_cell(), selected_block, player.occupied_bounds())


func _select_block(block: int) -> void:
	selected_block = block


func _respawn_player() -> void:
	player.respawn(world_data.spawn_above_world(player.spawn_position, player.occupied_bounds().size))


func _build_target_outline() -> void:
	var mesh: ImmediateMesh = ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for axis: int in range(3):
		for first: int in [-1, 1]:
			for second: int in [-1, 1]:
				var start: Vector3 = Vector3.ZERO
				start[axis] = -0.253
				start[(axis + 1) % 3] = float(first) * 0.253
				start[(axis + 2) % 3] = float(second) * 0.253
				var end: Vector3 = start
				end[axis] = 0.253
				mesh.surface_add_vertex(start)
				mesh.surface_add_vertex(end)
	mesh.surface_end()
	target_outline.mesh = mesh
