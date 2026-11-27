extends SceneTree
## M02 oracle: only the current Godot rules produce expected values.

var _lines: PackedStringArray = []


func _initialize() -> void:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	if arguments.size() != 1 or FileAccess.file_exists(arguments[0]):
		quit(3)
		return
	var world: VoxelWorldData = VoxelWorldData.new()
	var low: Vector3i = Vector3i(-4, -4, -4)
	var high: Vector3i = Vector3i(4, 8, 4)
	assert(world.generate_flat(low, high, 4))
	_record_world("flat", world)
	assert(world.break_block(Vector3i(-3, -1, -3)))
	assert(world.place_block(Vector3i(-3, 0, -3), VoxelWorldData.Block.MINER))
	assert(world.place_block(Vector3i(3, 0, 3), VoxelWorldData.Block.BELT_UP_EAST))
	assert(world.place_structure(Vector3i.ZERO, 3))
	_record_world("edited", world)
	var restored: VoxelWorldData = VoxelWorldData.new()
	assert(restored.restore_chunks(true, world.chunk_deltas(), world.structure_rows(), low, high, 4))
	_record_world("restored", restored)
	assert(restored.break_block(Vector3i(1, 2, 1)))
	_record_world("removed", restored)
	for block: int in range(9, 17):
		for sample: Vector2i in [Vector2i(1, 3), Vector2i(7, 1), Vector2i(2, 6)]:
			var cell: Vector3i = Vector3i(-2, -3, 2)
			var point: Vector3 = Vector3(cell) * 0.5 + Vector3(sample.x, 0, sample.y) * 0.0625
			var height: float = VoxelWorldData.slope_elevation(cell, block, point) / 0.5
			_lines.append("elevation %d %d %d %.9f" % [block, sample.x, sample.y, height])
	for height: int in [-3, 3]:
		var cell: Vector3i = Vector3i(-2, height, 2)
		for block: int in range(VoxelWorldData.Block.BELT_UP, VoxelWorldData.Block.BELT_DOWN_EAST + 1):
			for other: int in range(VoxelWorldData.Block.GRASS, VoxelWorldData.Block.BELT_DOWN_EAST + 1):
				for step: int in range(-2, 3):
					for horizontal: int in range(-1, 2):
						var neighbor: Vector3i = cell + Vector3i(horizontal, step, 0)
						var intersects: bool = VoxelWorldData.blocks_intersect(cell, block, neighbor, other)
						_lines.append("geometry %d %d %d %d %d %d" % [
							height, block, other, step, horizontal, int(intersects)])
	for x: int in range(-4, 5):
		for y: int in range(-4, 5):
			for z: int in range(-4, 5):
				var anchor: Vector3i = VoxelWorldData.structure_anchor(Vector3(x, y, z) * 0.125)
				_lines.append("anchor %d %d %d %d %d %d" % [x, y, z, anchor.x, anchor.y, anchor.z])
	var output: FileAccess = FileAccess.open(arguments[0], FileAccess.WRITE)
	if output == null:
		quit(3)
		return
	output.store_string("\n".join(_lines) + "\n")
	output.close()
	print("WORLD_ORACLE_PASS")
	quit(0)


func _record_world(label: String, world: VoxelWorldData) -> void:
	var blocks: PackedByteArray = []
	var owners: PackedByteArray = []
	for x: int in range(world.minimum.x, world.maximum.x):
		for y: int in range(world.minimum.y, world.maximum.y):
			for z: int in range(world.minimum.z, world.maximum.z):
				var cell: Vector3i = Vector3i(x, y, z)
				blocks.append(world.get_block(cell))
				var owner: Dictionary = world.structure_at(cell)
				owners.append(int(not owner.is_empty()))
				if not owner.is_empty():
					_lines.append("owner %s %d %d %d %d %d" % [
						label, x, y, z, owner["id"], owner["rotation"]])
	_lines.append("world %s %d %s %s" % [label, world.block_count(), blocks.hex_encode(), owners.hex_encode()])
