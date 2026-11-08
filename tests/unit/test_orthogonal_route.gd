extends GdUnitTestSuite


func test_both_axis_orders_in_all_quadrants() -> void:
	for x: int in [-2, 2]:
		for z: int in [-3, 3]:
			for north_first: bool in [true, false]:
				var start: Vector3i = Vector3i(-5, 7, -6)
				var end: Vector3i = start + Vector3i(x, 10, z)
				var route: Array[Vector3i] = OrthogonalRoute.footprint(start, end, north_first)
				assert_array(route).has_size(6)
				if route.size() != 6:
					continue
				assert_vector(route[0]).is_equal(start)
				assert_vector(route[-1]).is_equal(Vector3i(end.x, start.y, end.z))
				var corner: int = absi(z) if north_first else absi(x)
				assert_vector(route[corner]).is_equal(
					start + (Vector3i(0, 0, z) if north_first else Vector3i(x, 0, 0))
				)
				for index: int in range(1, route.size()):
					var step: Vector3i = route[index] - route[index - 1]
					assert_int(absi(step.x) + absi(step.z)).is_equal(1)


func test_single_cell_and_long_straight_route() -> void:
	assert_array(OrthogonalRoute.footprint(Vector3i.ZERO, Vector3i(0, 9, 0), true)).contains_exactly([Vector3i.ZERO])
	var route: Array[Vector3i] = OrthogonalRoute.footprint(Vector3i.ZERO, Vector3i(1000, 0, 0), true)
	assert_array(route).has_size(1001)
	assert_vector(route[-1]).is_equal(Vector3i(1000, 0, 0))


func test_flat_route_stays_at_the_lowest_ground() -> void:
	assert_array(OrthogonalRoute.fit_heights([0, 0, 0, 0], [1, 1, 1], 0, 0)).contains_exactly([0, 0, 0, 0])


func test_obstacle_climbs_then_descends_without_horizontal_detour() -> void:
	assert_array(OrthogonalRoute.fit_heights([0, 1, 0, 0], [1, 1, 1], 0, 0)).contains_exactly([0, 1, 1, 0])


func test_corner_moves_climb_back_to_lower_straight_cells() -> void:
	assert_array(OrthogonalRoute.fit_heights([0, 0, 2, 0, 0, 0], [1, 1, 0, 1, 1], 0, 0)).contains_exactly([0, 1, 2, 2, 1, 0])


func test_steps_use_all_available_ramps_in_both_directions() -> void:
	assert_array(OrthogonalRoute.fit_heights([0, 0, 0, 3], [1, 1, 1], 0, 3)).contains_exactly([0, 1, 2, 3])
	assert_array(OrthogonalRoute.fit_heights([0, 0, 0, 0], [1, 1, 1], 3, 0)).contains_exactly([3, 2, 1, 0])


func test_exhausted_ramps_or_fixed_flat_start_fail() -> void:
	assert_array(OrthogonalRoute.fit_heights([0, 0, 3, 0, 0, 0], [1, 1, 0, 1, 1], 0, 0)).is_empty()
	assert_array(OrthogonalRoute.fit_heights([0, 0, 0, 4], [1, 1, 1], 0, 4)).is_empty()
	assert_array(OrthogonalRoute.fit_heights([0, 1, 0, 0], [0, 1, 1], 0, 0)).is_empty()
	assert_array(OrthogonalRoute.fit_heights([0], [], 0, 1)).is_empty()


func test_invalid_array_contract_returns_no_route() -> void:
	assert_array(OrthogonalRoute.fit_heights([], [], 0, 0)).is_empty()
	assert_array(OrthogonalRoute.fit_heights([0, 0], [], 0, 0)).is_empty()
	assert_array(OrthogonalRoute.fit_heights([0, 0], [2], 0, 0)).is_empty()
