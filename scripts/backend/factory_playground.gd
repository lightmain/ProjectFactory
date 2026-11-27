extends Node3D
## Transitional small world. The backend owns rules; this node owns presentation.

const PLAYER_SCENE: PackedScene = preload("res://scenes/player.tscn")
const SPAWN_POSITION: Vector3 = Vector3(2.8, 0.05, 4.0)
const DIRECTIONS: Array[Vector3i] = [Vector3i.BACK, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.RIGHT]
const COLORS: Array[Color] = [
	Color.TRANSPARENT, Color("#567849"), Color("#8b6249"), Color("#707984"),
	Color("#343b45"), Color("#ca9148"), Color("#4a6170"), Color("#638eac"),
]

var player: FactoryPlayer
var ready_for_play: bool = false
var free_view: bool = false
@export var save_root: String = "user://saves/rust_backend"
var world_id: String = ""
var world_name: String = "新后端世界"
var autosave_minutes: float = 5.0
var autosave_retention: int = 3
var _save_records: Array[Dictionary] = []
var _save_sequence: int = 0
var _job_id: int = 0
var _job_operation: String = ""
var _job_kind: String = ""
var _job_stage: String = ""
var _file_mode: String = ""
var _load_was_paused: bool = false
var _autosave_seconds: float = 0.0
var _auto_pending: bool = false
var _save_notice: String = ""
var _persistence_ready: bool = false
var _backend: RefCounted
var _paused: bool = false
var _selected: int = 6
var _facing: int = 0
var _revision: int = -1
var _state: Dictionary = {}
var _world_view: Node3D
var _free_camera: Camera3D
var _ores: MultiMeshInstance3D
var _preview: MeshInstance3D
var _status: Label
var _hud: FactoryHud
var _inventory_view: InventoryView
var _menu: SessionMenu
var _capture_before_inventory: bool = false
var _capture_before_pause: bool = false
var _cell_nodes: Dictionary[Vector3i, Node3D] = {}
var _block_types: Dictionary[Vector3i, int] = {}
var _meshes: Dictionary[int, Mesh] = {}
var _materials: Dictionary[int, StandardMaterial3D] = {}
var _shapes: Dictionary[int, Shape3D] = {}
var _arrow_mesh: Mesh
var _arrow_material: StandardMaterial3D
var _notice: String = ""
var _rotating: bool = false
var _route_preview: BuildPreview
var _route: Dictionary = {}
var _route_cells: Array[Vector3i] = []
var _route_blocks: Array[int] = []
var _route_dirty: bool = true
var _route_target: Variant = null
var _route_revision: int = -1
var _route_failure_until: int = 0


func _ready() -> void:
	player = PLAYER_SCENE.instantiate() as FactoryPlayer
	player.position = SPAWN_POSITION
	player.process_physics_priority = -1
	add_child(player)
	player.configure_gravity(9.8)
	player.camera.rotation = Vector3(-0.35, 0.55, 0)
	player.break_requested.connect(_break)
	player.place_requested.connect(_place)
	player.block_selected.connect(_select)
	player.build_rotation_requested.connect(_rotate)
	player.build_waypoint_requested.connect(_lock_route)
	player.free_cancel_requested.connect(_cancel_route)
	player.pause_requested.connect(func() -> void: set_paused(true))
	player.inventory_requested.connect(_toggle_inventory)
	player.view_mode_requested.connect(_toggle_view)
	player.camera_input_requested.connect(_camera_input)
	player.respawn_requested.connect(func() -> void:
		_cancel_route()
		player.respawn(player.spawn_position)
	)
	player.focus_lost.connect(func() -> void:
		_capture_before_inventory = false
		_capture_before_pause = false
		_rotating = false
		_cancel_route()
	)
	_free_camera = Camera3D.new()
	_free_camera.position = Vector3(4, 7, 6)
	_free_camera.far = 80
	add_child(_free_camera)
	_free_camera.look_at(Vector3(0.25, 0.5, 1.5))
	_world_view = Node3D.new()
	_world_view.name = "World"
	add_child(_world_view)
	_arrow_mesh = LogisticsView._arrow_mesh()
	_arrow_material = LogisticsView._material(Color("#e8e5d3"))
	_ores = MultiMeshInstance3D.new()
	var ore_mesh: SphereMesh = SphereMesh.new()
	ore_mesh.radius = 0.045
	ore_mesh.height = 0.09
	ore_mesh.radial_segments = 8
	ore_mesh.rings = 4
	_ores.multimesh = MultiMesh.new()
	_ores.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_ores.multimesh.mesh = ore_mesh
	_ores.material_override = _material(Color("#e9b65d"))
	add_child(_ores)
	_preview = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3.ONE * 0.505
	_preview.mesh = box
	var preview_material: StandardMaterial3D = _material(Color(0.4, 0.85, 0.7, 0.3))
	preview_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_preview.material_override = preview_material
	add_child(_preview)
	_route_preview = BuildPreview.new()
	_route_preview.name = "RoutePreview"
	add_child(_route_preview)
	var light: DirectionalLight3D = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	light.shadow_enabled = true
	add_child(light)
	var environment: WorldEnvironment = WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("#a3bec9")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("#d8e5ef")
	environment.environment.ambient_light_energy = 0.6
	add_child(environment)
	_build_interface()
	if not ClassDB.class_exists(&"FactoryBackend"):
		_fail("新后端尚未安装，请按开发说明构建后重新启动。")
		return
	var instance: Variant = ClassDB.instantiate(&"FactoryBackend")
	if instance is RefCounted:
		_backend = instance
	if _backend == null or not _backend.has_method("begin_belt_route"):
		_fail("新后端版本不支持试玩，请重新构建。")
		return
	if not _command("open_backend", [{"api_version": 1}]):
		return
	start_factory("conveyor_continuous_v1")
	if not _backend.has_method("configure_persistence"):
		_menu.set_message("后端版本不支持存档，请重新构建并重启编辑器。", true)
		return
	var configured: Dictionary = _dictionary(_backend.call("configure_persistence",
		ProjectSettings.globalize_path(save_root)))
	_persistence_ready = configured.get("ok", false)
	if not _persistence_ready:
		_save_message("存档目录无法打开：" + str(configured.get("error", "")))
		return
	if get_tree().has_meta("backend_open_saves"):
		get_tree().remove_meta("backend_open_saves")
		set_paused(true)
		_file_mode = "load"
	_begin_job("list", _dictionary(_backend.call("request_save_list")))


func _exit_tree() -> void:
	if _backend != null:
		_backend.call("close_backend")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func start_factory(ruleset: String) -> void:
	if _job_id != 0:
		_save_message("请等待当前存档操作结束。")
		return
	_cancel_route()
	ready_for_play = _command("create_factory", [ruleset])
	_revision = -1
	_notice = "已搭好示例线路；可拆开、延长或另建一条。"
	if ready_for_play:
		world_id = str(_backend.call("new_world_id")) if _backend.has_method("new_world_id") else ""
		world_name = "新后端世界"
		_autosave_seconds = 0.0
		_auto_pending = false
		player.spawn_position = SPAWN_POSITION
		player.respawn(SPAWN_POSITION)
		_refresh()
		_update_target()


func snapshot() -> Dictionary:
	return _state.duplicate(true)


func advance(delta: float) -> void:
	if ready_for_play and not _paused:
		if _command("advance_factory", [delta]):
			_refresh()


func _physics_process(delta: float) -> void:
	advance(delta)
	if free_view and not _paused and player.controls_enabled():
		var movement: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		var right: Vector3 = _free_camera.global_basis.x
		var forward: Vector3 = _free_camera.global_basis.z
		right.y = 0
		forward.y = 0
		_free_camera.position += (right.normalized() * movement.x + forward.normalized() * movement.y) * delta * 4
	_update_target()


func _input(event: InputEvent) -> void:
	if _paused and event.is_action_pressed("toggle_mouse") and not event.is_echo() and ready_for_play:
		if _job_operation == "load":
			cancel_persistence()
		elif not _menu.close_panel():
			set_paused(false)
		get_viewport().set_input_as_handled()
	elif not _paused and event.is_action_pressed("toggle_inventory") and not event.is_echo():
		player.handle_input(event)
		get_viewport().set_input_as_handled()
	elif _inventory_view.visible and event.is_action_pressed("toggle_mouse") and not event.is_echo():
		_close_inventory()
		get_viewport().set_input_as_handled()


func set_paused(paused: bool) -> void:
	if not paused and _job_operation in ["load", "exit"]:
		_save_message("正在读档；按 Esc 可取消，完成前保留暂停。" if _job_operation == "load"
			else "正在保存并退出，请等待保存结果。")
		return
	if paused == _paused and ready_for_play:
		return
	if paused:
		_cancel_route()
		if _inventory_view.visible:
			_close_inventory()
		_capture_before_pause = player.controls_captured()
	_paused = paused
	_rotating = false
	player.set_session_paused(paused)
	player.set_physics_process(not paused)
	if not paused:
		player.set_controls_captured(_capture_before_pause)
		_menu.hide()
	else:
		_show_pause_menu()
	_preview.hide()


func _toggle_inventory() -> void:
	if not ready_for_play or _paused:
		return
	if _inventory_view.visible:
		_close_inventory()
	else:
		_capture_before_inventory = player.controls_captured()
		_inventory_view.show()
		player.set_inventory_open(true)
		_rotating = false
		_preview.hide()
		_route_preview.hide()
		_inventory_view.close_button.grab_focus()


func _close_inventory() -> void:
	_inventory_view.hide()
	player.set_inventory_open(false)
	player.set_controls_captured(_capture_before_inventory)


func _toggle_view() -> void:
	_cancel_route()
	free_view = not free_view
	player.set_free_view(free_view)
	_free_camera.current = free_view
	player.camera.current = not free_view
	_update_target()


func _camera_input(event: InputEvent) -> void:
	if not free_view or not player.controls_enabled():
		return
	if event is InputEventMouseButton:
		var button: InputEventMouseButton = event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_MIDDLE:
			_rotating = button.pressed
		elif button.pressed and button.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var sign_value: float = -1.0 if button.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
			_free_camera.position += _free_camera.global_basis.z * sign_value * 0.6
			_free_camera.position.y = clampf(_free_camera.position.y, 1.5, 15.0)
	elif event is InputEventMouseMotion and _rotating:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		_free_camera.rotation.y -= motion.relative.x * 0.004
		_free_camera.rotation.x = clampf(_free_camera.rotation.x - motion.relative.y * 0.004, -1.5, -0.15)


func _ray() -> Dictionary:
	if not ready_for_play:
		return {}
	var camera: Camera3D = _free_camera if free_view else player.camera
	var pointer: Vector2 = get_viewport().get_mouse_position() if free_view else get_viewport().get_visible_rect().size * 0.5
	return _dictionary(_backend.call("cast_ray", camera.project_ray_origin(pointer), camera.project_ray_normal(pointer), 30.0 if free_view else 6.0))


func _update_target() -> void:
	var hit: Dictionary = _ray()
	_update_route(hit)
	_preview.visible = not _paused and player.controls_enabled() and hit.get("hit", false) and not _route.get("active", false)
	if _preview.visible:
		var at: Vector3i = hit.cell + hit.normal
		_preview.position = Vector3(at) * 0.5 + Vector3.ONE * 0.25
	var quantity: int = 0
	var target_text: String = "Aim at a block within 6 m" if not free_view else "Point at a block within 30 m"
	if hit.get("hit", false):
		var cell: Vector3i = hit.cell
		target_text = "%s  /  [%d, %d, %d]" % [
			VoxelWorldData.block_name(_integer(_block_types.get(cell, 0))), cell.x, cell.y, cell.z,
		]
		for row: Dictionary in _state.get("machines", []):
			if row.cell == hit.cell:
				quantity = _integer(row.quantity)
				target_text += "  /  Iron ore: %d" % quantity
	var build_text: String = "右键单格放置  /  朝向：%s  /  R 转向" % ["南", "西", "北", "东"][_facing]
	if _selected == VoxelWorldData.Block.BELT:
		build_text = "右键选起点，再右键提交线路"
		if _route.get("active", false):
			var locked_points: PackedVector3Array = _route.get("locked_points", PackedVector3Array())
			build_text = "右键提交  /  左键取消  /  R 切换轴顺序  /  C 锁定\n%s  ·  %d 格  ·  %d 个锁定点" % [
				"先南北后东西" if _route.get("north_south_first", true) else "先东西后南北",
				_route_cells.size(), locked_points.size(),
			]
			if not _route.get("ok", false):
				build_text += "  /  " + _route_error(str(_route.get("error", "")))
	if VoxelWorldData.is_slope(_selected):
		build_text = "45° 直行斜坡  /  " + build_text
	if not _notice.is_empty():
		build_text += "\n" + _notice
	_status.position.y = 174.0 + float(build_text.count("\n")) * 24.0
	_hud.update_observation(_selected, target_text, build_text, player.controls_enabled(), free_view)


func _select(block: int) -> void:
	if block != _selected:
		_cancel_route()
	if block == 8:
		_notice = "多方块结构尚未接入此试玩。"
		return
	_selected = block
	_update_target()


func _rotate() -> void:
	if _route.get("active", false):
		_accept_route(_route_call("toggle_belt_route_order"))
		_route_dirty = true
	else:
		_facing = (_facing + 1) % 4
	_notice = ""
	_update_target()


func _place() -> void:
	_place_hit(_ray())


func _place_hit(hit: Dictionary) -> void:
	if not ready_for_play or not player.controls_enabled() or _rotating:
		return
	if _selected == VoxelWorldData.Block.BELT:
		if _route.get("active", false):
			_update_route(hit, true)
			var error: String = _route_safety_error()
			if not _route.get("ok", false) or not error.is_empty():
				_route_failed(error if not error.is_empty() else _route_error(str(_route.get("error", ""))))
				return
			var surface_y: float = _route_surface()
			_accept_route(_route_call("commit_belt_route"))
			if _route.get("ok", false):
				if surface_y > player.global_position.y:
					player.raise_to(surface_y)
				_notice = "已建造整条线路。"
				_route_preview.hide()
				_refresh()
			else:
				_route_failed(_route_error(str(_route.get("error", ""))))
		else:
			var target: Variant = _belt_target(hit)
			if target == null:
				return
			_accept_route(_route_call("begin_belt_route", [target, _facing]))
			_route_dirty = true
			if _route.get("ok", false):
				_notice = ""
				_update_route(hit, true)
			else:
				_notice = _route_error(str(_route.get("error", "")))
		return
	if not hit.get("hit", false):
		return
	var at: Vector3i = hit.cell + hit.normal
	var block: int = VoxelWorldData.oriented_slope(_selected, _facing) if _selected in [9, 13] else _selected
	if VoxelWorldData.block_intersects_bounds(at, block, player.occupied_bounds()):
		_notice = "这里与玩家重叠。"
		return
	if free_view and VoxelWorldData.block_intersects_bounds(at, block, _camera_bounds()):
		_notice = "这里与相机重叠。"
		return
	if _command("place_block", [at, block, _facing]):
		_notice = "已放置。"
		_refresh()


func _break() -> void:
	if _route.get("active", false):
		_cancel_route()
		_notice = "已取消线路。"
		return
	var hit: Dictionary = _ray()
	if hit.get("hit", false) and _command("remove_block", [hit.cell]):
		_notice = "已拆除。"
		_refresh()


func _belt_target(hit: Dictionary) -> Variant:
	if not hit.get("hit", false):
		return null
	var at: Vector3i = hit.cell
	var block: int = _block_types.get(at, 0)
	if VoxelWorldData.is_belt(block) or block in [VoxelWorldData.Block.MINER, VoxelWorldData.Block.CHEST]:
		return at
	var normal: Vector3i = hit.normal
	return at + normal if normal != Vector3i.ZERO else null


func _route_call(method: String, arguments: Array = []) -> Dictionary:
	if _backend == null:
		return {"ok": false, "active": false, "error": "backend_closed"}
	return _dictionary(_backend.callv(method, arguments))


func _accept_route(observation: Dictionary) -> void:
	_route = observation
	_route_cells.clear()
	_route_blocks.clear()
	var cells: PackedVector3Array = observation.get("cells", PackedVector3Array())
	var blocks: PackedInt32Array = observation.get("blocks", PackedInt32Array())
	for index: int in range(cells.size()):
		_route_cells.append(Vector3i(cells[index]))
		_route_blocks.append(blocks[index])


func _update_route(hit: Dictionary, force: bool = false) -> void:
	if not _route.get("active", false):
		_route_preview.hide()
		return
	if not player.controls_enabled() or _paused:
		_route_preview.hide()
		return
	var target: Variant = _belt_target(hit)
	if force or _route_dirty or target != _route_target or _revision != _route_revision:
		_accept_route(_route_call("preview_belt_route", [target, _facing]))
		_route_target = target
		_route_revision = _revision
		_route_dirty = false
		var directions: Array[Vector3i] = []
		var existing: Array[int] = []
		var locks: Array[Vector3i] = []
		for facing: int in _route.get("directions", PackedInt32Array()):
			directions.append(DIRECTIONS[facing])
		for block: int in _route.get("existing", PackedInt32Array()):
			existing.append(block)
		for point: Vector3 in _route.get("locked_points", PackedVector3Array()):
			locks.append(Vector3i(point))
		var invalid_route: bool = not _route.get("ok", false)
		_route_preview.show_observation(
			_route_cells, directions, VoxelWorldData.Block.BELT, existing,
			invalid_route, locks, _route_blocks
		)
	else:
		_route_preview.visible = not _route_cells.is_empty()
	var invalid: bool = not _route.get("ok", false) or not _route_safety_error().is_empty()
	_route_preview.set_invalid(invalid, Time.get_ticks_msec() < _route_failure_until)
	_preview.hide()


func _lock_route() -> void:
	_lock_route_hit(_ray())


func _lock_route_hit(hit: Dictionary) -> void:
	if not _route.get("active", false) or not player.controls_enabled() or _rotating:
		return
	_update_route(hit, true)
	if not _route.get("ok", false):
		_route_failed(_route_error(str(_route.get("error", ""))))
		return
	_accept_route(_route_call("lock_belt_route"))
	if not _route.get("ok", false):
		_route_failed(_route_error(str(_route.get("error", ""))))
	_route_dirty = true
	_update_route(hit, true)


func _cancel_route() -> void:
	if _backend != null and _backend.has_method("cancel_belt_route"):
		_backend.call("cancel_belt_route")
	_route.clear()
	_route_cells.clear()
	_route_blocks.clear()
	_route_dirty = true
	_route_target = null
	_route_failure_until = 0
	if _route_preview != null:
		_route_preview.hide()


func _route_failed(message: String) -> void:
	_notice = message
	_route_failure_until = Time.get_ticks_msec() + 180
	_route_preview.set_invalid(true, true)


func _camera_bounds() -> AABB:
	return AABB(_free_camera.global_position - Vector3.ONE * FreeCameraRig.HALF_SIZE,
		Vector3.ONE * FreeCameraRig.HALF_SIZE * 2)


func _route_surface() -> float:
	var occupied: AABB = player.occupied_bounds()
	var highest: float = player.global_position.y
	for index: int in range(_route_cells.size()):
		var at: Vector3i = _route_cells[index]
		var block: int = _route_blocks[index]
		if _block_types.get(at, 0) != VoxelWorldData.Block.AIR or not VoxelWorldData.block_intersects_bounds(at, block, occupied):
			continue
		var bounds: AABB = VoxelWorldData.block_bounds(at, block)
		if VoxelWorldData.is_slope(block):
			var overlap: AABB = bounds.intersection(occupied)
			for x: float in [overlap.position.x, overlap.end.x]:
				for z: float in [overlap.position.z, overlap.end.z]:
					highest = maxf(highest, float(at.y) * VoxelWorldData.CELL_SIZE +
						VoxelWorldData.slope_elevation(at, block, Vector3(x, 0, z)) + VoxelWorldData.BELT_HEIGHT)
		else:
			highest = maxf(highest, bounds.end.y)
	return highest


func _route_safety_error() -> String:
	if free_view:
		for index: int in range(_route_cells.size()):
			var at: Vector3i = _route_cells[index]
			if _block_types.get(at, 0) == VoxelWorldData.Block.AIR and VoxelWorldData.block_intersects_bounds(at, _route_blocks[index], _camera_bounds()):
				return "这里与相机重叠。"
	var surface_y: float = _route_surface()
	if surface_y <= player.global_position.y:
		return ""
	var occupied: AABB = player.occupied_bounds()
	var rise: float = surface_y + player.safe_margin - occupied.position.y
	var headroom: AABB = AABB(Vector3(occupied.position.x, occupied.end.y, occupied.position.z),
		Vector3(occupied.size.x, rise, occupied.size.z)).grow(player.safe_margin)
	# The same observation covers pending colliders and the new batch's ceiling.
	for index: int in range(_route_cells.size()):
		var at: Vector3i = _route_cells[index]
		var block: int = _route_blocks[index]
		if _block_types.get(at, 0) == VoxelWorldData.Block.AIR and not VoxelWorldData.block_intersects_bounds(at, block, occupied):
			if VoxelWorldData.block_intersects_bounds(at, block, headroom):
				return "玩家上方没有足够空间。"
	var first: Vector3i = VoxelWorldData.world_to_cell(headroom.position)
	var last: Vector3i = VoxelWorldData.world_to_cell(headroom.end)
	for x: int in range(first.x, last.x + 1):
		for y: int in range(first.y, last.y + 1):
			for z: int in range(first.z, last.z + 1):
				var at: Vector3i = Vector3i(x, y, z)
				var block: int = _block_types.get(at, 0)
				if block != VoxelWorldData.Block.AIR and VoxelWorldData.block_intersects_bounds(at, block, headroom):
					return "玩家上方没有足够空间。"
	return "" if player.can_raise_to(surface_y) else "玩家上方没有足够空间。"


static func _route_error(error: String) -> String:
	if "InsufficientRamps" in error or "SlopeTurn" in error:
		return "线路长度不足，无法匹配地形高度。"
	if "NoTarget" in error:
		return "请瞄准有效终点。"
	if "Port" in error or "BeltOutput" in error or "MinerHasNoInput" in error:
		return "线路方向与设施端口不匹配。"
	return "无法在此建造：" + error


func _command(method: String, arguments: Array = []) -> bool:
	if _backend == null:
		return false
	var result: Dictionary = _dictionary(_backend.callv(method, arguments))
	if not result.get("ok", false):
		_notice = "操作失败：" + str(result.get("error", "响应无效"))
		return false
	return true


func _refresh() -> void:
	_state = _dictionary(_backend.call("observe_factory"))
	if not _state.get("ok", false):
		_fail("读取工厂失败。")
		return
	if _revision != _integer(_state.revision):
		_revision = _integer(_state.revision)
		_sync_world()
	var positions: PackedVector3Array = _state.ores
	_ores.multimesh.instance_count = positions.size()
	for index: int in range(positions.size()):
		_ores.multimesh.set_instance_transform(index, Transform3D(Basis.IDENTITY, positions[index]))
	var received: int = 0
	for row: Dictionary in _state.machines:
		if row.block == 7:
			received += _integer(row.quantity)
	_status.text = "新后端试玩  /  %s\n生产 %d  ·  箱子收货 %d" % [
		"连续运输" if _state.ruleset == "conveyor_continuous_v1" else "离散运输", _state.produced, received]


func _sync_world() -> void:
	## Only the changed cells replace scene nodes; quantities never rebuild collisions.
	var cells: PackedVector3Array = _state.cells
	var blocks: PackedInt32Array = _state.blocks
	var observed: Dictionary[Vector3i, int] = {}
	for index: int in range(cells.size()):
		var at: Vector3i = Vector3i(cells[index])
		var block: int = blocks[index]
		observed[at] = block
		if _block_types.get(at, 0) == block:
			continue
		_remove_cell(at)
		var bounds: AABB = VoxelWorldData.block_bounds(at, block)
		_cache_block(block)
		var cell_node: Node3D = Node3D.new()
		cell_node.position = bounds.get_center()
		var visual: MeshInstance3D = MeshInstance3D.new()
		visual.name = "Visual"
		visual.mesh = _meshes[block]
		visual.material_override = _materials[block]
		cell_node.add_child(visual)
		var body: StaticBody3D = StaticBody3D.new()
		body.name = "Body"
		var collision: CollisionShape3D = CollisionShape3D.new()
		collision.shape = _shapes[block]
		body.add_child(collision)
		cell_node.add_child(body)
		_world_view.add_child(cell_node)
		_cell_nodes[at] = cell_node
	for at: Vector3i in _block_types:
		if not observed.has(at):
			_remove_cell(at)
	_block_types = observed
	for row: Dictionary in _state.machines:
		var at: Vector3i = row.cell
		var block: int = row.block
		var cell_node: Node3D = _cell_nodes[at]
		if VoxelWorldData.is_belt(block):
			_sync_ports(cell_node, at, block, row)
			continue
		var arrow: MeshInstance3D = cell_node.get_node_or_null("Arrow") as MeshInstance3D
		if arrow == null:
			arrow = MeshInstance3D.new()
			arrow.name = "Arrow"
			arrow.mesh = _arrow_mesh
			arrow.material_override = _arrow_material
			cell_node.add_child(arrow)
		arrow.basis = LogisticsView.arrow_facing(DIRECTIONS[_integer(row.direction)], block)
		var bounds: AABB = VoxelWorldData.block_bounds(at, block)
		var height: float = float(at.y) * 0.5 + VoxelWorldData.slope_elevation(at, block, bounds.get_center()) + 0.092 if VoxelWorldData.is_slope(block) else bounds.end.y + 0.012
		arrow.position = Vector3(0, height - bounds.get_center().y, 0)


func _sync_ports(cell_node: Node3D, at: Vector3i, block: int, row: Dictionary) -> void:
	var ports: Node3D = cell_node.get_node_or_null("Ports") as Node3D
	if ports == null:
		ports = Node3D.new()
		ports.name = "Ports"
		cell_node.add_child(ports)
	var desired: Array[String] = []
	for input: bool in [true, false]:
		var sides: PackedInt32Array = row.inputs if input else row.outputs
		for side: int in sides:
			var port_name: String = "%s%d" % ["In" if input else "Out", side]
			desired.append(port_name)
			var arrow: MeshInstance3D = ports.get_node_or_null(NodePath(port_name)) as MeshInstance3D
			if arrow == null:
				arrow = MeshInstance3D.new()
				arrow.name = port_name
				arrow.mesh = _arrow_mesh
				arrow.material_override = _arrow_material
				ports.add_child(arrow)
			var offset: Vector3 = Vector3(DIRECTIONS[side]) * 0.125
			var point: Vector3 = Vector3(at) * 0.5 + Vector3(0.25, 0, 0.25) + offset
			var height: float = VoxelWorldData.slope_elevation(at, block, point) if VoxelWorldData.is_slope(block) else 0.0
			offset.y = float(at.y) * 0.5 + height + VoxelWorldData.BELT_HEIGHT + 0.012 - cell_node.position.y
			arrow.position = offset
			var motion: Vector3i = -DIRECTIONS[side] if input else DIRECTIONS[side]
			arrow.basis = LogisticsView.arrow_facing(motion, block).scaled(Vector3.ONE * 0.45)
	for child: Node in ports.get_children():
		if not desired.has(String(child.name)):
			ports.remove_child(child)
			child.queue_free()


func _remove_cell(at: Vector3i) -> void:
	var node: Node3D = _cell_nodes.get(at)
	if node != null:
		_world_view.remove_child(node)
		node.queue_free()
		_cell_nodes.erase(at)


func _cache_block(block: int) -> void:
	if _meshes.has(block):
		return
	var bounds: AABB = VoxelWorldData.block_bounds(Vector3i.ZERO, block)
	var mesh: Mesh = _block_mesh(Vector3i.ZERO, block, bounds)
	_meshes[block] = mesh
	_materials[block] = _material(COLORS[mini(block, 6)] if block >= 9 else COLORS[block])
	if VoxelWorldData.is_slope(block):
		_shapes[block] = mesh.create_convex_shape()
	else:
		var shape: BoxShape3D = BoxShape3D.new()
		shape.size = bounds.size
		_shapes[block] = shape


static func _block_mesh(at: Vector3i, block: int, bounds: AABB) -> Mesh:
	if not VoxelWorldData.is_slope(block):
		var box: BoxMesh = BoxMesh.new()
		box.size = bounds.size
		return box
	var points: PackedVector3Array = PackedVector3Array()
	for z: float in [0.0, 0.5]:
		for x: float in [0.0, 0.5]:
			var top: Vector3 = Vector3(at) * 0.5 + Vector3(x, 0, z)
			top.y = float(at.y) * 0.5 + VoxelWorldData.slope_elevation(at, block, top) + 0.08
			points.append(top - bounds.get_center())
			points.append(top - bounds.get_center() - Vector3.UP * 0.08)
	var surface: SurfaceTool = SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index: int in [0, 4, 6, 0, 6, 2, 1, 3, 7, 1, 7, 5, 0, 2, 3, 0, 3, 1, 4, 5, 7, 4, 7, 6, 0, 1, 5, 0, 5, 4, 2, 6, 7, 2, 7, 3]:
		surface.add_vertex(points[index])
	surface.generate_normals()
	return surface.commit()


func _build_interface() -> void:
	var layer: CanvasLayer = CanvasLayer.new()
	layer.name = "Interface"
	add_child(layer)
	_hud = FactoryHud.new()
	_hud.name = "Hud"
	layer.add_child(_hud)
	_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_status = _label("", Vector2(28, 174))
	layer.add_child(_status)
	_inventory_view = InventoryView.new()
	_inventory_view.name = "InventoryView"
	layer.add_child(_inventory_view)
	_inventory_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_inventory_view.bind_inventory(InventoryData.new())
	_inventory_view.close_requested.connect(_close_inventory)
	_menu = SessionMenu.new()
	_menu.name = "SessionMenu"
	layer.add_child(_menu)
	_menu.transport_selected.connect(func(continuous: bool) -> void:
		if _job_id != 0:
			_show_pause_menu()
			_save_message("请等待当前存档操作结束。")
			return
		_menu.confirm_world_reset(func() -> void:
			start_factory("conveyor_continuous_v1" if continuous else "legacy_discrete_v1")
			_show_pause_menu())
	)
	_menu.resume_requested.connect(func() -> void: set_paused(false) if ready_for_play else set_paused(true))
	_menu.return_requested.connect(save_and_return)
	_menu.save_requested.connect(func() -> void: open_save_files(true))
	_menu.load_requested.connect(func() -> void: open_save_files(false))
	_menu.save_confirmed.connect(save_game)
	_menu.load_confirmed.connect(load_game)
	_menu.delete_confirmed.connect(delete_save)
	_menu.backend_settings_changed.connect(_set_save_settings)
	_menu.file_panel_closed.connect(func() -> void:
		_file_mode = ""
		if _job_operation == "load":
			cancel_persistence())
	_menu.hide()


func _show_pause_menu() -> void:
	_menu.show_playground_menu(str(_state.get("ruleset", "")) == "conveyor_continuous_v1",
		ready_for_play and _persistence_ready, not _save_records.is_empty(), world_name,
		autosave_minutes, autosave_retention, world_id)


func _set_save_settings(value: String, minutes: float, retention: int) -> void:
	var trimmed: String = value.strip_edges()
	if not trimmed.is_empty() and trimmed.length() <= 80:
		world_name = trimmed
		_menu.set_world_name(world_name)
	if is_finite(minutes) and minutes >= 0 and minutes <= 1440 and retention >= 1 and retention <= 100:
		autosave_minutes = minutes
		autosave_retention = retention
		_autosave_seconds = 0.0
		_auto_pending = false


func _process(delta: float) -> void:
	poll_persistence()
	advance_autosave(delta)


func advance_autosave(delta: float) -> void:
	if not ready_for_play or _paused or not _persistence_ready or autosave_minutes <= 0:
		return
	_autosave_seconds += delta
	if _autosave_seconds >= autosave_minutes * 60:
		_autosave_seconds = 0.0
		_auto_pending = true
	if _auto_pending and _job_id == 0:
		_auto_pending = false
		save_game(_default_save_name() + "_" + str(_backend.call("new_world_id")).substr(0, 8), false, "auto")


func _session_checkpoint() -> Dictionary:
	return {"world_id": world_id, "world_name": world_name,
		"autosave_minutes": autosave_minutes, "autosave_retention": autosave_retention,
		"player": {"frame": Engine.get_physics_frames(), "position": player.position,
			"velocity": player.velocity, "spawn": player.spawn_position,
			"body_rotation": player.rotation, "rotation": player.camera.rotation,
			"tool": _selected, "build_rotation": _facing, "free_view": free_view,
			"free_position": _free_camera.position, "free_rotation": _free_camera.rotation}}


func _default_save_name() -> String:
	return world_name + "_" + Time.get_datetime_string_from_system().replace(":", "").replace("T", "_")


func _begin_job(operation: String, result: Dictionary) -> bool:
	if not result.get("ok", false):
		_save_message("存档操作失败：" + str(result.get("error", "未知错误")))
		return false
	_job_id = _integer(result.get("job_id", 0))
	_job_operation = operation
	_job_stage = ""
	_menu.set_message("正在读档… [Esc 取消]" if operation == "load" else "正在处理存档…")
	return _job_id != 0


func open_save_files(saving: bool) -> void:
	if not _persistence_ready or _job_id != 0:
		_save_message("存档服务尚未就绪或正在忙碌。")
		return
	set_paused(true)
	_file_mode = "save" if saving else "load"
	_begin_job("list", _dictionary(_backend.call("request_save_list")))


func save_game(save_name: String, overwrite: bool = false, kind: String = "manual") -> void:
	if not _persistence_ready or _job_id != 0:
		_save_message("请等待当前存档操作结束。")
		return
	# Player runs before the parent physics tick; process/menu capture sees the completed frame.
	if _begin_job("exit" if kind == "exit" else "save", _dictionary(_backend.call("request_save",
			_session_checkpoint(), {"name": save_name, "overwrite": overwrite,
				"kind": kind, "sequence": _save_sequence}))):
		_job_kind = kind


func save_and_return(overwrite_manual: bool = false) -> void:
	if not ready_for_play or not _persistence_ready:
		get_tree().change_scene_to_file("res://scenes/session.tscn")
		return
	if _job_id != 0:
		_save_message("请等待当前存档操作结束。")
		return
	set_paused(true)
	if not overwrite_manual:
		for record: Dictionary in _save_records:
			if record.world_id == world_id and record.name == "退出存档" and record.kind != "exit":
				_menu.confirm_overwrite("退出存档", func() -> void: save_and_return(true))
				return
	save_game("退出存档", true, "exit")


func load_game(save_id: String) -> void:
	if not _persistence_ready or _job_id != 0:
		_save_message("请等待当前存档操作结束。")
		return
	_load_was_paused = _paused
	set_paused(true)
	_cancel_route()
	if not _begin_job("load", _dictionary(_backend.call("request_load", save_id))):
		set_paused(_load_was_paused)


func delete_save(save_id: String) -> void:
	if not _persistence_ready or _job_id != 0:
		_save_message("请等待当前存档操作结束。")
		return
	_begin_job("delete", _dictionary(_backend.call("request_delete_save", save_id, _save_sequence)))


func cancel_persistence() -> void:
	if _job_id != 0:
		var result: Dictionary = _dictionary(_backend.call("cancel_save_job", _job_id))
		_menu.set_message("正在取消…" if result.get("cancelled", false) else "已进入提交阶段，等待结果…")


func poll_persistence() -> void:
	if not _persistence_ready or _job_id == 0:
		return
	var result: Dictionary = _dictionary(_backend.call("poll_save_job"))
	if _integer(result.get("job_id", 0)) != _job_id:
		return
	if result.get("active", false):
		var stage: String = str(result.get("state", ""))
		if stage != _job_stage:
			_job_stage = stage
			var labels: Dictionary[String, String] = {"Queued": "等待", "Reading": "读取",
				"Encoding": "编码", "Writing": "写入", "Verifying": "重读校验",
				"Validating": "校验", "Committing": "提交"}
			_menu.set_message("存档：" + str(labels.get(stage, stage)) + "…" +
				(" [Esc 取消]" if _job_operation == "load" else ""))
		return
	var operation: String = _job_operation
	var kind: String = _job_kind
	var identity: int = _job_id
	_job_id = 0
	_job_operation = ""
	_job_kind = ""
	if not result.get("ok", false):
		_save_notice = ""
		if operation == "load":
			set_paused(_load_was_paused)
		_save_message("操作已取消。" if result.get("state", "") == "Cancelled" else
			"存档操作失败：" + str(result.get("error", "未知错误")))
		return
	if operation == "load":
		if not _install_checkpoint(result, identity):
			_backend.call("cancel_save_job", identity)
			set_paused(_load_was_paused)
			_save_message("读档失败，当前世界已保留。")
			return
		set_paused(_load_was_paused)
		if _paused:
			_show_pause_menu()
		_file_mode = ""
		_save_message("读档完成。")
	elif operation == "list":
		var directory: Dictionary = _dictionary(result.get("directory"))
		_save_sequence = _integer(directory.get("sequence", 0))
		_save_records.clear()
		for record: Dictionary in directory.get("records", []):
			_save_records.append(record)
		if not _file_mode.is_empty():
			_menu.show_files(_file_mode == "save", _save_records, _default_save_name())
		if not _save_notice.is_empty():
			_save_message(_save_notice)
			_save_notice = ""
	elif operation == "exit":
		get_tree().change_scene_to_file("res://scenes/session.tscn")
	else:
		if operation == "delete":
			_save_notice = "存档已删除。"
		else:
			_save_notice = "自动保存完成。" if kind == "auto" else "保存完成。"
		_begin_job("list", _dictionary(_backend.call("request_save_list")))


func _install_checkpoint(result: Dictionary, identity: int) -> bool:
	var state: Dictionary = _dictionary(result.get("world"))
	var session: Dictionary = _dictionary(result.get("session"))
	var pose: Dictionary = _dictionary(session.get("player"))
	if not state.get("ok", false) or pose.is_empty() or not state.get("cells") is PackedVector3Array \
			or not state.get("blocks") is PackedInt32Array:
		return false
	var cells: PackedVector3Array = state.cells
	var blocks: PackedInt32Array = state.blocks
	if cells.size() != blocks.size():
		return false
	# Build a complete detached candidate. The live world/collisions remain installed.
	var previous_world: Node3D = _world_view
	var previous_state: Dictionary = _state
	var previous_nodes: Dictionary[Vector3i, Node3D] = _cell_nodes
	var previous_blocks: Dictionary[Vector3i, int] = _block_types
	var candidate: Node3D = Node3D.new()
	candidate.name = "World"
	_world_view = candidate
	_state = state
	_cell_nodes = {}
	_block_types = {}
	_sync_world()
	var candidate_nodes: Dictionary[Vector3i, Node3D] = _cell_nodes
	var candidate_blocks: Dictionary[Vector3i, int] = _block_types
	_world_view = previous_world
	_state = previous_state
	_cell_nodes = previous_nodes
	_block_types = previous_blocks
	if candidate.get_child_count() != cells.size():
		candidate.free()
		return false
	var committed: Dictionary = _dictionary(_backend.call("commit_prepared_load", identity))
	if not committed.get("ok", false):
		candidate.free()
		return false
	remove_child(previous_world)
	previous_world.queue_free()
	add_child(candidate)
	_world_view = candidate
	_cell_nodes = candidate_nodes
	_block_types = candidate_blocks
	_revision = _integer(state.revision)
	world_id = session.world_id
	world_name = session.world_name
	autosave_minutes = session.autosave_minutes
	autosave_retention = session.autosave_retention
	_autosave_seconds = 0
	_auto_pending = false
	player.position = pose.position
	player.velocity = pose.velocity
	player.spawn_position = pose.spawn
	player.rotation = pose.body_rotation
	player.camera.rotation = pose.rotation
	_selected = pose.tool
	_facing = pose.build_rotation
	free_view = pose.free_view
	player.set_free_view(free_view)
	player.set_session_paused(true)
	_free_camera.position = pose.free_position
	_free_camera.rotation = pose.free_rotation
	_free_camera.current = free_view
	player.camera.current = not free_view
	_select(_selected)
	ready_for_play = true
	_refresh()
	_update_target()
	return true


func _save_message(message: String) -> void:
	_menu.set_message(message)
	_hud.show_build_notice(message)


func _fail(message: String) -> void:
	ready_for_play = false
	_status.text = message
	set_paused(true)


static func _dictionary(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value
	return {}


static func _integer(value: Variant) -> int:
	if value is int:
		return value
	return 0


static func _label(text: String, at: Vector2) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.position = at
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_override("font", preload("res://assets/fonts/build_ui.ttf"))
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", Color("#ffffff"))
	label.add_theme_color_override("font_shadow_color", Color("#182c36"))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	return label


static func _material(color: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9
	return material
