class_name BeltPlacement
extends RefCounted
## A reversible belt build session. Nothing reaches the world until commit.

var active: bool = false
var path: Array[Vector3i] = []
var locked_path: Array[Vector3i] = []
var locked_points: Array[Vector3i] = []
var directions: Array[Vector3i] = []
var blocks: Array[int] = []
var north_south_first: bool = true
var _locked_blocks: Array[int] = []
var _locked_directions: Array[Vector3i] = []
var error: String = ""
var _world: VoxelWorldData
var _logistics: LogisticsData
var _start_block: int
var _start_direction: Vector3i
var _end_block: int
var _end_direction: Vector3i
var _preferred: Vector3i


func toggle_route_order() -> void:
	if active:
		north_south_first = not north_south_first


func bind_world(world: VoxelWorldData, logistics: LogisticsData) -> void:
	_world = world
	_logistics = logistics
	cancel()


func begin(hit: VoxelHit, preferred: Vector3i) -> bool:
	error = ""
	if hit == null:
		error = "请瞄准有效位置"
		return false
	var cell: Vector3i = _target_cell(hit)
	var block: int = _world.get_block(cell)
	if block == VoxelWorldData.Block.AIR:
		error = _empty_cell_error(cell)
	elif not LogisticsData.is_machine(block) or VoxelWorldData.is_slope(block):
		error = "该位置已被占用"
	if not error.is_empty():
		return false
	_start_block = block
	_start_direction = _logistics.direction_at(cell)
	_end_block = block
	_end_direction = _start_direction
	_preferred = preferred
	locked_path.assign([cell])
	path.assign(locked_path)
	directions.assign([preferred])
	blocks.assign([VoxelWorldData.Block.BELT])
	_locked_blocks.assign(blocks)
	_locked_directions.assign(directions)
	north_south_first = true
	active = true
	if block in [VoxelWorldData.Block.MINER, VoxelWorldData.Block.CHEST]:
		error = _empty_cell_error(cell + _start_direction)
		if not error.is_empty():
			var reason: String = error
			cancel()
			error = reason
			return false
	return true


func preview(hit: VoxelHit, preferred: Vector3i) -> void:
	if not active:
		return
	_preferred = preferred
	path.assign(locked_path)
	blocks.assign(_locked_blocks)
	directions.assign(_locked_directions)
	error = _validate_prefix()
	if not error.is_empty():
		return
	if hit == null:
		error = "请瞄准有效位置"
		return
	var end: Vector3i = _target_cell(hit)
	if locked_path.size() == 1 and end == locked_path[0] and _start_block in [
		VoxelWorldData.Block.MINER, VoxelWorldData.Block.CHEST,
	]:
		end += _start_direction
	_end_block = _world.get_block(end)
	_end_direction = _logistics.direction_at(end)
	var after_downhill: bool = VoxelWorldData.is_slope(_locked_blocks[-1]) and (
		VoxelWorldData.slope_rise(_locked_blocks[-1]) < 0
	)
	# A locked ramp is immutable. Its successor receives its outlet; the ramp
	# itself must not become the first cell of the next height calculation.
	if after_downhill and end == locked_path[-1]:
		error = _validate_path()
		return
	var start: Vector3i = locked_path[-1]
	var preserved_count: int = locked_path.size() - 1
	if after_downhill:
		start += _locked_directions[-1]
		preserved_count = locked_path.size()
	var suffix: Array[Vector3i] = OrthogonalRoute.footprint(start, end, north_south_first)
	var suffix_directions: Array[Vector3i] = _route_directions(suffix)
	if after_downhill:
		if suffix.size() == 1 and _end_block == VoxelWorldData.Block.AIR:
			suffix_directions[0] = _locked_directions[-1]
		path.append_array(suffix)
		directions.append_array(suffix_directions)
	else:
		path.append_array(suffix.slice(1))
		directions[-1] = suffix_directions[0]
		directions.append_array(suffix_directions.slice(1))
	if path.size() > preserved_count:
		path[-1] = end
	blocks.resize(path.size())
	for index: int in range(preserved_count, path.size()):
		blocks[index] = VoxelWorldData.Block.BELT
	if _end_block == VoxelWorldData.Block.MINER:
		error = "矿机没有输入口"
	elif _end_block == VoxelWorldData.Block.AIR:
		if not _world.is_in_bounds(end):
			error = "超出世界边界"
	elif _end_block not in [VoxelWorldData.Block.BELT, VoxelWorldData.Block.CHEST]:
		error = "该位置已被占用"
	if not error.is_empty():
		return
	if not after_downhill and suffix.size() == 1 and end.y != start.y:
		path.append(end)
		blocks.append(VoxelWorldData.Block.BELT)
		directions.append(_preferred)
		error = "直线坡道不足，无法连接高度"
		return
	error = _port_error()
	if not error.is_empty():
		return
	var floors: Array[int] = []
	var capacities: Array[int] = []
	var prefix_tops: Dictionary[Vector2i, int] = {}
	for index: int in range(preserved_count):
		var cell: Vector3i = locked_path[index]
		var column: Vector2i = Vector2i(cell.x, cell.z)
		var top: int = cell.y + (2 if VoxelWorldData.is_slope(_locked_blocks[index]) else 1)
		var previous_top: int = prefix_tops[column] if prefix_tops.has(column) else _world.minimum.y
		prefix_tops[column] = maxi(previous_top, top)
	for index: int in range(suffix.size()):
		var cell: Vector3i = suffix[index]
		var floor_height: int = end.y
		if index == 0 and not after_downhill:
			floor_height = start.y
			if locked_points.is_empty() and _start_block == VoxelWorldData.Block.AIR and suffix.size() > 1:
				# Only lower the base if the cell below the selected inlet is
				# actually free, including slope lips and the world boundary.
				var down_block: int = VoxelWorldData.Block.BELT_DOWN + VoxelWorldData.SLOPE_DIRECTIONS.find(suffix_directions[0])
				if _empty_cell_error(locked_path[-1] + Vector3i.DOWN, down_block).is_empty():
					floor_height -= 1
		elif index < suffix.size() - 1:
			floor_height = _column_floor(cell, prefix_tops)
		floors.append(floor_height)
		var can_slope: bool = index == 0 or suffix_directions[index - 1] == suffix_directions[index]
		if index == 0:
			if after_downhill:
				can_slope = suffix_directions[0] == _locked_directions[-1]
			elif not locked_points.is_empty() or _start_block != VoxelWorldData.Block.AIR:
				can_slope = false
		if index < suffix.size() - 1:
			capacities.append(1 if can_slope else 0)
		elif _end_block == VoxelWorldData.Block.AIR and (suffix.size() > 1 or after_downhill):
			# One virtual port expresses the last cell's outlet. Both ends
			# clear end.y, so this capacity permits descent, never ascent.
			floors.append(end.y)
			capacities.append(1 if can_slope else 0)
	var heights: Array[int] = OrthogonalRoute.fit_heights(floors, capacities, start.y, end.y)
	if heights.is_empty():
		error = "直线坡道不足，无法连接高度"
		return
	for index: int in range(suffix.size()):
		var rise: int = heights[index + 1] - heights[index] if index + 1 < heights.size() else 0
		var block: int = VoxelWorldData.Block.BELT
		if rise != 0:
			var rotation: int = VoxelWorldData.SLOPE_DIRECTIONS.find(suffix_directions[index])
			block = (VoxelWorldData.Block.BELT_UP if rise > 0 else VoxelWorldData.Block.BELT_DOWN) + rotation
		var cell: Vector3i = suffix[index]
		cell.y = mini(heights[index], heights[index] + rise)
		var path_index: int = preserved_count + index
		path[path_index] = cell
		blocks[path_index] = block
	error = _validate_path()


func lock_preview() -> bool:
	if not active or not error.is_empty() or path.is_empty():
		return false
	if _world.get_block(path[-1]) != VoxelWorldData.Block.AIR:
		return false
	locked_path.assign(path)
	_locked_blocks.assign(blocks)
	_locked_directions.assign(directions)
	if not locked_points.has(path[-1]):
		locked_points.append(path[-1])
	return true


func commit() -> bool:
	if not active or not error.is_empty() or path.is_empty():
		return false
	error = _validate_path()
	if not error.is_empty():
		return false
	# All checks finish before the first mutation; signals only update topology.
	for index: int in range(path.size()):
		var cell: Vector3i = path[index]
		if _world.get_block(cell) == VoxelWorldData.Block.AIR:
			_world.place_block(cell, blocks[index])
			_logistics.set_direction(cell, directions[index])
	if _start_block == VoxelWorldData.Block.BELT:
		_logistics.set_direction(path[0], directions[0])
	cancel()
	return true


func cancel() -> void:
	active = false
	path.clear()
	locked_path.clear()
	locked_points.clear()
	directions.clear()
	blocks.clear()
	_locked_blocks.clear()
	_locked_directions.clear()
	north_south_first = true
	error = ""


func _target_cell(hit: VoxelHit) -> Vector3i:
	return hit.cell if LogisticsData.is_machine(_world.get_block(hit.cell)) else hit.adjacent_cell()


func _empty_cell_error(cell: Vector3i, block: int = VoxelWorldData.Block.BELT) -> String:
	if not _world.is_in_bounds(cell):
		return "超出世界边界"
	if _world.get_block(cell) != VoxelWorldData.Block.AIR:
		return "与现有传送带交叉" if _world.get_block(cell) == VoxelWorldData.Block.BELT else "该位置已被占用"
	return _world.placement_error(cell, block)


func _validate_prefix() -> String:
	if _world.get_block(locked_path[0]) != _start_block:
		return "起点已改变"
	if _start_block in [VoxelWorldData.Block.MINER, VoxelWorldData.Block.CHEST]:
		if _logistics.direction_at(locked_path[0]) != _start_direction:
			return "起点出口已改变"
	for index: int in range(locked_path.size()):
		if index == 0 and _start_block != VoxelWorldData.Block.AIR:
			continue
		var reason: String = _empty_cell_error(locked_path[index], _locked_blocks[index])
		if not reason.is_empty():
			return reason
	return ""


func _validate_path() -> String:
	var reason: String = _validate_prefix()
	if not reason.is_empty():
		return reason
	reason = _port_error()
	if not reason.is_empty():
		return reason
	var planned: Dictionary[Vector3i, int] = {}
	for index: int in range(path.size()):
		var cell: Vector3i = path[index]
		if index > 0:
			var source_block: int = _start_block if index == 1 and _start_block != VoxelWorldData.Block.AIR else blocks[index - 1]
			var target_block: int = _end_block if index == path.size() - 1 and _end_block != VoxelWorldData.Block.AIR else blocks[index]
			var outlet: Vector3i = path[index - 1] + directions[index - 1] + (
				Vector3i.UP * VoxelWorldData.outlet_step(source_block)
			)
			var inlet: Vector3i = cell + Vector3i.UP * VoxelWorldData.inlet_step(target_block)
			if outlet != inlet:
				return "传送带端口无法连接"
			if VoxelWorldData.is_slope(target_block) and directions[index - 1] != directions[index]:
				return "斜坡只能直行接入"
			if target_block == VoxelWorldData.Block.BELT and directions[index - 1] == -directions[index]:
				return "不能从传送带出口接入"
		if planned.has(cell):
			return "路径不能与自身交叉"
		for neighbor: Vector3i in [cell + Vector3i.UP, cell + Vector3i.DOWN]:
			if planned.has(neighbor) and VoxelWorldData.blocks_intersect(cell, blocks[index], neighbor, planned[neighbor]):
				return "与斜坡实体相交"
		planned[cell] = blocks[index]
		if index == 0 and _start_block != VoxelWorldData.Block.AIR:
			continue
		if index == path.size() - 1 and _end_block != VoxelWorldData.Block.AIR:
			if _world.get_block(cell) != _end_block or _logistics.direction_at(cell) != _end_direction:
				return "终点入口已改变"
			continue
		reason = _empty_cell_error(cell, blocks[index])
		if not reason.is_empty():
			return reason
	return ""


func _route_directions(cells: Array[Vector3i]) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for index: int in range(cells.size()):
		if index + 1 < cells.size():
			var direction: Vector3i = cells[index + 1] - cells[index]
			direction.y = 0
			result.append(direction)
		elif _end_block == VoxelWorldData.Block.BELT:
			result.append(_end_direction)
		elif index > 0:
			result.append(result[-1])
		else:
			result.append(_preferred)
	return result


func _column_floor(cell: Vector3i, prefix_tops: Dictionary[Vector2i, int]) -> int:
	var floor_height: int = _world.minimum.y
	for y: int in range(_world.maximum.y - 1, _world.minimum.y - 1, -1):
		var block: int = _world.get_block(Vector3i(cell.x, y, cell.z))
		if block != VoxelWorldData.Block.AIR:
			floor_height = y + (2 if VoxelWorldData.is_slope(block) else 1)
			break
	var column: Vector2i = Vector2i(cell.x, cell.z)
	var prefix_top: int = prefix_tops[column] if prefix_tops.has(column) else _world.minimum.y
	return maxi(floor_height, prefix_top)


func _port_error() -> String:
	if path.size() < 2:
		return ""
	if _start_block in [VoxelWorldData.Block.MINER, VoxelWorldData.Block.CHEST] and directions[0] != _start_direction:
		return "起点出口与直角路线不符"
	if _end_block == VoxelWorldData.Block.CHEST and directions[-2] != _end_direction:
		return "终点入口与直角路线不符"
	if _end_block == VoxelWorldData.Block.BELT and directions[-2] == -_end_direction:
		return "不能从传送带出口接入"
	return ""
