extends GdUnitTestSuite


func test_real_gravity_and_maximum_jump_height() -> void:
	assert_float(PlayerMotionRules.GRAVITY).is_equal(9.81)
	assert_float(PlayerMotionRules.MAX_JUMP_HEIGHT).is_equal(1.5)
	assert_float(PlayerMotionRules.STEP_HEIGHT).is_equal(0.25)
	for rate: int in [60, 120]:
		var speed: float = PlayerMotionRules.jump_speed()
		var height: float = 0.0
		var peak: float = 0.0
		for frame: int in range(rate * 2):
			var step: Vector2 = PlayerMotionRules.vertical_step(speed, 1.0 / float(rate))
			height += step.x
			speed = step.y
			peak = maxf(peak, height)
		assert_float(peak).is_between(1.49, 1.500001)


func test_free_fall_displacement_matches_real_gravity() -> void:
	var step: Vector2 = PlayerMotionRules.vertical_step(0.0, 1.0)
	assert_float(step.x).is_equal_approx(-4.905, 0.00001)
	assert_float(step.y).is_equal_approx(-9.81, 0.00001)
