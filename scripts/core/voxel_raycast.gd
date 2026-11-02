class_name VoxelRaycast
extends RefCounted
## Grid DDA, independent of the render/physics rebuild schedule.


static func cast(
	world: VoxelWorldData, origin: Vector3, direction: Vector3, max_distance: float
) -> VoxelHit:
	if (
		world == null or not origin.is_finite() or not direction.is_finite()
		or direction.is_zero_approx() or not is_finite(max_distance) or max_distance < 0.0
	):
		return null
	var ray: Vector3 = direction.normalized()
	var cell: Vector3i = VoxelWorldData.world_to_cell(origin)
	var step: Vector3i = Vector3i(int(signf(ray.x)), int(signf(ray.y)), int(signf(ray.z)))
	var next_distance: Vector3 = Vector3(INF, INF, INF)
	var distance_step: Vector3 = Vector3(INF, INF, INF)
	for axis: int in range(3):
		if step[axis] == 0:
			continue
		var boundary: float = float(cell[axis] + (1 if step[axis] > 0 else 0))
		next_distance[axis] = (boundary * VoxelWorldData.CELL_SIZE - origin[axis]) / ray[axis]
		distance_step[axis] = VoxelWorldData.CELL_SIZE / absf(ray[axis])
	var distance: float = 0.0
	var normal: Vector3i = Vector3i.ZERO
	while distance <= max_distance:
		var block: int = world.get_block(cell)
		if block != VoxelWorldData.Block.AIR:
			if block != VoxelWorldData.Block.BELT:
				return VoxelHit.new(cell, normal, distance)
			var hit: VoxelHit = _cast_bounds(
				cell, VoxelWorldData.block_bounds(cell, block), origin, ray, max_distance
			)
			if hit != null:
				return hit
		var axis: int = 0
		if next_distance.y < next_distance.x:
			axis = 1
		if next_distance.z < next_distance[axis]:
			axis = 2
		distance = next_distance[axis]
		cell[axis] += step[axis]
		normal = Vector3i.ZERO
		normal[axis] = -step[axis]
		next_distance[axis] += distance_step[axis]
	return null


static func _cast_bounds(
	cell: Vector3i, bounds: AABB, origin: Vector3, ray: Vector3, max_distance: float
) -> VoxelHit:
	var entry: float = 0.0
	var exit_distance: float = INF
	var normal: Vector3i = Vector3i.ZERO
	for axis: int in range(3):
		if ray[axis] == 0.0:
			if origin[axis] < bounds.position[axis] or origin[axis] > bounds.end[axis]:
				return null
			continue
		var near_distance: float = (bounds.position[axis] - origin[axis]) / ray[axis]
		var far_distance: float = (bounds.end[axis] - origin[axis]) / ray[axis]
		if near_distance > far_distance:
			var swap: float = near_distance
			near_distance = far_distance
			far_distance = swap
		# A surface origin still has an entry face; strict interior origins do not.
		if near_distance >= entry:
			entry = near_distance
			normal = Vector3i.ZERO
			normal[axis] = -int(signf(ray[axis]))
		exit_distance = minf(exit_distance, far_distance)
		if entry > exit_distance:
			return null
	if entry > max_distance:
		return null
	return VoxelHit.new(cell, normal, entry)
