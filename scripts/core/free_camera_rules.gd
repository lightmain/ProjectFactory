class_name FreeCameraRules
extends RefCounted


static func move(
	world: VoxelWorldData, start: Vector3, motion: Vector3, anchor: Vector3,
	max_distance: float, half_size: float = 0.12, soften: bool = true
) -> Vector3:
	if world == null or not start.is_finite() or not motion.is_finite() or not anchor.is_finite():
		return start
	if not is_finite(max_distance) or max_distance <= 0 or not is_finite(half_size) or half_size <= 0:
		return start
	var adjusted: Vector3 = motion
	var radial: Vector3 = start - anchor
	var distance: float = radial.length()
	if soften and distance > 0:
		var normal: Vector3 = radial / distance
		var outward: float = maxf(0, adjusted.dot(normal))
		var band: float = minf(2, max_distance)
		var progress: float = clampf((distance - (max_distance - band)) / band, 0, 1)
		var damping: float = progress * progress * (3 - 2 * progress)
		adjusted -= normal * outward * damping
	var target: Vector3 = start + adjusted
	# After the rig has selected a safe path, individual engine-side steps must
	# clamp their own axis without assuming other axes can move as well.
	if soften:
		target = anchor + (target - anchor).limit_length(max_distance)
	var position: Vector3 = start
	# Free room on the sphere before moving tangentially; a blocked correction
	# still leaves every following axis constrained by the safety radius.
	for axis: int in motion_axes(start, target, anchor):
		var offset: Vector3 = position - anchor
		offset[axis] = 0
		var extent: float = sqrt(maxf(0.0, max_distance * max_distance - offset.length_squared()))
		var destination: float = clampf(
			target[axis], anchor[axis] - extent, anchor[axis] + extent
		)
		position[axis] += _axis_motion(world, position, axis, destination - position[axis], half_size)
	return position


static func motion_axes(start: Vector3, target: Vector3, anchor: Vector3) -> Array[int]:
	var axes: Array[int] = []
	for axis: int in range(3):
		if absf(target[axis] - anchor[axis]) < absf(start[axis] - anchor[axis]):
			axes.append(axis)
	for axis: int in range(3):
		if not axes.has(axis):
			axes.append(axis)
	return axes


static func move_linear(
	world: VoxelWorldData, start: Vector3, motion: Vector3, anchor: Vector3,
	max_distance: float, half_size: float = 0.12
) -> Vector3:
	# Zoom keeps its center ray: shorten travel instead of sliding sideways.
	if world == null or not start.is_finite() or not motion.is_finite() or not anchor.is_finite():
		return start
	if not is_finite(max_distance) or max_distance <= 0 or not is_finite(half_size) or half_size <= 0:
		return start
	var travel: float = motion.length()
	if travel <= 0:
		return start
	var direction: Vector3 = motion / travel
	var radial: Vector3 = start - anchor
	var radius: float = radial.length()
	var along: float = radial.dot(direction)
	if along > 0 and radius > 0:
		var band: float = minf(2, max_distance)
		var progress: float = clampf((radius - (max_distance - band)) / band, 0, 1)
		var damping: float = progress * progress * (3 - 2 * progress)
		travel *= 1 - damping * pow(along / radius, 2)
	var sphere_exit: float = -along + sqrt(maxf(
		0, along * along + max_distance * max_distance - radial.length_squared()
	))
	travel = minf(travel, maxf(0, sphere_exit))
	var end: Vector3 = start + direction * travel
	var sweep: AABB = AABB(start.min(end), start.max(end) - start.min(end)).grow(half_size)
	var first: Vector3i = VoxelWorldData.world_to_cell(sweep.position).max(VoxelWorldData.MIN_CELL)
	var last: Vector3i = VoxelWorldData.world_to_cell(sweep.end).min(VoxelWorldData.MAX_CELL - Vector3i.ONE)
	for x: int in range(first.x, last.x + 1):
		for y: int in range(first.y, last.y + 1):
			for z: int in range(first.z, last.z + 1):
				var cell: Vector3i = Vector3i(x, y, z)
				var block: int = world.get_block(cell)
				if block == VoxelWorldData.Block.AIR:
					continue
				var entry: float = _ray_entry(
					VoxelWorldData.block_bounds(cell, block).grow(half_size), start, direction
				)
				if entry >= 0:
					travel = minf(travel, maxf(0, entry - 0.001))
	return start + direction * travel


static func _ray_entry(bounds: AABB, start: Vector3, direction: Vector3) -> float:
	var entry: float = 0
	var exit_distance: float = INF
	for axis: int in range(3):
		if is_zero_approx(direction[axis]):
			if start[axis] <= bounds.position[axis] or start[axis] >= bounds.end[axis]:
				return -1
			continue
		var near_distance: float = (bounds.position[axis] - start[axis]) / direction[axis]
		var far_distance: float = (bounds.end[axis] - start[axis]) / direction[axis]
		entry = maxf(entry, minf(near_distance, far_distance))
		exit_distance = minf(exit_distance, maxf(near_distance, far_distance))
		if entry > exit_distance:
			return -1
	return entry


static func _axis_motion(
	world: VoxelWorldData, position: Vector3, axis: int, motion: float, half_size: float
) -> float:
	if is_zero_approx(motion):
		return 0.0
	var end: Vector3 = position
	end[axis] += motion
	var sweep: AABB = AABB(position.min(end), position.max(end) - position.min(end)).grow(half_size)
	var first: Vector3i = VoxelWorldData.world_to_cell(sweep.position).max(VoxelWorldData.MIN_CELL)
	var last: Vector3i = VoxelWorldData.world_to_cell(sweep.end).min(VoxelWorldData.MAX_CELL - Vector3i.ONE)
	var travel: float = absf(motion)
	var direction_sign: float = signf(motion)
	for x: int in range(first.x, last.x + 1):
		for y: int in range(first.y, last.y + 1):
			for z: int in range(first.z, last.z + 1):
				var cell: Vector3i = Vector3i(x, y, z)
				var block: int = world.get_block(cell)
				if block == VoxelWorldData.Block.AIR:
					continue
				var bounds: AABB = VoxelWorldData.block_bounds(cell, block).grow(half_size)
				var overlaps: bool = true
				for other: int in range(3):
					if other != axis and (
						position[other] <= bounds.position[other] or position[other] >= bounds.end[other]
					):
						overlaps = false
				if not overlaps:
					continue
				var near: float = bounds.position[axis] if direction_sign > 0 else bounds.end[axis]
				var distance: float = (near - position[axis]) * direction_sign
				if distance >= 0:
					travel = minf(travel, maxf(0.0, distance - 0.001))
				elif position[axis] > bounds.position[axis] and position[axis] < bounds.end[axis]:
					travel = 0
	return travel * direction_sign
