extends GdUnitTestSuite

var _game: FactoryGame


func before_test() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_game = auto_free(scene.instantiate()) as FactoryGame
	add_child(_game)
	_game.player.set_physics_process(false)
	_game.player.set_controls_captured(true)
	await get_tree().physics_frame


func after_test() -> void:
	_game.player.set_controls_captured(false)


func _ground(cell: Vector3i) -> VoxelHit:
	return VoxelHit.new(cell + Vector3i.DOWN, Vector3i.UP, 1.0)


func test_same_batch_upper_belt_blocks_player_lift_and_preserves_entire_route() -> void:
	_game._select_block(VoxelWorldData.Block.BELT)
	_game.player.global_position = Vector3(0.25, 0, 0.25)
	# This target is above the swept headroom. Its underside selects the
	# planned upper endpoint; it cannot itself explain a rejected lift.
	_game.world_data.place_block(Vector3i(0, 6, 0), VoxelWorldData.Block.STONE)
	_game.belt_placement.begin(_ground(Vector3i(0, 2, 0)), Vector3i.RIGHT)
	for end: Vector3i in [Vector3i(6, 2, 0), Vector3i(6, 5, 6), Vector3i(0, 5, 6)]:
		_game.belt_placement.preview(_ground(end), Vector3i.RIGHT)
		assert_str(_game.belt_placement.error).is_empty()
		assert_bool(_game.belt_placement.lock_preview()).is_true()
	_game.player.camera.look_at(Vector3(0.26, 3.0, 0.26), Vector3.UP)
	_game._update_preview(_game.current_hit(), true)
	assert_str(_game.belt_placement.error).is_empty()
	assert_vector(_game.belt_placement.path[-1]).is_equal(Vector3i(0, 5, 0))
	var surface: float = _game._overlapping_belt_surface()
	assert_float(surface).is_equal_approx(1.08, 0.001)
	var count: int = _game.world_data.block_count()
	var prefix: Array[Vector3i] = _game.belt_placement.locked_path.duplicate()
	_game._place_target()
	assert_int(_game.world_data.block_count()).is_equal(count)
	assert_bool(_game.belt_placement.active).is_true()
	assert_array(_game.belt_placement.locked_path).contains_exactly(prefix)
	assert_float(_game.player.global_position.y).is_equal(0.0)
	assert_str(_game.hud._notice.text).is_equal("无法在此建造")
