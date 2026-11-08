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
		var segment_end: float = minf(max_distance, minf(next_distance.x, minf(next_distance.y, next_distance.z)))
		var nearest: VoxelHit
		var block: int = world.get_block(cell)
		if block != VoxelWorldData.Block.AIR:
			if not VoxelWorldData.is_belt(block):
				nearest = VoxelHit.new(cell, normal, distance, origin + ray * distance)
			else:
				nearest = cast_block(cell, block, origin, ray, segment_end)
				if nearest != null and nearest.distance < distance - 0.000001:
					nearest = null
		var below: Vector3i = cell + Vector3i.DOWN
		var below_block: int = world.get_block(below)
		if VoxelWorldData.is_slope(below_block):
			var lip: VoxelHit = cast_block(below, below_block, origin, ray, segment_end)
			if lip != null and lip.distance >= distance - 0.000001 and (
				nearest == null or lip.distance < nearest.distance
			):
				nearest = lip
		if nearest != null:
			return nearest
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


static func cast_block(
	cell: Vector3i, block: int, origin: Vector3, ray: Vector3, max_distance: float,
	half_size: float = 0.0
) -> VoxelHit:
	var bounds: AABB = VoxelWorldData.block_bounds(cell, block).grow(half_size)
	if not VoxelWorldData.is_slope(block):
		return _cast_bounds(cell, bounds, origin, ray, max_distance)
	var flat: AABB = VoxelWorldData.block_bounds(cell, VoxelWorldData.Block.BELT).grow(half_size)
	var gradient: Vector3 = Vector3(VoxelWorldData.slope_direction(block)) * VoxelWorldData.slope_rise(block)
	# Shear into flat plate coordinates. Parameter t remains world distance.
	var transformed_origin: Vector3 = origin
	transformed_origin.y -= VoxelWorldData.slope_elevation(cell, block, origin)
	var transformed_ray: Vector3 = ray
	transformed_ray.y -= gradient.dot(ray)
	# The moving camera box extends along both the horizontal and vertical axes.
	flat.position.y -= half_size
	flat.size.y += half_size * 2.0
	var hit: VoxelHit = _cast_bounds(cell, flat, transformed_origin, transformed_ray, max_distance)
	if hit == null:
		return null
	var outer: VoxelHit = _cast_bounds(cell, bounds, origin, ray, max_distance)
	if outer == null:
		return null
	var entry: float = maxf(hit.distance, outer.distance)
	var point: Vector3 = origin + ray * entry
	var projected: Vector3 = point
	projected.y -= VoxelWorldData.slope_elevation(cell, block, point)
	if not flat.grow(0.000001).has_point(projected) or not bounds.grow(0.000001).has_point(point):
		return null
	return VoxelHit.new(cell, hit.normal if hit.distance >= outer.distance else outer.normal, entry, point)


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
	return VoxelHit.new(cell, normal, entry, origin + ray * entry)
