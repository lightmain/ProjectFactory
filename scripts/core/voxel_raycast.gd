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
		if world.get_block(cell) != VoxelWorldData.Block.AIR:
			return VoxelHit.new(cell, normal, distance)
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
