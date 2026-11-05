class_name FactoryPlayer
extends CharacterBody3D

signal break_requested
signal place_requested
signal block_selected(block: int)
signal build_rotation_requested
signal build_waypoint_requested
signal respawn_requested
signal inventory_requested
signal focus_lost
signal controls_capture_changed(captured: bool)
signal view_mode_requested
signal camera_input_requested(event: InputEvent)
signal free_cancel_requested
signal focus_restored
signal pause_requested

const BODY_RADIUS: float = 0.28
const BODY_HEIGHT: float = 1.75

@export var move_speed: float = 4.0
## Maximum rise above the takeoff point, in metres.
@export var max_jump_height: float = 1.6
@export var mouse_sensitivity: float = 0.0025

@onready var camera: Camera3D = $Camera3D
@onready var collision: CollisionShape3D = $CollisionShape3D

var spawn_position: Vector3
var _captured: bool = false
var _inventory_open: bool = false
var _jump_requires_release: bool = false
var _jump_block_frames: int = 0
var _free_view: bool = false
var _free_rotating: bool = false
var _focused: bool = true
var _gravity: float = 0.0
var body_visual: MeshInstance3D
var _session_paused: bool = false


func _ready() -> void:
	spawn_position = position
	body_visual = MeshInstance3D.new()
	body_visual.name = "BodyVisual"
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = Vector3(BODY_RADIUS * 2, BODY_HEIGHT, BODY_RADIUS * 2)
	body_visual.mesh = mesh
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = Color("#ff982e")
	body_visual.material_override = material
	body_visual.position.y = BODY_HEIGHT * 0.5
	body_visual.hide()
	add_child(body_visual)
	set_controls_captured(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_focused = false
		_free_rotating = false
		set_controls_captured(false)
		focus_lost.emit()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_focused = true
		focus_restored.emit()


func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func configure_gravity(gravity: float) -> void:
	_gravity = gravity if is_finite(gravity) and gravity >= 0.0 else 0.0


func set_controls_captured(captured: bool) -> void:
	var previous: bool = _captured
	_captured = captured and not _inventory_open and not _free_view and not _session_paused
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _captured else Input.MOUSE_MODE_VISIBLE
	if previous != _captured:
		controls_capture_changed.emit(_captured)


func controls_captured() -> bool:
	return _captured


func controls_enabled() -> bool:
	return not _session_paused and not _inventory_open and (_captured or (_free_view and _focused))


func set_session_paused(paused: bool) -> void:
	_session_paused = paused
	_free_rotating = false
	_jump_requires_release = true
	_jump_block_frames = 2
	if paused:
		set_controls_captured(false)


func set_free_view(enabled: bool) -> void:
	_free_view = enabled
	_free_rotating = false
	body_visual.visible = enabled
	_jump_requires_release = true
	_jump_block_frames = 2
	set_controls_captured(not enabled)


func set_inventory_open(open: bool) -> void:
	_inventory_open = open
	_free_rotating = false
	_jump_requires_release = true
	# Idle input can become just_pressed on the following physics tick.
	_jump_block_frames = 2
	if open:
		set_controls_captured(false)


func occupied_bounds() -> AABB:
	return AABB(
		global_position + Vector3(-BODY_RADIUS, 0, -BODY_RADIUS),
		Vector3(BODY_RADIUS * 2.0, BODY_HEIGHT, BODY_RADIUS * 2.0)
	)


func can_raise_to(surface_y: float) -> bool:
	var rise: float = surface_y + safe_margin - global_position.y
	return rise <= 0.0 or not test_move(global_transform, Vector3.UP * rise)


func raise_to(surface_y: float) -> void:
	global_position.y = maxf(global_position.y, surface_y + safe_margin)
	velocity.y = maxf(0.0, velocity.y)


func respawn(at: Vector3) -> void:
	global_position = at
	velocity = Vector3.ZERO


func _unhandled_input(event: InputEvent) -> void:
	handle_input(event)


func handle_input(event: InputEvent) -> void:
	# Public input boundary also permits deterministic headless integration tests.
	if _session_paused:
		return
	if event.is_action_pressed("toggle_inventory") and not event.is_echo():
		inventory_requested.emit()
		return
	if _inventory_open:
		if event.is_action_pressed("toggle_mouse") and not event.is_echo():
			inventory_requested.emit()
		return
	if event.is_action_pressed("toggle_mouse") and not event.is_echo():
		_free_rotating = false
		camera_input_requested.emit(event)
		free_cancel_requested.emit()
		pause_requested.emit()
		return
	if event.is_action_pressed("toggle_view") and not event.is_echo():
		view_mode_requested.emit()
		return
	if _free_view:
		if not _focused:
			return
		camera_input_requested.emit(event)
		if event is InputEventMouseMotion:
			return
		if event is InputEventMouseButton:
			var free_button: InputEventMouseButton = event as InputEventMouseButton
			if free_button.button_index == MOUSE_BUTTON_MIDDLE:
				_free_rotating = free_button.pressed
				return
		if not _free_rotating:
			_handle_build_input(event)
		return
	if not _captured:
		if event is InputEventMouseButton:
			var button: InputEventMouseButton = event as InputEventMouseButton
			if button.pressed:
				set_controls_captured(true)
		return
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		camera.rotation.y -= motion.relative.x * mouse_sensitivity
		camera.rotation.x = clampf(
			camera.rotation.x - motion.relative.y * mouse_sensitivity, -1.5, 1.5
		)
	else:
		_handle_build_input(event)


func _handle_build_input(event: InputEvent) -> void:
	if event.is_action_pressed("break_block"):
		break_requested.emit()
	elif event.is_action_pressed("place_block"):
		place_requested.emit()
	elif event.is_action_pressed("select_grass"):
		block_selected.emit(VoxelWorldData.Block.GRASS)
	elif event.is_action_pressed("select_dirt"):
		block_selected.emit(VoxelWorldData.Block.DIRT)
	elif event.is_action_pressed("select_stone"):
		block_selected.emit(VoxelWorldData.Block.STONE)
	elif event.is_action_pressed("select_miner"):
		block_selected.emit(VoxelWorldData.Block.MINER)
	elif event.is_action_pressed("select_belt"):
		block_selected.emit(VoxelWorldData.Block.BELT)
	elif event.is_action_pressed("select_chest"):
		block_selected.emit(VoxelWorldData.Block.CHEST)
	elif event.is_action_pressed("rotate_build") and not event.is_echo():
		build_rotation_requested.emit()
	elif event.is_action_pressed("lock_belt_path") and not event.is_echo():
		build_waypoint_requested.emit()


func _physics_process(delta: float) -> void:
	# Camera rotation never affects the body's physics transform.
	global_basis = Basis.IDENTITY
	var grounded: bool = is_on_floor()
	if _jump_block_frames > 0:
		_jump_block_frames -= 1
	elif _jump_requires_release and not Input.is_action_pressed("jump") and not Input.is_action_just_pressed("jump"):
		_jump_requires_release = false
	var movement: Vector2 = Vector2.ZERO
	if _captured:
		movement = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		if grounded and not _jump_requires_release and Input.is_action_just_pressed("jump"):
			velocity.y = PlayerMotionRules.jump_speed(max_jump_height, _gravity)
			grounded = false
	var direction: Vector3 = Basis(Vector3.UP, camera.rotation.y) * Vector3(movement.x, 0, movement.y)
	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed
	var horizontal_velocity: Vector3 = Vector3(velocity.x, 0, velocity.z)
	var stepped: bool = false
	if grounded and velocity.y <= 0.0:
		stepped = _try_step(horizontal_velocity * delta)
	var vertical: Vector2 = PlayerMotionRules.vertical_step(velocity.y, delta, _gravity)
	velocity.y = vertical.x / delta
	if stepped:
		# The sweep consumed this tick's horizontal displacement.
		velocity.x = 0.0
		velocity.z = 0.0
	move_and_slide()
	velocity.y = 0.0 if is_on_floor() or is_on_ceiling() else vertical.y
	if stepped:
		velocity.x = horizontal_velocity.x
		velocity.z = horizontal_velocity.z
	if global_position.y < -8.0:
		respawn_requested.emit()


func _try_step(horizontal: Vector3) -> bool:
	if horizontal.is_zero_approx() or not test_move(global_transform, horizontal):
		return false
	var start: Transform3D = global_transform
	var lift: Vector3 = Vector3.UP * (PlayerMotionRules.STEP_HEIGHT + safe_margin * 2.0)
	var clearance: KinematicCollision3D = KinematicCollision3D.new()
	if test_move(start, lift, clearance):
		# A low step may fit even when there is no room for the maximum lift.
		lift = Vector3.UP * maxf(0.0, clearance.get_travel().y)
	if lift.y <= safe_margin:
		return false
	var raised: Transform3D = start
	raised.origin += lift
	if test_move(raised, horizontal):
		return false
	var forward: Transform3D = raised
	forward.origin += horizontal
	var landing: KinematicCollision3D = KinematicCollision3D.new()
	if not test_move(forward, Vector3.DOWN * (lift.y + floor_snap_length), landing):
		return false
	if landing.get_normal().dot(Vector3.UP) < cos(floor_max_angle):
		return false
	var destination: Vector3 = forward.origin + landing.get_travel()
	var rise: float = destination.y - start.origin.y
	if rise <= safe_margin or rise > PlayerMotionRules.STEP_HEIGHT + safe_margin * 2.0:
		return false
	global_position = destination
	return true
