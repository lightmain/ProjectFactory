extends SceneTree
## Actual legacy SurfaceTool output, independently generated for M07a.

var _lines: PackedStringArray = []


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 1 or FileAccess.file_exists(args[0]):
		quit(3)
		return
	var normals: Array[Vector3i] = [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.BACK, Vector3i.FORWARD]
	for block: int in [1, 2, 3, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 16]:
		for direction: int in range(4):
			for location: int in range(2):
				var cell: Vector3i = Vector3i(-1, 2, -1) if location == 0 else Vector3i(2, 2, 2)
				var world: VoxelWorldData = VoxelWorldData.new()
				assert(world.place_block(cell, block))
				_record("block_%d_%d_%d" % [block, direction, location], world,
					VoxelWorldView._chunk_for(cell), normals[direction])
	for block: int in [3, 6, 12]:
		var world: VoxelWorldData = VoxelWorldData.new()
		assert(world.place_block(Vector3i(7, 2, 2), 3))
		assert(world.place_block(Vector3i(8, 2, 2), block))
		_record("neighbor_%d" % block, world, Vector3i.ZERO, Vector3i.RIGHT)
		_record("neighbor_%d" % block, world, Vector3i.RIGHT, Vector3i.RIGHT)
	for anchor: int in [1, 7]:
		var world: VoxelWorldData = VoxelWorldData.new()
		assert(world.place_structure(Vector3i(anchor, 2, 2), 3))
		_record("structure_%d" % anchor, world, Vector3i.ZERO, Vector3i.ZERO)
		if anchor == 7:
			_record("structure_%d" % anchor, world, Vector3i.RIGHT, Vector3i.ZERO)
	var flat: VoxelWorldData = VoxelWorldData.new()
	assert(flat.generate_flat())
	_record("flat", flat, Vector3i(-1, -1, -1), Vector3i.ZERO)
	_record("flat", flat, Vector3i(-4, -1, -4), Vector3i.ZERO)
	var output: FileAccess = FileAccess.open(args[0], FileAccess.WRITE)
	if output == null:
		quit(3)
		return
	output.store_string("\n".join(_lines) + "\n")
	output.close()
	print("MESHING_ORACLE_PASS")
	quit(0)


func _record(label: String, world: VoxelWorldData, key: Vector3i, direction: Vector3i) -> void:
	var view: VoxelWorldView = VoxelWorldView.new()
	view.set("_world", world)
	var surface: SurfaceTool = SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
	var start: Vector3i = key * VoxelWorldView.CHUNK_SIZE
	for x: int in range(start.x, start.x + VoxelWorldView.CHUNK_SIZE):
		for y: int in range(start.y, start.y + VoxelWorldView.CHUNK_SIZE):
			for z: int in range(start.z, start.z + VoxelWorldView.CHUNK_SIZE):
				var cell: Vector3i = Vector3i(x, y, z)
				var block: int = world.get_block(cell)
				if block == VoxelWorldData.Block.AIR:
					continue
				var bounds: AABB = VoxelWorldData.block_bounds(cell, block)
				for normal: Vector3i in VoxelWorldView.FACE_NORMALS:
					if not view._face_covered(cell, normal, bounds):
						VoxelWorldView._add_face(surface, cell, normal, block, bounds,
							direction if LogisticsData.is_machine(block) else Vector3i.ZERO)
	view.free()
	var arrays: Array = surface.commit_to_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var custom: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	_lines.append("mesh %s %d %d %d %d" % [label, key.x, key.y, key.z, vertices.size()])
	assert(vertices.size() == normals.size() and vertices.size() == colors.size())
	assert(vertices.size() == uv.size() and custom.size() == vertices.size() * 4)
	for i: int in range(vertices.size()):
		var p: Vector3 = vertices[i]
		var n: Vector3 = normals[i]
		var c: Color = colors[i]
		var t: Vector2 = uv[i]
		_lines.append("vertex %s %d %d %d %d %.9f %.9f %.9f %.9f %.9f %.9f %.9f %.9f %.9f %.9f %.9f %.9f %.9f %.9f %.9f %.9f" % [
			label, key.x, key.y, key.z, i, p.x, p.y, p.z, n.x, n.y, n.z,
			c.r, c.g, c.b, c.a, t.x, t.y,
			custom[i * 4], custom[i * 4 + 1], custom[i * 4 + 2], custom[i * 4 + 3]])
