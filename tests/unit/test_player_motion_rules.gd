extends GdUnitTestSuite


func test_real_gravity_and_maximum_jump_height() -> void:
	assert_float(PlayerMotionRules.STEP_HEIGHT).is_equal(0.5)
	for gravity: float in [4.905, 9.81, 19.62]:
		for configured_height: float in [0.4, 1.6]:
			for rate: int in [60, 120]:
				var speed: float = PlayerMotionRules.jump_speed(configured_height, gravity)
				var height: float = 0.0
				var peak: float = 0.0
				for frame: int in range(rate * 2):
					var step: Vector2 = PlayerMotionRules.vertical_step(speed, 1.0 / float(rate), gravity)
					height += step.x
					speed = step.y
					peak = maxf(peak, height)
				assert_float(peak).is_between(configured_height - 0.01, configured_height + 0.000001)


func test_free_fall_displacement_matches_real_gravity() -> void:
	var step: Vector2 = PlayerMotionRules.vertical_step(0.0, 1.0, 9.81)
	assert_float(step.x).is_equal_approx(-4.905, 0.00001)
	assert_float(step.y).is_equal_approx(-9.81, 0.00001)


func test_zero_gravity_and_non_positive_height_do_not_launch_player() -> void:
	assert_float(PlayerMotionRules.jump_speed(1.6, 0.0)).is_equal(0.0)
	assert_float(PlayerMotionRules.jump_speed(-1.0, 9.81)).is_equal(0.0)
	assert_vector(PlayerMotionRules.vertical_step(2.0, 0.5, 0.0)).is_equal(Vector2(1.0, 2.0))
