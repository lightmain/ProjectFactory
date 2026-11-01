class_name FactoryPlayer
extends CharacterBody3D

signal break_requested
signal place_requested
signal block_selected(block: int)
signal respawn_requested
signal inventory_requested
signal focus_lost

const BODY_RADIUS: float = 0.28
const BODY_HEIGHT: float = 1.75

@export var move_speed: float = 4.0
@export var mouse_sensitivity: float = 0.0025

@onready var camera: Camera3D = $Camera3D
@onready var collision: CollisionShape3D = $CollisionShape3D

var spawn_position: Vector3
var _captured: bool = false
var _inventory_open: bool = false
var _jump_requires_release: bool = false
var _jump_block_frames: int = 0


func _ready() -> void:
	spawn_position = position
	set_controls_captured(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		set_controls_captured(false)
		focus_lost.emit()


func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func set_controls_captured(captured: bool) -> void:
	_captured = captured and not _inventory_open
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _captured else Input.MOUSE_MODE_VISIBLE


func controls_captured() -> bool:
	return _captured


func set_inventory_open(open: bool) -> void:
	_inventory_open = open
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


func respawn(at: Vector3) -> void:
	global_position = at
	velocity = Vector3.ZERO


func _unhandled_input(event: InputEvent) -> void:
	handle_input(event)


func handle_input(event: InputEvent) -> void:
	# Public input boundary also permits deterministic headless integration tests.
	if event.is_action_pressed("toggle_inventory") and not event.is_echo():
		inventory_requested.emit()
		return
	if _inventory_open:
		if event.is_action_pressed("toggle_mouse") and not event.is_echo():
			inventory_requested.emit()
		return
	if event.is_action_pressed("toggle_mouse"):
		set_controls_captured(not _captured)
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
	elif event.is_action_pressed("break_block"):
		break_requested.emit()
	elif event.is_action_pressed("place_block"):
		place_requested.emit()
	elif event.is_action_pressed("select_grass"):
		block_selected.emit(VoxelWorldData.Block.GRASS)
	elif event.is_action_pressed("select_dirt"):
		block_selected.emit(VoxelWorldData.Block.DIRT)
	elif event.is_action_pressed("select_stone"):
		block_selected.emit(VoxelWorldData.Block.STONE)


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
			velocity.y = PlayerMotionRules.jump_speed()
			grounded = false
	var direction: Vector3 = Basis(Vector3.UP, camera.rotation.y) * Vector3(movement.x, 0, movement.y)
	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed
	var horizontal_velocity: Vector3 = Vector3(velocity.x, 0, velocity.z)
	var stepped: bool = false
	if grounded and velocity.y <= 0.0:
		stepped = _try_step(horizontal_velocity * delta)
	var vertical: Vector2 = PlayerMotionRules.vertical_step(velocity.y, delta)
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
	if test_move(start, lift):
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
