class_name BeltPathfinder
extends RefCounted
## Breadth-first direction states: shortest distance, then fewest corners.
## A state is (cell.x, cell.z, incoming index); all cells share start.y.


static func find(
	world: VoxelWorldData, start: Vector3i, end: Vector3i, preferred: Vector3i,
	start_exit: Vector3i, end_output: Vector3i, end_is_chest: bool,
	blocked: Dictionary[Vector3i, bool], allow_belts: bool = false,
	initial_direction: Vector3i = Vector3i.ZERO
) -> Array[Vector3i]:
	var axes: Array[Vector3i] = [preferred]
	for turn: int in range(3):
		var previous: Vector3i = axes[-1]
		axes.append(Vector3i(-previous.z, 0, previous.x))
	var initial: int = axes.find(initial_direction)
	var root: Vector3i = Vector3i(start.x, start.z, initial if initial >= 0 else 4)
	var queue: Array[Vector3i] = [root]
	var distances: Dictionary[Vector3i, int] = {root: 0}
	var corners: Dictionary[Vector3i, int] = {root: 0}
	var parents: Dictionary[Vector3i, Vector3i] = {}
	var read: int = 0
	var goal: Vector3i = root
	var best_distance: int = 2147483647
	var best_corners: int = 2147483647
	while read < queue.size():
		var state: Vector3i = queue[read]
		read += 1
		var distance: int = distances[state]
		if distance > best_distance:
			break
		var cell: Vector3i = Vector3i(state.x, start.y, state.y)
		if cell == end:
			var terminal_turn: int = (
				1 if state.z < 4 and end_output != Vector3i.ZERO and axes[state.z] != end_output else 0
			)
			var total_corners: int = corners[state] + terminal_turn
			if total_corners < best_corners:
				goal = state
				best_distance = distance
				best_corners = total_corners
			continue
		for axis: int in range(4):
			var direction: Vector3i = axes[axis]
			if state == root and start_exit != Vector3i.ZERO and direction != start_exit:
				continue
			var next: Vector3i = cell + direction
			if next == start or blocked.has(next) or not world.is_in_bounds(next):
				continue
			if next == end and end_output != Vector3i.ZERO:
				if (end_is_chest and direction != end_output) or direction == -end_output:
					continue
			var kind: int = world.get_block(next)
			if next != end and kind != VoxelWorldData.Block.AIR:
				if not allow_belts or kind != VoxelWorldData.Block.BELT:
					continue
			var key: Vector3i = Vector3i(next.x, next.z, axis)
			var turns: int = corners[state] + (1 if state.z < 4 and state.z != axis else 0)
			if not distances.has(key):
				distances[key] = distance + 1
				corners[key] = turns
				parents[key] = state
				queue.append(key)
			elif distances[key] == distance + 1 and turns < corners[key]:
				# All parents in this layer are processed before the next layer.
				corners[key] = turns
				parents[key] = state
	var result: Array[Vector3i] = []
	if best_distance == 2147483647:
		return result
	var cursor: Vector3i = goal
	while cursor != root:
		result.append(Vector3i(cursor.x, start.y, cursor.y))
		cursor = parents[cursor]
	result.append(start)
	result.reverse()
	return result
