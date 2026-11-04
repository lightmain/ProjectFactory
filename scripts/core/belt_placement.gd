class_name BeltPlacement
extends RefCounted
## A reversible belt build session. Nothing reaches the world until commit.

var active: bool = false
var path: Array[Vector3i] = []
var locked_path: Array[Vector3i] = []
var locked_points: Array[Vector3i] = []
var directions: Array[Vector3i] = []
var error: String = ""
var _world: VoxelWorldData
var _logistics: LogisticsData
var _start_block: int
var _start_direction: Vector3i
var _end_block: int
var _end_direction: Vector3i
var _preferred: Vector3i


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
	elif not LogisticsData.is_machine(block):
		error = "该位置已被占用"
	if not error.is_empty():
		return false
	_start_block = block
	_start_direction = _logistics.direction_at(cell)
	_preferred = preferred
	locked_path.assign([cell])
	path.assign(locked_path)
	directions.assign([preferred])
	active = true
	if block in [VoxelWorldData.Block.MINER, VoxelWorldData.Block.CHEST]:
		error = _empty_cell_error(cell + _start_direction)
		if not error.is_empty():
			cancel()
			return false
	return true


func preview(hit: VoxelHit, preferred: Vector3i) -> void:
	if not active:
		return
	_preferred = preferred
	path.assign(locked_path)
	error = _validate_prefix()
	if not error.is_empty():
		_update_directions()
		return
	if hit == null:
		error = "请瞄准有效位置"
		_update_directions()
		return
	var end: Vector3i = _target_cell(hit)
	if locked_path.size() == 1 and end == locked_path[0] and _start_block in [
		VoxelWorldData.Block.MINER, VoxelWorldData.Block.CHEST,
	]:
		end += _start_direction
	_end_block = _world.get_block(end)
	_end_direction = _logistics.direction_at(end)
	if end.y != locked_path[0].y:
		error = "暂不支持高低差传送带"
	elif _end_block == VoxelWorldData.Block.MINER:
		error = "矿机没有输入口"
	elif _end_block == VoxelWorldData.Block.AIR:
		error = _empty_cell_error(end)
	elif _end_block not in [VoxelWorldData.Block.BELT, VoxelWorldData.Block.CHEST]:
		error = "该位置已被占用"
	if not error.is_empty():
		# Keep the prefix flat, and show the invalid target at its actual height.
		path.append(end)
		_update_directions()
		return
	var blocked: Dictionary[Vector3i, bool] = {}
	for index: int in range(locked_path.size() - 1):
		blocked[locked_path[index]] = true
	if blocked.has(end) or (end == locked_path[0] and _end_block != VoxelWorldData.Block.AIR):
		error = "路径不能与自身交叉"
		_update_directions()
		return
	var start_exit: Vector3i = Vector3i.ZERO
	if locked_path.size() == 1 and _start_block in [
		VoxelWorldData.Block.MINER, VoxelWorldData.Block.CHEST,
	]:
		start_exit = _start_direction
	var incoming: Vector3i = Vector3i.ZERO
	if locked_path.size() > 1:
		incoming = locked_path[-1] - locked_path[-2]
	var suffix: Array[Vector3i] = BeltPathfinder.find(
		_world, locked_path[-1], end, preferred, start_exit, _end_direction,
		_end_block == VoxelWorldData.Block.CHEST, blocked, false, incoming
	)
	if suffix.is_empty():
		suffix = BeltPathfinder.find(
			_world, locked_path[-1], end, preferred, start_exit, _end_direction,
			_end_block == VoxelWorldData.Block.CHEST, blocked, true, incoming
		)
		error = "与现有传送带交叉" if not suffix.is_empty() else "没有可用的传送带路径"
	if suffix.is_empty():
		path.append(end)
	else:
		path.append_array(suffix.slice(1))
	_update_directions()


func lock_preview() -> bool:
	if not active or not error.is_empty() or path.is_empty():
		return false
	if _world.get_block(path[-1]) != VoxelWorldData.Block.AIR:
		return false
	locked_path.assign(path)
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
			_world.place_block(cell, VoxelWorldData.Block.BELT)
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


func _target_cell(hit: VoxelHit) -> Vector3i:
	return hit.cell if LogisticsData.is_machine(_world.get_block(hit.cell)) else hit.adjacent_cell()


func _empty_cell_error(cell: Vector3i) -> String:
	if not _world.is_in_bounds(cell):
		return "超出世界边界"
	if _world.get_block(cell) != VoxelWorldData.Block.AIR:
		return "与现有传送带交叉" if _world.get_block(cell) == VoxelWorldData.Block.BELT else "该位置已被占用"
	return ""


func _validate_prefix() -> String:
	if _world.get_block(locked_path[0]) != _start_block:
		return "起点已改变"
	if _start_block in [VoxelWorldData.Block.MINER, VoxelWorldData.Block.CHEST]:
		if _logistics.direction_at(locked_path[0]) != _start_direction:
			return "起点出口已改变"
	for index: int in range(locked_path.size()):
		if index == 0 and _start_block != VoxelWorldData.Block.AIR:
			continue
		var reason: String = _empty_cell_error(locked_path[index])
		if not reason.is_empty():
			return reason
	return ""


func _validate_path() -> String:
	var reason: String = _validate_prefix()
	if not reason.is_empty():
		return reason
	for index: int in range(path.size()):
		var cell: Vector3i = path[index]
		if index == 0 and _start_block != VoxelWorldData.Block.AIR:
			continue
		if index == path.size() - 1 and _end_block != VoxelWorldData.Block.AIR:
			if _world.get_block(cell) != _end_block or _logistics.direction_at(cell) != _end_direction:
				return "终点入口已改变"
			continue
		reason = _empty_cell_error(cell)
		if not reason.is_empty():
			return reason
	return ""


func _update_directions() -> void:
	directions.clear()
	for index: int in range(path.size()):
		if index + 1 < path.size():
			var direction: Vector3i = path[index + 1] - path[index]
			directions.append(direction if direction.y == 0 else _preferred)
		elif _end_block == VoxelWorldData.Block.BELT:
			directions.append(_end_direction)
		elif index > 0:
			directions.append(directions[-1])
		else:
			directions.append(_preferred)
