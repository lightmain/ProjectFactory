extends GdUnitTestSuite
## A small exhaustive relaxation oracle verifies the greatest solution.
## The production solver is additionally bounded on large chains and cycles.


func _oracle(
	desired: Array[float], leaders: Array[int], weights: Array[float]
) -> Array[float]:
	var result: Array[float] = desired.duplicate()
	for pass_index: int in range(desired.size() + 1):
		for index: int in range(desired.size()):
			if leaders[index] >= 0:
				result[index] = minf(result[index], result[leaders[index]] + weights[index])
	return result


func test_long_reverse_dependency_chain_visits_each_node_a_bounded_number_of_times() -> void:
	for count: int in [16, 128, 1024]:
		var desired: Array[float] = []
		var leaders: Array[int] = []
		var weights: Array[float] = []
		for index: int in range(count):
			desired.append(0.2 if index == count - 1 else 1.0)
			leaders.append(index + 1 if index < count - 1 else -1)
			weights.append(0.0)
		var solver: BeltPositionSolver = BeltPositionSolver.new()
		var actual: Array[float] = solver.solve(desired, leaders, weights)
		for position: float in actual:
			assert_float(position).is_equal_approx(0.2, 0.000001)
		assert_int(solver.work).is_less_equal(12 * count)


func test_zero_weight_full_ring_moves_as_far_as_its_tightest_head_allows() -> void:
	for count: int in [16, 128, 1024]:
		var desired: Array[float] = []
		var leaders: Array[int] = []
		var weights: Array[float] = []
		for index: int in range(count):
			desired.append(1.0 if index % 2 == 0 else 0.5)
			leaders.append((index + 1) % count)
			weights.append(0.5 if index % 2 == 0 else -0.5)
		desired[count - 2] = 0.75
		var solver: BeltPositionSolver = BeltPositionSolver.new()
		var actual: Array[float] = solver.solve(desired, leaders, weights)
		for index: int in range(count):
			assert_float(actual[index]).is_equal_approx(
				0.75 if index % 2 == 0 else 0.25, 0.000001
			)
		assert_int(solver.work).is_less_equal(12 * count)


func test_mixed_trees_and_nonnegative_cycles_match_an_independent_maximum_oracle() -> void:
	var random: RandomNumberGenerator = RandomNumberGenerator.new()
	random.seed = 472
	for trial: int in range(250):
		var count: int = 25
		var desired: Array[float] = []
		var leaders: Array[int] = []
		var weights: Array[float] = []
		var old: Array[float] = []
		for index: int in range(count):
			old.append(float(random.randi_range(0, 2)) * 0.5)
			desired.append(old[index] + random.randf())
			leaders.append(random.randi_range(-1, count - 1))
		for index: int in range(count):
			var leader: int = leaders[index]
			var slack: float = float(random.randi_range(0, 1)) * 0.5
			weights.append(old[index] - old[leader] + slack if leader >= 0 else 0.0)
		var solver: BeltPositionSolver = BeltPositionSolver.new()
		var actual: Array[float] = solver.solve(desired, leaders, weights)
		var expected: Array[float] = _oracle(desired, leaders, weights)
		for index: int in range(count):
			assert_float(actual[index]).is_equal_approx(expected[index], 0.000001)
			assert_float(actual[index]).is_greater_equal(old[index] - 0.000001)
		assert_int(solver.work).is_less_equal(12 * count)
