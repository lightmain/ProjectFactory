class_name OrthogonalRoute
extends RefCounted
## Pure finite-route geometry. No world, block, port or scene dependencies.


static func footprint(start: Vector3i, end: Vector3i, north_south_first: bool) -> Array[Vector3i]:
	var cells: Array[Vector3i] = [start]
	var cursor: Vector3i = start
	var axes: Array[int] = [2, 0]
	if not north_south_first:
		axes.reverse()
	for axis: int in axes:
		var step: int = signi(end[axis] - cursor[axis])
		while cursor[axis] != end[axis]:
			cursor[axis] += step
			cells.append(cursor)
	return cells


static func fit_heights(
	floors: Array[int], capacities: Array[int], start_height: int, end_height: int
) -> Array[int]:
	if floors.is_empty() or capacities.size() != floors.size() - 1:
		return []
	for capacity: int in capacities:
		if capacity < 0 or capacity > 1:
			return []
	var heights: Array[int] = [floors[0]]
	for index: int in range(1, floors.size()):
		# A ramp's lower end must clear its own column as well.
		heights.append(maxi(floors[index - 1], floors[index]))
	heights[0] = maxi(heights[0], start_height)
	heights[-1] = maxi(heights[-1], end_height)
	for index: int in range(capacities.size()):
		heights[index + 1] = maxi(heights[index + 1], heights[index] - capacities[index])
	for index: int in range(capacities.size() - 1, -1, -1):
		heights[index] = maxi(heights[index], heights[index + 1] - capacities[index])
	if heights[0] != start_height or heights[-1] != end_height:
		return []
	return heights
