class_name FactoryGame
extends Node3D
## Composition root: connects rules, input and presentation explicitly.

const REACH: float = 5.0

@export var game_config: GameConfig = GameConfig.new()

@onready var player: FactoryPlayer = $Player
@onready var world_view: VoxelWorldView = $World
@onready var hud: FactoryHud = $Interface/Hud
@onready var target_outline: MeshInstance3D = $TargetOutline
@onready var inventory_view: InventoryView = $Interface/InventoryView

var world_data: VoxelWorldData = VoxelWorldData.new()
var selected_block: int = VoxelWorldData.Block.STONE
var inventory: InventoryData = InventoryData.new()
var logistics_data: LogisticsData = LogisticsData.new()
var logistics_view: LogisticsView
var belt_placement: BeltPlacement = BeltPlacement.new()
var build_preview: BuildPreview
var free_camera: FreeCameraRig
var _capture_before_inventory: bool = false
var _build_rotation: int = 0
var _preview_dirty: bool = true
var _preview_has_hit: bool = false
var _preview_cell: Vector3i
var _preview_normal: Vector3i
var _preview_direction: Vector3i
var _preview_occupied: Array[Vector3i] = []
var _preview_error: String = ""
var _failure_seconds: float = 0.0
var _idle_belt: BeltPlacement = BeltPlacement.new()
var initial_snapshot: SessionSnapshot
var world_id: String = SaveGameStore.new_id()
var world_name: String = "新世界"


func _ready() -> void:
	if game_config == null:
		game_config = GameConfig.new()
	var gravity_setting: Variant = ProjectSettings.get_setting("physics/3d/default_gravity")
	var gravity: float = 0.0
	if gravity_setting is float or gravity_setting is int:
		gravity = gravity_setting
	player.configure_gravity(gravity)
	if initial_snapshot == null:
		world_data.generate_flat()
		logistics_data.bind_world(world_data, game_config.mining_interval, game_config.mining_amount)
	else:
		world_id = initial_snapshot.world_id if not initial_snapshot.world_id.is_empty() else SaveGameStore.new_id()
		world_name = initial_snapshot.world_name
		world_data = initial_snapshot.world
		logistics_data = initial_snapshot.logistics
		inventory = initial_snapshot.inventory
		# Restore tuning for newly placed machines without editing the shared Resource.
		game_config = game_config.duplicate() as GameConfig
		var simulation: Dictionary = logistics_data.save_state()
		game_config.mining_interval = simulation["interval"]
		game_config.mining_amount = simulation["amount"]
		player.position = initial_snapshot.position
		player.velocity = initial_snapshot.velocity
		player.spawn_position = initial_snapshot.spawn
		player.camera.rotation = initial_snapshot.view_rotation
		selected_block = initial_snapshot.selected_block
		_build_rotation = initial_snapshot.build_rotation
		initial_snapshot = null
	world_view.bind_world(world_data)
	logistics_view = LogisticsView.new()
	logistics_view.name = "Logistics"
	add_child(logistics_view)
	logistics_view.bind_logistics(logistics_data, world_data, player.camera)
	_apply_game_config()
	game_config.changed.connect(_apply_game_config)
	free_camera = FreeCameraRig.new()
	free_camera.name = "FreeCamera"
	add_child(free_camera)
	free_camera.configure(player, world_data)
	belt_placement.bind_world(world_data, logistics_data)
	_idle_belt.bind_world(world_data, logistics_data)
	build_preview = BuildPreview.new()
	build_preview.name = "BuildPreview"
	add_child(build_preview)
	world_data.cell_changed.connect(_invalidate_preview)
	world_data.world_reset.connect(_cancel_build)
	logistics_data.machine_changed.connect(_invalidate_preview)
	player.break_requested.connect(_break_target)
	player.place_requested.connect(_place_target)
	player.block_selected.connect(_select_block)
	player.build_rotation_requested.connect(_rotate_build)
	player.build_waypoint_requested.connect(_lock_belt_path)
	player.controls_capture_changed.connect(_on_capture_changed)
	player.respawn_requested.connect(_respawn_player)
	player.inventory_requested.connect(_toggle_inventory)
	player.focus_lost.connect(_on_player_focus_lost)
	player.focus_restored.connect(_on_player_focus_restored)
	player.view_mode_requested.connect(_toggle_free_view)
	player.camera_input_requested.connect(free_camera.handle_input)
	player.free_cancel_requested.connect(_cancel_build)
	inventory_view.bind_inventory(inventory)
	inventory_view.close_requested.connect(_close_inventory)
	_build_target_outline()


func save_state() -> Dictionary:
	return {
		"world_id": world_id, "world_name": world_name,
		"version": SessionSnapshot.FORMAT_VERSION, "generator": SessionSnapshot.GENERATOR_VERSION,
		"minimum": VoxelWorldData.MIN_CELL, "maximum": VoxelWorldData.MAX_CELL,
		"flat": world_data.has_flat_baseline(), "chunks": world_data.chunk_deltas(),
		"logistics": logistics_data.save_state(), "inventory": inventory.save_state(),
		"player": {
			"position": player.position, "velocity": player.velocity, "spawn": player.spawn_position,
			"rotation": player.camera.rotation, "tool": selected_block, "build_rotation": _build_rotation,
		},
	}


func _apply_game_config() -> void:
	logistics_data.configure_miners(game_config.mining_interval, game_config.mining_amount)
	if is_instance_valid(logistics_view):
		var distance: float = game_config.ore_render_distance
		logistics_view.render_distance = distance if is_finite(distance) and distance > 0.0 else 0.0


func _process(delta: float) -> void:
	_failure_seconds = maxf(0.0, _failure_seconds - delta)
	var hit: VoxelHit = current_hit()
	_update_preview(hit)
	build_preview.set_invalid(not _preview_error.is_empty(), _failure_seconds > 0.0)
	target_outline.visible = hit != null and player.controls_enabled()
	if hit != null:
		var bounds: AABB = VoxelWorldData.block_bounds(hit.cell, world_data.get_block(hit.cell))
		target_outline.position = bounds.get_center()
		target_outline.scale = bounds.size / VoxelWorldData.CELL_SIZE
	hud.update_status(
		selected_block, hit, world_data, player.controls_enabled(), logistics_data, build_direction(),
		belt_placement.active, belt_placement.locked_path.size(), free_camera.active
	)


func _physics_process(delta: float) -> void:
	logistics_data.advance(delta)


func build_direction() -> Vector3i:
	var base_direction: Vector3i = Vector3i.BACK
	for turn: int in range(_build_rotation):
		base_direction = Vector3i(-base_direction.z, 0, base_direction.x)
	return base_direction


func _input(event: InputEvent) -> void:
	# Handle modal shortcuts before focused buttons consume GUI input.
	if event.is_action_pressed("toggle_view") or event.is_action_pressed("toggle_inventory") or (
		event.is_action_pressed("toggle_mouse")
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
		free_camera.set_input_enabled(false)
		build_preview.hide()
		inventory_view.close_button.grab_focus()


func _close_inventory() -> void:
	inventory_view.hide()
	player.set_inventory_open(false)
	player.set_controls_captured(_capture_before_inventory)
	free_camera.set_input_enabled(player.controls_enabled())
	_preview_dirty = true


func _on_player_focus_lost() -> void:
	_capture_before_inventory = false
	free_camera.set_input_enabled(false)
	_cancel_build()


func _on_player_focus_restored() -> void:
	free_camera.set_input_enabled(player.controls_enabled())


func _toggle_free_view() -> void:
	_cancel_build()
	if free_camera.active:
		free_camera.leave()
		player.set_free_view(false)
		logistics_view.set_camera(player.camera)
	else:
		player.set_free_view(true)
		free_camera.set_input_enabled(player.controls_enabled())
		free_camera.enter()
		logistics_view.set_camera(free_camera.camera)


func _on_capture_changed(captured: bool) -> void:
	if not captured and not inventory_view.visible:
		_cancel_build()


func current_hit() -> VoxelHit:
	if free_camera.active:
		return VoxelRaycast.cast(
			world_data, free_camera.camera.project_ray_origin(free_camera.cursor_position),
			free_camera.camera.project_ray_normal(free_camera.cursor_position), 40.0
		)
	return VoxelRaycast.cast(
		world_data, player.camera.global_position, -player.camera.global_basis.z, REACH
	)


func _break_target() -> void:
	if not player.controls_enabled() or free_camera.is_rotating():
		return
	if belt_placement.active:
		_cancel_build()
		return
	var hit: VoxelHit = current_hit()
	if hit != null:
		world_data.break_block(hit.cell)


func _place_target() -> void:
	if not player.controls_enabled() or free_camera.is_rotating():
		return
	var hit: VoxelHit = current_hit()
	_update_preview(hit, true)
	if selected_block == VoxelWorldData.Block.BELT:
		if belt_placement.active:
			var surface_y: float = _overlapping_belt_surface()
			if _belt_overlaps_camera(belt_placement.path):
				_build_failed("无法在此建造")
			elif surface_y > player.global_position.y and not _player_has_lift_clearance(surface_y):
				_build_failed("无法在此建造")
			elif not belt_placement.commit():
				_build_failed(belt_placement.error)
			elif surface_y > player.global_position.y:
				player.raise_to(surface_y)
		elif not belt_placement.begin(hit, build_direction()):
			_build_failed(belt_placement.error)
		_preview_dirty = true
		_update_preview(hit)
		return
	if hit == null or hit.normal == Vector3i.ZERO:
		if LogisticsData.is_machine(selected_block):
			_build_failed("请瞄准有效位置")
		return
	var cell: Vector3i = hit.adjacent_cell()
	if free_camera.active and VoxelWorldData.block_bounds(cell, selected_block).intersects(
		free_camera.occupied_bounds()
	):
		_build_failed("无法在此建造")
		return
	if world_data.place_block(cell, selected_block, player.occupied_bounds()):
		if LogisticsData.is_machine(selected_block):
			logistics_data.set_direction(cell, build_direction())
	elif LogisticsData.is_machine(selected_block):
		_build_failed(_preview_error)


func _belt_overlaps_camera(cells: Array[Vector3i]) -> bool:
	if not free_camera.active:
		return false
	for cell: Vector3i in cells:
		if world_data.get_block(cell) == VoxelWorldData.Block.AIR and VoxelWorldData.block_bounds(
			cell, VoxelWorldData.Block.BELT
		).intersects(free_camera.occupied_bounds()):
			return true
	return false


func _overlapping_belt_surface() -> float:
	var occupied: AABB = player.occupied_bounds()
	var highest: float = player.global_position.y
	for cell: Vector3i in belt_placement.path:
		if world_data.get_block(cell) != VoxelWorldData.Block.AIR:
			continue
		var bounds: AABB = VoxelWorldData.block_bounds(cell, VoxelWorldData.Block.BELT)
		if bounds.intersects(occupied):
			highest = maxf(highest, bounds.end.y)
	return highest


func _player_has_lift_clearance(surface_y: float) -> bool:
	var occupied: AABB = player.occupied_bounds()
	var rise: float = surface_y + player.safe_margin - occupied.position.y
	# World edits queue collider rebuilding. Check the newly swept headroom
	# against authoritative data before consulting the live physics space.
	var headroom: AABB = AABB(
		Vector3(occupied.position.x, occupied.end.y, occupied.position.z),
		Vector3(occupied.size.x, rise, occupied.size.z)
	).grow(player.safe_margin)
	var first: Vector3i = VoxelWorldData.world_to_cell(headroom.position)
	var last: Vector3i = VoxelWorldData.world_to_cell(headroom.end)
	for x: int in range(first.x, last.x + 1):
		for y: int in range(first.y, last.y + 1):
			for z: int in range(first.z, last.z + 1):
				var cell: Vector3i = Vector3i(x, y, z)
				var block: int = world_data.get_block(cell)
				if block != VoxelWorldData.Block.AIR and VoxelWorldData.block_bounds(
					cell, block
				).intersects(headroom):
					return false
	return player.can_raise_to(surface_y)


func _lock_belt_path() -> void:
	if inventory_view.visible or not belt_placement.active:
		return
	_update_preview(current_hit(), true)
	if not _preview_error.is_empty():
		_build_failed(_preview_error)
		return
	if not belt_placement.lock_preview():
		_build_failed(
			belt_placement.error if not belt_placement.error.is_empty() else "中途点必须为空格"
		)
	else:
		_preview_dirty = true
		build_preview.show_lock_points(belt_placement.locked_points)


func _build_failed(reason: String) -> void:
	_failure_seconds = 0.35
	build_preview.set_invalid(true, true)
	hud.show_build_notice(reason if not reason.is_empty() else "无法在此建造")


func _cancel_build() -> void:
	belt_placement.cancel()
	_failure_seconds = 0.0
	_preview_dirty = true
	if build_preview != null:
		build_preview.show_lock_points([])
		build_preview.hide()


func _invalidate_preview(_cell: Vector3i) -> void:
	_preview_dirty = true


func _update_preview(hit: VoxelHit, force: bool = false) -> void:
	if not player.controls_enabled() or not LogisticsData.is_machine(selected_block):
		build_preview.hide()
		_preview_dirty = true
		return
	var direction: Vector3i = build_direction()
	var occupied: AABB = player.occupied_bounds()
	var occupied_cells: Array[Vector3i] = []
	if selected_block != VoxelWorldData.Block.BELT:
		occupied_cells = _occupied_preview_cells(occupied)
	if free_camera.active:
		occupied_cells.append_array(_occupied_preview_cells(free_camera.occupied_bounds()))
	var has_hit: bool = hit != null
	if not force and not _preview_dirty and has_hit == _preview_has_hit and (
		not has_hit or (hit.cell == _preview_cell and hit.normal == _preview_normal)
	) and direction == _preview_direction and occupied_cells == _preview_occupied:
		return
	_preview_dirty = false
	_preview_has_hit = has_hit
	if has_hit:
		_preview_cell = hit.cell
		_preview_normal = hit.normal
	_preview_direction = direction
	_preview_occupied.assign(occupied_cells)
	_preview_error = ""
	if selected_block == VoxelWorldData.Block.BELT and belt_placement.active:
		belt_placement.preview(hit, direction)
		_preview_error = belt_placement.error
		if _preview_error.is_empty() and _belt_overlaps_camera(belt_placement.path):
			_preview_error = "无法在此建造"
		build_preview.show_cells(
			belt_placement.path, belt_placement.directions, selected_block, world_data,
			not _preview_error.is_empty() or _failure_seconds > 0.0, belt_placement.locked_points
		)
	elif not has_hit:
		build_preview.hide()
		_preview_error = "请瞄准有效位置"
	else:
		var cell: Vector3i = hit.adjacent_cell()
		if selected_block == VoxelWorldData.Block.BELT:
			_idle_belt.begin(hit, direction)
			_preview_error = _idle_belt.error
			if _preview_error.is_empty() and _belt_overlaps_camera(_idle_belt.path):
				_preview_error = "无法在此建造"
			if LogisticsData.is_machine(world_data.get_block(hit.cell)):
				cell = hit.cell
				if world_data.get_block(cell) != VoxelWorldData.Block.BELT:
					direction = logistics_data.direction_at(cell)
					cell += direction
			_idle_belt.cancel()
		else:
			_preview_error = _single_placement_error(cell, occupied)
		build_preview.show_cells(
			[cell], [direction], selected_block, world_data,
			not _preview_error.is_empty() or _failure_seconds > 0.0
		)
	build_preview.set_invalid(not _preview_error.is_empty(), _failure_seconds > 0.0)


func _single_placement_error(cell: Vector3i, occupied: AABB) -> String:
	if not world_data.is_in_bounds(cell):
		return "超出世界边界"
	if world_data.get_block(cell) != VoxelWorldData.Block.AIR:
		return "该位置已被占用"
	if VoxelWorldData.block_bounds(cell, selected_block).intersects(occupied):
		return "不能放在玩家所在位置"
	if free_camera.active and VoxelWorldData.block_bounds(cell, selected_block).intersects(
		free_camera.occupied_bounds()
	):
		return "无法在此建造"
	return ""


func _occupied_preview_cells(occupied: AABB) -> Array[Vector3i]:
	# Cache actual collision cells, including the belt's thin top threshold.
	var cells: Array[Vector3i] = []
	var first: Vector3i = VoxelWorldData.world_to_cell(occupied.position)
	var last: Vector3i = VoxelWorldData.world_to_cell(occupied.end)
	for x: int in range(first.x, last.x + 1):
		for y: int in range(first.y, last.y + 1):
			for z: int in range(first.z, last.z + 1):
				var cell: Vector3i = Vector3i(x, y, z)
				if VoxelWorldData.block_bounds(cell, selected_block).intersects(occupied):
					cells.append(cell)
	return cells


func _select_block(block: int) -> void:
	_cancel_build()
	selected_block = block


func _rotate_build() -> void:
	if LogisticsData.is_machine(selected_block):
		_build_rotation = (_build_rotation + 1) % 4
		_preview_dirty = true


func _respawn_player() -> void:
	_cancel_build()
	player.respawn(world_data.spawn_above_world(player.spawn_position, player.occupied_bounds().size))
	if free_camera.active:
		free_camera.enter()


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
