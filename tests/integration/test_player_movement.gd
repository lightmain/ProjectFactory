extends GdUnitTestSuite

var _game: FactoryGame
var _original_physics_rate: int
var _original_gravity: float


func before_test() -> void:
	_original_physics_rate = Engine.physics_ticks_per_second
	_original_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity"))
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
	Engine.physics_ticks_per_second = _original_physics_rate
	ProjectSettings.set_setting("physics/3d/default_gravity", _original_gravity)


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


func _jump_peak(rate: int) -> float:
	Engine.physics_ticks_per_second = rate
	await get_tree().physics_frame
	var start_y: float = _game.player.position.y
	Input.action_press("jump")
	await get_tree().physics_frame
	await get_tree().physics_frame
	Input.action_release("jump")
	var peak: float = _game.player.position.y
	for frame: int in range(rate * 2):
		await get_tree().physics_frame
		peak = maxf(peak, _game.player.position.y)
	assert_bool(_game.player.is_on_floor()).is_true()
	return peak - start_y


func test_real_jump_peaks_at_one_point_six_metres() -> void:
	for rate: int in [60, 120]:
		assert_float(await _jump_peak(rate)).is_between(1.59, 1.601)


func test_project_gravity_controls_real_fall_and_preserves_jump_height() -> void:
	ProjectSettings.set_setting("physics/3d/default_gravity", 19.62)
	_game.free()
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_game = auto_free(scene.instantiate()) as FactoryGame
	add_child(_game)
	_game.player.set_physics_process(false)
	_game.player.respawn(Vector3(0.25, 4.0, 2.0))
	var delta: float = 1.0 / float(Engine.physics_ticks_per_second)
	_game.player._physics_process(delta)
	assert_float(_game.player.position.y).is_equal_approx(
		4.0 - 19.62 * delta * delta * 0.5, 0.000001
	)
	assert_float(_game.player.velocity.y).is_equal_approx(-19.62 * delta, 0.000001)
	_game.player.respawn(Vector3(0.25, 0.01, 2.0))
	_game.player.set_physics_process(true)
	for frame: int in range(10):
		await get_tree().physics_frame
	for rate: int in [60, 120]:
		assert_float(await _jump_peak(rate)).is_between(1.59, 1.601)


func test_exported_jump_height_changes_actual_jump() -> void:
	var exported: bool = false
	for property: Dictionary in _game.player.get_property_list():
		if property.get("name") == "max_jump_height":
			var usage: int = int(property.get("usage", 0))
			exported = (
				usage & PROPERTY_USAGE_EDITOR != 0 and usage & PROPERTY_USAGE_STORAGE != 0
			)
	assert_bool(exported).is_true()
	if not exported:
		return
	assert_float(float(_game.player.get("max_jump_height"))).is_equal(1.6)
	_game.player.set("max_jump_height", 0.4)
	for rate: int in [60, 120]:
		assert_float(await _jump_peak(rate)).is_between(0.39, 0.401)


func test_walks_up_quarter_metre_step_without_jump() -> void:
	_obstacle(Vector3(2, 0.25, 0.5), Vector3(0.25, 0.125, 1))
	await get_tree().physics_frame
	await _walk(18)
	assert_float(_game.player.position.z).is_less(1.25)
	assert_float(_game.player.position.y).is_between(0.245, 0.26)
	assert_bool(_game.player.is_on_floor()).is_true()


func test_walks_up_half_metre_step_without_jump() -> void:
	_obstacle(Vector3(2, 0.5, 0.5), Vector3(0.25, 0.25, 1))
	await get_tree().physics_frame
	await _walk(18)
	assert_float(_game.player.position.z).is_less(1.25)
	assert_float(_game.player.position.y).is_between(0.495, 0.51)
	assert_bool(_game.player.is_on_floor()).is_true()


func test_walks_up_real_voxel_without_jump_at_both_physics_rates() -> void:
	for rate: int in [60, 120]:
		Engine.physics_ticks_per_second = rate
		_game.player.respawn(Vector3(0.25, 0.01, 2))
		for frame: int in range(10):
			await get_tree().physics_frame
		assert_bool(_game.world_data.place_block(
			Vector3i(0, 0, 2), VoxelWorldData.Block.STONE, _game.player.occupied_bounds()
		)).is_true()
		await get_tree().physics_frame
		await _walk(int(float(rate) * 0.2))
		assert_float(_game.player.position.z).is_less(1.5)
		assert_float(_game.player.position.y).is_between(0.495, 0.51)
		assert_bool(_game.player.is_on_floor()).is_true()
		assert_bool(_game.world_data.break_block(Vector3i(0, 0, 2))).is_true()


func test_obstacle_above_half_metre_is_too_high_to_step() -> void:
	_obstacle(Vector3(2, 0.51, 0.5), Vector3(0.25, 0.255, 1))
	await get_tree().physics_frame
	await _walk()
	assert_float(_game.player.position.z).is_greater(1.5)
	assert_float(_game.player.position.y).is_less(0.02)


func test_two_voxel_wall_is_too_high_to_step() -> void:
	assert_bool(_game.world_data.place_block(
		Vector3i(0, 0, 2), VoxelWorldData.Block.STONE, _game.player.occupied_bounds()
	)).is_true()
	assert_bool(_game.world_data.place_block(
		Vector3i(0, 1, 2), VoxelWorldData.Block.STONE, _game.player.occupied_bounds()
	)).is_true()
	await get_tree().physics_frame
	await _walk()
	assert_float(_game.player.position.z).is_greater(1.5)
	assert_float(_game.player.position.y).is_less(0.02)


func test_step_does_not_push_head_through_low_ceiling() -> void:
	_obstacle(Vector3(2, 0.5, 0.5), Vector3(0.25, 0.25, 1))
	_obstacle(Vector3(2, 0.2, 3), Vector3(0.25, 1.95, 1))
	await get_tree().physics_frame
	await _walk()
	assert_float(_game.player.position.z).is_greater(1.5)
	assert_float(_game.player.position.y).is_less(0.02)


func test_lower_step_remains_walkable_with_only_required_headroom() -> void:
	_obstacle(Vector3(2, 0.25, 0.5), Vector3(0.25, 0.125, 1))
	_obstacle(Vector3(2, 0.2, 3), Vector3(0.25, 2.2, 1))
	await get_tree().physics_frame
	await _walk(18)
	assert_float(_game.player.position.z).is_less(1.25)
	assert_float(_game.player.position.y).is_between(0.245, 0.26)
	assert_bool(_game.player.is_on_floor()).is_true()


func test_airborne_player_cannot_step_up_an_obstacle() -> void:
	_obstacle(Vector3(2, 0.5, 0.5), Vector3(0.25, 0.25, 1))
	_game.player.position = Vector3(0.25, 0.1, 1.6)
	_game.player.velocity = Vector3(0, 1.0, 0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_bool(_game.player.is_on_floor()).is_false()
	await _walk(2)
	assert_float(_game.player.position.z).is_greater(1.5)
	assert_float(_game.player.position.y).is_less(0.2)
