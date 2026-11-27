extends "res://rust/tests/logistics_oracle.gd"
## Preparation for M04b: complete queues, not display prediction.


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 1 or FileAccess.file_exists(args[0]):
		quit(3)
		return
	for scenario: String in ["merge", "ring", "slope0", "slope1", "slope2", "slope3"]:
		var world: VoxelWorldData = VoxelWorldData.new()
		world.generate_flat()
		var data: LogisticsData = LogisticsData.new()
		data.bind_world(world, 0.17, 2)
		_build(scenario, world, data)
		_record(scenario, 0, data)
		for operation: int in range(1, 361):
			if scenario == "merge" and operation in [120, 125]:
				assert(data.set_direction(Vector3i.ZERO, Vector3i.FORWARD if operation == 120 else Vector3i.RIGHT))
			data.advance(LogisticsData.LOGIC_STEP)
			_record(scenario, operation, data)
	var output: FileAccess = FileAccess.open(args[0], FileAccess.WRITE)
	if output == null:
		quit(3)
		return
	output.store_string("\n".join(_lines) + "\n")
	output.close()
	print("LOGISTICS_COMPLEX_ORACLE_PASS")
	quit(0)


func _place(world: VoxelWorldData, data: LogisticsData, cell: Vector3i, block: int, direction: Vector3i) -> void:
	assert(world.place_block(cell, block))
	assert(data.set_direction(cell, direction))


func _build(scenario: String, world: VoxelWorldData, data: LogisticsData) -> void:
	if scenario == "merge":
		_place(world, data, Vector3i.ZERO, VoxelWorldData.Block.BELT, Vector3i.RIGHT)
		_place(world, data, Vector3i.RIGHT, VoxelWorldData.Block.CHEST, Vector3i.RIGHT)
		for direction: Vector3i in [Vector3i.RIGHT, Vector3i.BACK, Vector3i.FORWARD]:
			_place(world, data, -direction, VoxelWorldData.Block.MINER, direction)
	elif scenario == "ring":
		var cells: Array[Vector3i] = [Vector3i.ZERO, Vector3i.RIGHT, Vector3i(1, 0, 1), Vector3i.BACK]
		for index: int in range(cells.size()):
			_place(world, data, cells[index], VoxelWorldData.Block.BELT, cells[(index + 1) % cells.size()] - cells[index])
		_place(world, data, Vector3i.LEFT, VoxelWorldData.Block.MINER, Vector3i.RIGHT)
		assert(data.prefill_belts())
	else:
		var rotation: int = int(scenario.trim_prefix("slope"))
		var directions: Array[Vector3i] = [Vector3i.BACK, Vector3i.LEFT, Vector3i.FORWARD, Vector3i.RIGHT]
		var facing: Vector3i = directions[rotation]
		var side: Vector3i = Vector3i(-facing.z, 0, facing.x)
		var cells: Array[Vector3i] = [
			-facing, Vector3i.ZERO, facing, facing * 2 + Vector3i.UP,
			facing * 3 + Vector3i.UP, facing * 4, facing * 5, facing * 5 + side,
		]
		var blocks: Array[int] = [5, 6, 9 + rotation, 9 + rotation, 13 + rotation, 13 + rotation, 6, 7]
		for index: int in range(cells.size()):
			_place(world, data, cells[index], blocks[index], facing if index < 6 else side)
		_place(world, data, facing * 5 - side, VoxelWorldData.Block.MINER, side)
		_place(world, data, facing - side, VoxelWorldData.Block.MINER, side)
		assert(data.prefill_belts())
