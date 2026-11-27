extends SceneTree
## Current gameplay planner only; no Rust output is consumed here.

var _lines: PackedStringArray = []
var _world: VoxelWorldData
var _logistics: LogisticsData
var _build: BeltPlacement


func _initialize() -> void:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	if arguments.size() != 1 or FileAccess.file_exists(arguments[0]):
		quit(3)
		return
	for layout: int in range(4):
		_reset(layout)
		for start_y: int in range(4):
			for x: int in range(-3, 4):
				for end_y: int in range(4):
					for z: int in range(-3, 4):
						for north: bool in [false, true]:
							_new_build()
							if _build.begin(_hit(Vector3i(0, start_y, 0)), Vector3i.RIGHT):
								if not north:
									_build.toggle_route_order()
								_build.preview(_hit(Vector3i(x, end_y, z)), Vector3i.RIGHT)
							_record("basic:%d:%d:%d:%d:%d:%d" % [layout, start_y, x, end_y, z, int(north)])
	for direction: int in range(4):
		var facing: Vector3i = VoxelWorldData.SLOPE_DIRECTIONS[direction]
		var cross: Vector3i = VoxelWorldData.SLOPE_DIRECTIONS[(direction + 1) % 4]
		_reset(0)
		_build.begin(_hit(Vector3i(0, 4, 0)), facing)
		_build.preview(_hit(facing * 3), facing)
		_record("locked:%d:0" % direction)
		_build.lock_preview()
		_record("locked:%d:1" % direction)
		_build.preview(_hit(facing * 3), -facing)
		_record("locked:%d:2" % direction)
		for stage: int in [3, 4]:
			if stage == 4:
				_build.toggle_route_order()
			_build.preview(_hit(facing * 6 + cross * 2), -facing)
			_record("locked:%d:%d" % [direction, stage])
		_reset(0)
		_build.begin(_hit(Vector3i(0, 5, 0)), facing)
		var terminals: Array[Vector3i] = [facing + Vector3i(0, 3, 0), facing * 3 + Vector3i.UP, facing * 4]
		for stage: int in range(terminals.size()):
			_build.preview(_hit(terminals[stage]), facing)
			_build.lock_preview()
			_record("repeat:%d:%d" % [direction, stage])
	for start_kind: int in [5, 6, 7]:
		for end_kind: int in [5, 6, 7]:
			for start_dir: int in range(4):
				for end_dir: int in range(4):
					for north: bool in [false, true]:
						_reset(0)
						_world.place_block(Vector3i.ZERO, start_kind)
						_world.place_block(Vector3i(3, 0, 2), end_kind)
						_logistics.set_direction(Vector3i.ZERO, VoxelWorldData.SLOPE_DIRECTIONS[start_dir])
						_logistics.set_direction(Vector3i(3, 0, 2), VoxelWorldData.SLOPE_DIRECTIONS[end_dir])
						if _build.begin(_hit(Vector3i.ZERO), Vector3i.RIGHT):
							if not north:
								_build.toggle_route_order()
							_build.preview(_hit(Vector3i(3, 0, 2)), Vector3i.RIGHT)
						_record("ports:%d:%d:%d:%d:%d" % [start_kind, end_kind, start_dir, end_dir, int(north)])
	var output: FileAccess = FileAccess.open(arguments[0], FileAccess.WRITE)
	if output == null:
		quit(3)
		return
	output.store_string("\n".join(_lines) + "\n")
	output.close()
	print("BELT_PLACEMENT_ORACLE_PASS")
	quit(0)


func _reset(layout: int) -> void:
	_world = VoxelWorldData.new()
	_world.generate_flat()
	_logistics = LogisticsData.new()
	_logistics.bind_world(_world)
	_new_build()
	if layout == 1:
		_world.place_block(Vector3i.RIGHT, VoxelWorldData.Block.STONE)
	elif layout == 2:
		_world.place_block(Vector3i.RIGHT, VoxelWorldData.Block.BELT_UP + 3)
	elif layout == 3:
		_world.place_structure(Vector3i(3, 0, 0))


func _new_build() -> void:
	_build = BeltPlacement.new()
	_build.bind_world(_world, _logistics)


func _hit(cell: Vector3i) -> VoxelHit:
	return VoxelHit.new(cell if LogisticsData.is_machine(_world.get_block(cell)) else cell + Vector3i.DOWN, Vector3i.UP, 1.0)


func _record(label: String) -> void:
	_lines.append("%s %s %s %s %d" % [
		label, _code(_build.error), _rows(_build.path, _build.blocks, _build.directions),
		_rows(_build.locked_path, _build._locked_blocks, _build._locked_directions), int(_build.active)])


func _rows(cells: Array[Vector3i], blocks: Array[int], directions: Array[Vector3i]) -> String:
	var values: PackedStringArray = []
	for index: int in range(cells.size()):
		var cell: Vector3i = cells[index]
		values.append("%d,%d,%d,%d,%d" % [
			cell.x, cell.y, cell.z, blocks[index], VoxelWorldData.SLOPE_DIRECTIONS.find(directions[index])])
	return "_" if values.is_empty() else ";".join(values)


func _code(error: String) -> String:
	match error:
		"": return "ok"
		"请瞄准有效位置": return "NoTarget"
		"超出世界边界": return "OutOfBounds"
		"该位置已被占用": return "Occupied"
		"与现有传送带交叉": return "BeltCrossing"
		"与斜坡实体相交", "斜坡超出世界边界": return "GeometryConflict"
		"起点已改变": return "StartChanged"
		"起点出口已改变": return "StartDirectionChanged"
		"终点入口已改变": return "EndChanged"
		"矿机没有输入口": return "MinerHasNoInput"
		"起点出口与直角路线不符": return "StartPort"
		"终点入口与直角路线不符": return "EndPort"
		"不能从传送带出口接入": return "BeltOutput"
		"直线坡道不足，无法连接高度": return "InsufficientRamps"
		"传送带端口无法连接": return "Disconnected"
		"斜坡只能直行接入": return "SlopeTurn"
		"路径不能与自身交叉": return "SelfCrossing"
	return "unknown:" + error
