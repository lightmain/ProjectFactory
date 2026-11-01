extends GdUnitTestSuite

var _game: FactoryGame


func before_test() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_game = auto_free(scene.instantiate()) as FactoryGame
	add_child(_game)
	_game.player.position = Vector3(0.25, 0.01, 2)
	_game.player.set_controls_captured(true)
	for frame: int in range(10):
		await get_tree().physics_frame


func after_test() -> void:
	Input.action_release("move_forward")
	Input.action_release("jump")
	_game.player.set_controls_captured(false)


func _obstacle(size: Vector3, center: Vector3) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	body.collision_layer = 1
	body.position = center
	var shape: BoxShape3D = BoxShape3D.new()
	shape.size = size
	var collision: CollisionShape3D = CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	_game.add_child(body)


func _walk(frames: int = 25) -> void:
	Input.action_press("move_forward")
	for frame: int in range(frames):
		await get_tree().physics_frame
	Input.action_release("move_forward")


func test_box_stays_axis_aligned_when_view_rotates() -> void:
	var collision: CollisionShape3D = _game.player.get_node("CollisionShape3D") as CollisionShape3D
	assert_bool(collision.shape is BoxShape3D).is_true()
	var before: AABB = _game.player.occupied_bounds()
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.relative = Vector2(150, 60)
	_game.player.handle_input(motion)
	assert_vector(collision.global_basis.x).is_equal_approx(Vector3.RIGHT, Vector3.ONE * 0.00001)
	assert_vector(collision.global_basis.y).is_equal_approx(Vector3.UP, Vector3.ONE * 0.00001)
	assert_vector(collision.global_basis.z).is_equal_approx(Vector3.BACK, Vector3.ONE * 0.00001)
	assert_vector(_game.player.occupied_bounds().size).is_equal(before.size)
	assert_float(_game.player.camera.rotation.y).is_not_equal(0.0)


func test_real_jump_peaks_at_one_point_five_metres() -> void:
	var start_y: float = _game.player.position.y
	Input.action_press("jump")
	await get_tree().physics_frame
	await get_tree().physics_frame
	Input.action_release("jump")
	var peak: float = _game.player.position.y
	for frame: int in range(90):
		await get_tree().physics_frame
		peak = maxf(peak, _game.player.position.y)
	assert_float(peak - start_y).is_between(1.49, 1.501)
	assert_bool(_game.player.is_on_floor()).is_true()


func test_walks_up_quarter_metre_step_without_jump() -> void:
	_obstacle(Vector3(2, 0.25, 0.5), Vector3(0.25, 0.125, 1))
	await get_tree().physics_frame
	await _walk(18)
	assert_float(_game.player.position.z).is_less(1.25)
	assert_float(_game.player.position.y).is_between(0.245, 0.26)
	assert_bool(_game.player.is_on_floor()).is_true()


func test_half_metre_wall_is_too_high_to_step() -> void:
	_obstacle(Vector3(2, 0.5, 0.5), Vector3(0.25, 0.25, 1))
	await get_tree().physics_frame
	await _walk()
	assert_float(_game.player.position.z).is_greater(1.5)
	assert_float(_game.player.position.y).is_less(0.02)


func test_step_does_not_push_head_through_low_ceiling() -> void:
	_obstacle(Vector3(2, 0.25, 0.5), Vector3(0.25, 0.125, 1))
	_obstacle(Vector3(2, 0.2, 3), Vector3(0.25, 1.95, 1))
	await get_tree().physics_frame
	await _walk()
	assert_float(_game.player.position.z).is_greater(1.5)
	assert_float(_game.player.position.y).is_less(0.02)


func test_airborne_player_cannot_step_up_an_obstacle() -> void:
	_obstacle(Vector3(2, 0.25, 0.5), Vector3(0.25, 0.125, 1))
	_game.player.position = Vector3(0.25, 0.1, 1.6)
	_game.player.velocity = Vector3(0, 1.0, 0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_bool(_game.player.is_on_floor()).is_false()
	await _walk(2)
	assert_float(_game.player.position.z).is_greater(1.5)
	assert_float(_game.player.position.y).is_less(0.2)
