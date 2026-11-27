extends SceneTree
## Independent current-Godot geometry, including infeasible height profiles.

var _lines: PackedStringArray = []


func _initialize() -> void:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	if arguments.size() != 1 or FileAccess.file_exists(arguments[0]):
		quit(3)
		return
	for x: int in range(-3, 4):
		for z: int in range(-3, 4):
			for north: bool in [false, true]:
				_record_footprint(x, z, north)
	_record_footprint(1000, 0, true)
	var invalid_floors: Array[Array] = [[], [0, 0], [0, 0], [0, 0]]
	var invalid_capacities: Array[Array] = [[], [], [-1], [2]]
	for index: int in range(invalid_floors.size()):
		var floors: Array[int] = []
		var capacities: Array[int] = []
		floors.assign(invalid_floors[index])
		capacities.assign(invalid_capacities[index])
		var heights: Array[int] = OrthogonalRoute.fit_heights(floors, capacities, 0, 0)
		_lines.append("invalid %d %s" % [index, "none" if heights.is_empty() else "unexpected"])
	for length: int in range(1, 6):
		for code: int in range(int(pow(3, length))):
			var floors: Array[int] = []
			var digits: int = code
			for index: int in range(length):
				floors.append(digits % 3 - 1)
				digits = int(digits / 3)
			for mask: int in range(1 << (length - 1)):
				var capacities: Array[int] = []
				for index: int in range(length - 1):
					capacities.append((mask >> index) & 1)
				for start: int in range(-1, 2):
					for end: int in range(-1, 2):
						var heights: Array[int] = OrthogonalRoute.fit_heights(floors, capacities, start, end)
						var values: PackedStringArray = []
						for height: int in heights:
							values.append(str(height))
						_lines.append("fit %d %d %d %d %d %s" % [
							length, code, mask, start, end, "none" if values.is_empty() else ",".join(values)])
	var output: FileAccess = FileAccess.open(arguments[0], FileAccess.WRITE)
	if output == null:
		quit(3)
		return
	output.store_string("\n".join(_lines) + "\n")
	output.close()
	print("ROUTE_ORACLE_PASS")
	quit(0)


func _record_footprint(x: int, z: int, north: bool) -> void:
	var cells: Array[Vector3i] = OrthogonalRoute.footprint(Vector3i(-5, 7, -6), Vector3i(-5 + x, 17, -6 + z), north)
	var values: PackedStringArray = []
	for cell: Vector3i in cells:
		values.append("%d,%d,%d" % [cell.x, cell.y, cell.z])
	_lines.append("footprint %d %d %d %s" % [x, z, int(north), ";".join(values)])
