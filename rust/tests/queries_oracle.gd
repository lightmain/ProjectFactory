extends SceneTree
## M03 ray observations come only from the existing Godot implementation.

var _lines: PackedStringArray = []
const RAYS: Array[Vector3] = [
	Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD,
	Vector3(1, 1, 0), Vector3(-1, -1, 0), Vector3(1.13, -2.17, 3.31), Vector3(-2.23, 3.37, -0.97),
]


func _initialize() -> void:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	if arguments.size() != 1 or FileAccess.file_exists(arguments[0]):
		quit(3)
		return
	var cell: Vector3i = Vector3i(-2, 1, 2)
	for block: int in range(1, 17):
		if block == VoxelWorldData.Block.BEDROCK:
			continue
		var world: VoxelWorldData = VoxelWorldData.new()
		if not world.place_block(cell, block):
			push_error("Oracle setup rejected block %d" % block)
			quit(3)
			return
		var index: int = 0
		for x: float in [-0.25, 0.125, 0.75]:
			for y: float in [-0.25, 0.125, 0.75]:
				for z: float in [-0.25, 0.125, 0.75]:
					for ray: Vector3 in RAYS:
						var origin: Vector3 = Vector3(cell) * 0.5 + Vector3(x, y, z)
						_record("%d:%d" % [block, index], world, origin, ray, 5.0)
						index += 1
	var flat: VoxelWorldData = VoxelWorldData.new()
	flat.generate_flat()
	_record("ground", flat, Vector3(0.25, 2, 0.25), Vector3.DOWN, 2.0)
	_record("short", flat, Vector3(0.25, 2, 0.25), Vector3.DOWN, 1.9)
	_record("zero", flat, Vector3.ZERO, Vector3.ZERO, 5.0)
	_record("tiny", flat, Vector3.ZERO, Vector3.ONE * 0.00000001, 5.0)
	_record("negative", flat, Vector3.ZERO, Vector3.DOWN, -1.0)
	flat.break_block(Vector3i(0, -1, 0))
	_record("edit", flat, Vector3(0.25, 1, 0.25), Vector3.DOWN, 5.0)
	var slope: VoxelWorldData = VoxelWorldData.new()
	slope.place_block(Vector3i.ZERO, VoxelWorldData.Block.BELT_UP_EAST)
	_record("air", slope, Vector3(0.4, 0.1, -0.2), Vector3.BACK, 1.0)
	_record("lip", slope, Vector3(0.48, 0.55, -0.2), Vector3.BACK, 1.0)
	slope.place_block(Vector3i(0, 0, 2), VoxelWorldData.Block.STONE)
	_record("next", slope, Vector3(0.4, 0.1, -0.2), Vector3.BACK, 2.0)
	var stone: VoxelWorldData = VoxelWorldData.new()
	stone.place_block(Vector3i(-2, 0, 0), VoxelWorldData.Block.STONE)
	_record("nonunit", stone, Vector3(0, 0.25, 0.25), Vector3(-4, 0, 0), 5.0)
	stone.place_block(Vector3i.ZERO, VoxelWorldData.Block.STONE)
	_record("corner", stone, Vector3(-0.5, -0.5, 0.25), Vector3(1, 1, 0), 3.0)
	var output: FileAccess = FileAccess.open(arguments[0], FileAccess.WRITE)
	if output == null:
		quit(3)
		return
	output.store_string("\n".join(_lines) + "\n")
	output.close()
	print("QUERIES_ORACLE_PASS")
	quit(0)


func _record(label: String, world: VoxelWorldData, origin: Vector3, ray: Vector3, limit: float) -> void:
	var hit: VoxelHit = VoxelRaycast.cast(world, origin, ray, limit)
	var row: String = "%s %.9f %.9f %.9f %.9f %.9f %.9f %.9f" % [
		label, origin.x, origin.y, origin.z, ray.x, ray.y, ray.z, limit]
	if hit == null:
		_lines.append(row + " none")
	else:
		_lines.append(row + " %d %d %d %d %d %d %.9f %.9f %.9f %.9f" % [
			hit.cell.x, hit.cell.y, hit.cell.z, hit.normal.x, hit.normal.y, hit.normal.z,
			hit.distance, hit.position.x, hit.position.y, hit.position.z])
