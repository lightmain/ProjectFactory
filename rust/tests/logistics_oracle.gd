extends SceneTree
## M04a observations are committed Godot state, including the settled graph.

const Replay = preload("res://tests/support/logistics_replay.gd")
var _lines: PackedStringArray = []


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 1 or FileAccess.file_exists(args[0]):
		quit(3)
		return
	for scenario: String in ["chain", "blocked", "partial", "flush", "output", "arrival"]:
		var world: VoxelWorldData = VoxelWorldData.new()
		world.generate_flat()
		var data: LogisticsData = LogisticsData.new()
		data.bind_world(world, 0.1, 3 if scenario == "output" else 1)
		_apply(scenario, 0, world, data)
		for operation: int in range(1, 301):
			_apply(scenario, operation, world, data)
		assert(data.set_direction(Vector3i(2 if scenario == "arrival" else 1, 0, 0), Vector3i.FORWARD))
		var saved: Dictionary = data.save_state()
		assert(data.restore_state(saved))
		_record(scenario, 301, data)
		for operation: int in range(302, 362):
			data.advance(LogisticsData.LOGIC_STEP)
			_record(scenario, operation, data)
	var output: FileAccess = FileAccess.open(args[0], FileAccess.WRITE)
	if output == null:
		quit(3)
		return
	output.store_string("\n".join(_lines) + "\n")
	output.close()
	print("LOGISTICS_ORACLE_PASS")
	quit(0)


func _apply(scenario: String, operation: int, world: VoxelWorldData, data: LogisticsData) -> void:
	if operation == 0:
		for x: int in range(3):
			if scenario == "partial" and x == 0:
				continue
			if scenario in ["output", "arrival"] and x == 2:
				continue
			var block: int = VoxelWorldData.Block.CHEST if scenario == "arrival" and x == 1 else [5, 6, 7][x]
			assert(world.place_block(Vector3i(x, 0, 0), block))
			assert(data.set_direction(Vector3i(x, 0, 0), Vector3i.RIGHT))
	elif scenario == "partial" and operation == 1:
		data.advance(0.003)
		assert(world.place_block(Vector3i.ZERO, VoxelWorldData.Block.MINER))
		assert(data.set_direction(Vector3i.ZERO, Vector3i.RIGHT))
	elif scenario == "blocked" and operation == 40:
		assert(world.break_block(Vector3i(2, 0, 0)))
		data.advance(LogisticsData.LOGIC_STEP)
	elif scenario == "blocked" and operation == 160:
		assert(world.place_block(Vector3i(2, 0, 0), VoxelWorldData.Block.CHEST))
		assert(data.set_direction(Vector3i(2, 0, 0), Vector3i.RIGHT))
		data.advance(LogisticsData.LOGIC_STEP)
	elif scenario == "flush" and operation in [60, 61, 62]:
		assert(data.set_direction(Vector3i.RIGHT, Vector3i.FORWARD if operation == 60 else Vector3i.RIGHT))
		data.advance(1e-10)
	elif scenario == "output" and operation == 7:
		assert(world.break_block(Vector3i.RIGHT))
		assert(world.place_block(Vector3i.RIGHT, VoxelWorldData.Block.BELT))
		assert(data.set_direction(Vector3i.RIGHT, Vector3i.RIGHT))
		data.advance(1e-10)
	elif scenario == "arrival" and operation == 7:
		assert(world.place_block(Vector3i(2, 0, 0), VoxelWorldData.Block.BELT))
		assert(data.set_direction(Vector3i(2, 0, 0), Vector3i.RIGHT))
		data.advance(1e-10)
	elif scenario in ["output", "arrival"] and operation == 8:
		data.advance(0.0)
	else:
		data.advance(LogisticsData.LOGIC_STEP)
	_record(scenario, operation, data)


func _record(scenario: String, operation: int, data: LogisticsData) -> void:
	var state: Dictionary = Replay.canonical_state(data.save_state())
	_lines.append("S %s %d %s %s %d %d %d %d %s %d %d" % [
		scenario, operation, _float(state["time"]), _float(state["compensation"]), state["tick"],
		state["flushed"], state["next_id"], int(state["dirty"]), _float(state["interval"]),
		state["amount"], state["machines"].size(),
	])
	var rows: Array = state["machines"]
	for row: Dictionary in rows:
		var ores: Array = row["ores"]
		_lines.append("M %s %d %d %d %d %d %d %s %d %s %d %s %d %s %s %s %s %d" % [
			_cell(row["cell"]), row["block"], _direction(row["direction"]),
			_direction(row["settled"]), row["quantity"], row["eligible"], row["last_output"],
			_float(row["interval"]), row["amount"], _float(row["next"]), row["cursor"], _float(row["placed"]),
			row["cycles"], _cell(row["outgoing"]), _cell(row["inputs"][0]),
			_cell(row["inputs"][1]), _cell(row["inputs"][2]), ores.size(),
		])
		for ore: Dictionary in ores:
			_lines.append("O %d %d %s" % [ore["id"], _direction(ore["incoming"]), _float(ore["progress"])])


func _float(value: float) -> String:
	return PackedFloat64Array([value]).to_byte_array().hex_encode()


func _cell(value: Variant) -> String:
	if value == null:
		return "-"
	var cell: Vector3i = value
	return "%d,%d,%d" % [cell.x, cell.y, cell.z]


func _direction(value: Vector3i) -> int:
	return [Vector3i.BACK, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.RIGHT].find(value)
