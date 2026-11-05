class_name FreeCameraRig
extends CharacterBody3D
## Independent camera body; pure world sweeps also cover pending collider edits.

const HALF_SIZE: float = 0.12
const INITIAL_HEIGHT: float = 4.0
const INITIAL_PITCH: float = -75.0
const ZOOM_FACTOR: float = 0.85
const MIN_SURFACE_DISTANCE: float = 0.5
const CENTER_RAY_DISTANCE: float = 40.0

@export var move_speed: float = 5.0
@export_range(4.0, 40.0) var max_distance: float = 12.0
@export var mouse_sensitivity: float = 0.0025

var camera: Camera3D
var active: bool = false
var cursor_position: Vector2
var _player: FactoryPlayer
var _world: VoxelWorldData
var _input_enabled: bool = true
var _rotating: bool = false
var _saved_cursor: Vector2
var _zoom_steps: int = 0
var _orbit_motion: Vector2 = Vector2.ZERO
var _orbit_anchor: Vector3
var _has_orbit_anchor: bool = false


func _ready() -> void:
	collision_layer = 0
	collision_mask = 1
	safe_margin = 0.001
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3.ONE * HALF_SIZE * 2
	shape.shape = box
	add_child(shape)
	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.fov = 75
	camera.near = 0.05
	camera.far = 80
	add_child(camera)


func configure(player: FactoryPlayer, world: VoxelWorldData) -> void:
	_player = player
	_world = world


func enter() -> void:
	stop_rotating()
	_zoom_steps = 0
	active = true
	cursor_position = get_viewport().get_mouse_position()
	global_position = _player.camera.global_position
	var destination: Vector3 = anchor_position() + Vector3.UP * INITIAL_HEIGHT
	move_and_collide(FreeCameraRules.move(
		_world, global_position, destination - global_position, anchor_position(), max_distance
	) - global_position)
	# Godot's world north is -Z; zero yaw keeps it at the top of the view.
	camera.rotation = Vector3(deg_to_rad(INITIAL_PITCH), 0, 0)
	camera.make_current()


func leave() -> void:
	stop_rotating()
	_zoom_steps = 0
	active = false
	velocity = Vector3.ZERO
	_player.camera.make_current()


func anchor_position() -> Vector3:
	return _player.global_position + Vector3.UP * FactoryPlayer.BODY_HEIGHT


func occupied_bounds() -> AABB:
	return AABB(global_position - Vector3.ONE * HALF_SIZE, Vector3.ONE * HALF_SIZE * 2)


func set_input_enabled(enabled: bool) -> void:
	_input_enabled = enabled
	if not enabled:
		stop_rotating()
		_zoom_steps = 0


func is_rotating() -> bool:
	return _rotating


func stop_rotating() -> void:
	_orbit_motion = Vector2.ZERO
	_has_orbit_anchor = false
	if not _rotating:
		return
	_rotating = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	cursor_position = _saved_cursor
	Input.warp_mouse(_saved_cursor)


func handle_input(event: InputEvent) -> void:
	if not active or not _input_enabled:
		return
	if event is InputEventMouseButton:
		var button: InputEventMouseButton = event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_MIDDLE:
			if button.pressed:
				_saved_cursor = cursor_position
				_zoom_steps = 0
				_orbit_motion = Vector2.ZERO
				var hit: VoxelHit = _center_hit()
				_has_orbit_anchor = hit != null
				if hit != null:
					_orbit_anchor = camera.global_position - camera.global_basis.z * hit.distance
				_rotating = true
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			else:
				stop_rotating()
		elif not _rotating:
			cursor_position = button.position
			if button.pressed:
				if button.button_index == MOUSE_BUTTON_WHEEL_UP:
					_zoom_steps = mini(_zoom_steps + 1, 32)
				elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
					_zoom_steps = maxi(_zoom_steps - 1, -32)
	elif event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		if _rotating:
			if motion.relative.is_finite():
				_orbit_motion += motion.relative * mouse_sensitivity
				_orbit_motion = _orbit_motion.clamp(Vector2.ONE * -PI, Vector2.ONE * PI)
		else:
			cursor_position = motion.position
	elif event.is_action_pressed("toggle_mouse"):
		stop_rotating()
		_zoom_steps = 0


func _center_hit() -> VoxelHit:
	return VoxelRaycast.cast(_world, camera.global_position, -camera.global_basis.z, CENTER_RAY_DISTANCE)


func _zoom() -> void:
	var steps: int = _zoom_steps
	_zoom_steps = 0
	if steps == 0:
		return
	var hit: VoxelHit = _center_hit()
	if hit == null:
		return
	if steps > 0 and hit.distance <= MIN_SURFACE_DISTANCE:
		return
	var distance: float = maxf(MIN_SURFACE_DISTANCE, hit.distance * pow(ZOOM_FACTOR, steps))
	var motion: Vector3 = -camera.global_basis.z * (hit.distance - distance)
	var destination: Vector3 = FreeCameraRules.move_linear(
		_world, global_position, motion, anchor_position(), max_distance, HALF_SIZE
	)
	move_and_collide(destination - global_position)


func _orbit() -> void:
	var motion: Vector2 = _orbit_motion
	_orbit_motion = Vector2.ZERO
	if not _has_orbit_anchor or motion.is_zero_approx():
		return
	var radius: float = global_position.distance_to(_orbit_anchor)
	if radius < 0.001:
		return
	var initial: Vector3 = camera.rotation
	var target: Vector3 = Vector3(
		clampf(initial.x - motion.y, deg_to_rad(-85), deg_to_rad(85)),
		initial.y - motion.x, 0
	)
	var angle: float = absf(target.x - initial.x) + absf(target.y - initial.y)
	# Small chords stay within the sweep margin of the true arc.
	var segments: int = maxi(1, ceili(angle / minf(0.02, 0.08 / radius)))
	for segment: int in range(1, segments + 1):
		var rotation_step: Vector3 = initial.lerp(target, float(segment) / segments)
		var desired: Vector3 = _orbit_anchor + Basis.from_euler(rotation_step).z * radius
		_move_safe(desired - global_position)
		camera.look_at(_orbit_anchor, Vector3.UP)
		if global_position.distance_to(desired) > 0.002:
			break


func move_camera(movement: Vector3, delta: float) -> void:
	if not active or not _input_enabled or not movement.is_finite() or delta <= 0:
		return
	var motion: Vector3 = Basis(Vector3.UP, camera.rotation.y) * movement.limit_length() * move_speed * delta
	_move_safe(motion)


func _move_safe(motion: Vector3) -> void:
	var anchor: Vector3 = anchor_position()
	var target: Vector3 = FreeCameraRules.move(
		_world, global_position, motion, anchor, max_distance, HALF_SIZE
	)
	# The body follows the same axis path as the pure sweep, including pending
	# collider edits. Recheck after an engine collision blocks a correction.
	for axis: int in FreeCameraRules.motion_axes(global_position, target, anchor):
		var step: Vector3 = Vector3.ZERO
		step[axis] = target[axis] - global_position[axis]
		var destination: Vector3 = FreeCameraRules.move(
			_world, global_position, step, anchor, max_distance, HALF_SIZE, false
		)
		step[axis] = destination[axis] - global_position[axis]
		move_and_collide(step)


func _physics_process(delta: float) -> void:
	if not active:
		return
	if global_position.distance_to(anchor_position()) > max_distance + 0.001:
		enter()
	if not _input_enabled:
		return
	if _rotating:
		_orbit()
		return
	_zoom()
	var horizontal: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	move_camera(Vector3(horizontal.x, 0, horizontal.y), delta)
