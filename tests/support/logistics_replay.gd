extends RefCounted
## Replay diagnostics are pure data, suitable for a failing assertion or an artifact.

const Reference = preload("res://tests/support/logistics_t03_reference.gd")
const STEP: float = 1.0 / 60.0


static func production_between(state: Dictionary, end_tick: int) -> int:
	var produced: int = 0
	var rows: Array = state["machines"]
	var boundary: float = float(end_tick) * STEP
	for row: Dictionary in rows:
		var interval: float = row["interval"]
		var amount: int = row["amount"]
		if row["block"] != VoxelWorldData.Block.MINER or not is_finite(interval) or interval < 0.001 or amount <= 0:
			continue
		var placed: float = row["placed"]
		var previous: int = row["cycles"]
		var cycles: int = maxi(0, int(floorf((boundary - placed + 1e-9) / interval)))
		produced += maxi(0, cycles - previous) * amount
	return produced


static func run_seed(seed_value: int, ticks: int = 240) -> Dictionary:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value
	var initial: Dictionary = _initial_factory(rng, seed_value)
	var operations: Array[Dictionary] = []
	var edit_cell: Vector3i = Vector3i(-9, 0, 7)
	var stock: Vector3i = Vector3i(10, 0, -8)
	var initial_rows: Array = initial["logistics"]["machines"]
	var line_end: Vector3i = Vector3i.ZERO
	for row: Dictionary in initial_rows:
		var cell: Vector3i = row["cell"]
		if row["block"] == VoxelWorldData.Block.CHEST and cell.x < 0:
			line_end = cell
	var line_belt: Vector3i = Vector3i(-9, 0, line_end.z)
	for index: int in range(ticks):
		match index % 30:
			0:
				operations.append({"kind": "inventory", "cell": stock, "amount": rng.randi_range(5, 15)})
			1:
				operations.append({"kind": "inventory", "cell": stock, "amount": -rng.randi_range(1, 4)})
			2:
				edit_cell = Vector3i(rng.randi_range(-10, -8), 0, rng.randi_range(6, 9))
				operations.append({"kind": "place", "cell": edit_cell, "block": VoxelWorldData.Block.MINER, "direction": _random_direction(rng)})
				# Also exercise an edit flush exactly at a settled boundary.
				operations.append({"kind": "advance", "delta": 1e-10})
			3:
				operations.append({"kind": "rotate", "cell": Vector3i.ZERO, "direction": _random_direction(rng)})
			4:
				operations.append({"kind": "delete", "cell": edit_cell})
			5:
				operations.append({"kind": "restore"})
			6:
				operations.append({"kind": "configure", "interval": float(rng.randi_range(1, 12)) / 100.0, "amount": rng.randi_range(1, 4)})
			7:
				operations.append({"kind": "advance", "delta": 0.003})
				operations.append({"kind": "place", "cell": edit_cell, "block": VoxelWorldData.Block.MINER, "direction": _random_direction(rng)})
			8:
				operations.append({"kind": "restore"})
			9:
				operations.append({"kind": "delete", "cell": edit_cell})
				operations.append({"kind": "rotate", "cell": Vector3i.ZERO, "direction": Vector3i.RIGHT})
			10:
				operations.append({"kind": "delete", "cell": Vector3i.RIGHT})
			11:
				operations.append({"kind": "place", "cell": Vector3i.RIGHT, "block": VoxelWorldData.Block.BELT, "direction": Vector3i.BACK})
			12:
				operations.append({"kind": "inventory", "cell": line_end, "amount": rng.randi_range(5, 15)})
			13:
				operations.append({"kind": "inventory", "cell": line_end, "amount": -rng.randi_range(1, 4)})
			14:
				operations.append({"kind": "delete", "cell": line_belt})
			15:
				operations.append({"kind": "place", "cell": line_belt, "block": VoxelWorldData.Block.BELT, "direction": Vector3i.RIGHT})
			16:
				operations.append({"kind": "restore"})
		operations.append({"kind": "advance", "delta": STEP})
	return run_operations(seed_value, initial, operations)


static func _random_direction(rng: RandomNumberGenerator) -> Vector3i:
	var directions: Array[Vector3i] = [Vector3i.RIGHT, Vector3i.BACK, Vector3i.LEFT, Vector3i.FORWARD]
	return directions[rng.randi_range(0, 3)]


static func _initial_factory(rng: RandomNumberGenerator, seed_value: int) -> Dictionary:
	var world: VoxelWorldData = VoxelWorldData.new()
	assert(world.generate_flat(Vector3i(-12, -4, -12), Vector3i(12, 12, 12)))
	var reference: Reference = Reference.new()
	reference.bind_world(world, float(rng.randi_range(3, 17)) / 100.0, rng.randi_range(1, 3))
	var cells: Array[Dictionary] = []
	var z: int = rng.randi_range(-8, -5)
	var length: int = rng.randi_range(4, 7)
	for x: int in range(-10, -10 + length):
		_place_initial(world, reference, cells, Vector3i(x, 0, z),
			VoxelWorldData.Block.MINER if x == -10 else VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	_place_initial(world, reference, cells, Vector3i(-10 + length, 0, z), VoxelWorldData.Block.CHEST, Vector3i.RIGHT)
	# Both side ports merge with the straight input.
	_place_initial(world, reference, cells, Vector3i(-8, 0, z - 1), VoxelWorldData.Block.MINER, Vector3i.BACK)
	_place_initial(world, reference, cells, Vector3i(-8, 0, z + 1), VoxelWorldData.Block.MINER, Vector3i.FORWARD)
	var ring: Array[Vector3i] = [Vector3i.ZERO, Vector3i.RIGHT, Vector3i(1, 0, 1), Vector3i.BACK]
	var directions: Array[Vector3i] = [Vector3i.RIGHT, Vector3i.BACK, Vector3i.LEFT, Vector3i.FORWARD]
	for index: int in range(4):
		_place_initial(world, reference, cells, ring[index], VoxelWorldData.Block.BELT, directions[index])
	_place_initial(world, reference, cells, Vector3i.LEFT, VoxelWorldData.Block.MINER, Vector3i.RIGHT)
	_place_initial(world, reference, cells, Vector3i(3, 0, 4), VoxelWorldData.Block.MINER, Vector3i.RIGHT)
	_place_initial(world, reference, cells, Vector3i(4, 0, 4), VoxelWorldData.Block.BELT_UP_EAST, Vector3i.RIGHT)
	_place_initial(world, reference, cells, Vector3i(5, 1, 4), VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	_place_initial(world, reference, cells, Vector3i(6, 0, 4), VoxelWorldData.Block.BELT_DOWN_EAST, Vector3i.RIGHT)
	_place_initial(world, reference, cells, Vector3i(7, 0, 4), VoxelWorldData.Block.BELT, Vector3i.RIGHT)
	_place_initial(world, reference, cells, Vector3i(8, 0, 4), VoxelWorldData.Block.CHEST, Vector3i.RIGHT)
	_place_initial(world, reference, cells, Vector3i(10, 0, -8), VoxelWorldData.Block.CHEST, Vector3i.FORWARD)
	reference.advance(1e-10)
	var state: Dictionary = reference.save_state()
	var rows: Array = state["machines"]
	# Some seeds begin with a full circulating ring and others with an empty ring.
	if seed_value % 2 != 0:
		var next_id: int = 1
		for row: Dictionary in rows:
			var ring_index: int = ring.find(row["cell"])
			if ring_index < 0:
				continue
			row["quantity"] = 2
			row["eligible"] = 2
			row["ores"] = [
				{"id": next_id, "incoming": directions[(ring_index + 3) % 4], "progress": 1.0},
				{"id": next_id + 1, "incoming": directions[(ring_index + 3) % 4], "progress": 0.5},
			]
			next_id += 2
		state["next_id"] = next_id
	return {"world": cells, "minimum": world.minimum, "maximum": world.maximum, "logistics": state}


static func _place_initial(
	world: VoxelWorldData, reference: Reference, cells: Array[Dictionary],
	cell: Vector3i, block: int, direction: Vector3i
) -> void:
	assert(world.place_block(cell, block), "Replay fixture must be geometrically legal")
	assert(reference.set_direction(cell, direction))
	cells.append({"cell": cell, "block": block})


static func _total(state: Dictionary) -> int:
	var total: int = 0
	var rows: Array = state["machines"]
	for row: Dictionary in rows:
		total += int(row["quantity"])
	return total


static func _sample_rows(subject: LogisticsData, extra_time: float) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for queue: LogisticsOreQueue in subject.sample_belts(extra_time):
		var ores: Array[Dictionary] = []
		for ore: LogisticsOre in queue.ores:
			ores.append({"id": ore.id, "incoming": ore.incoming_direction, "progress": ore.progress})
		rows.append({"cell": queue.cell, "direction": queue.direction, "block": queue.block, "ores": ores})
	rows.sort_custom(_row_less)
	return rows


static func run_operations(seed_value: int, initial: Dictionary, operations: Array[Dictionary]) -> Dictionary:
	var world: VoxelWorldData = VoxelWorldData.new()
	assert(world.generate_flat(initial["minimum"], initial["maximum"]))
	var cells: Array = initial["world"]
	for row: Dictionary in cells:
		assert(world.place_block(row["cell"], row["block"]))
	var subject: LogisticsData = LogisticsData.new()
	subject.bind_world(world)
	var reference: Reference = Reference.new()
	reference.bind_world(world)
	var state: Dictionary = initial["logistics"]
	var result: Dictionary = {
		"initial": initial.duplicate(true), "operations": operations.duplicate(true), "failure": {},
		"initial_total": _total(state), "production": 0, "inserted": 0, "removed": 0,
		"restores": 0, "rotations": 0, "placements": 0, "deletions": 0, "checked_ticks": 0,
		"non_last_deletions": 0, "connected_deletions": 0, "loaded_belt_deletions": 0,
		"connected_inventory_edits": 0,
	}
	if not subject.restore_state(state):
		result["failure"] = failure_context(seed_value, int(state["tick"]), _difference("initial.restore", true, false), initial, initial, [])
		return result
	reference.restore_state(state)
	var prefix: Array[Dictionary] = []
	for operation: Dictionary in operations:
		var before: Dictionary = reference.save_state()
		var before_world: Dictionary = _world_snapshot(world, before)
		prefix.append(operation)
		var accepted: bool = _execute(operation, world, subject, reference, result, before)
		var expected: Dictionary = reference.save_state()
		var actual: Dictionary = subject.save_state()
		var difference: Dictionary = first_difference(canonical_state(expected), canonical_state(actual))
		if not accepted:
			difference = _difference("operation.accepted", true, false)
		if difference.is_empty():
			var expected_total: int = int(result["initial_total"]) + int(result["production"]) + int(result["inserted"]) - int(result["removed"])
			difference = first_difference(expected_total, _total(actual), "ledger.total")
		if difference.is_empty():
			# Generous lookahead is clipped by the same next-tick boundary on both sides.
			for extra: float in [0.0, 0.007, 100.0]:
				var expected_sample: Array[Dictionary] = reference.sample_state(extra)
				expected_sample.sort_custom(_row_less)
				difference = first_difference(expected_sample, _sample_rows(subject, extra), "sample")
				if not difference.is_empty():
					break
		if not difference.is_empty():
			result["failure"] = failure_context(seed_value, int(expected["tick"]), difference, initial, before_world, prefix)
			break
	result["final_state"] = canonical_state(subject.save_state())
	result["final_total"] = subject.total_ore()
	return result


static func _world_snapshot(world: VoxelWorldData, logistics: Dictionary) -> Dictionary:
	# Replay edits only facilities above an unchanged flat floor.
	var rows: Array = logistics["machines"]
	var cells: Array[Dictionary] = []
	for row: Dictionary in rows:
		cells.append({"cell": row["cell"], "block": row["block"]})
	return {
		"world": cells, "minimum": world.minimum, "maximum": world.maximum,
		"logistics": logistics.duplicate(true),
	}


static func _connected(state: Dictionary, index: int) -> bool:
	var outgoing: Array = state["outgoing"]
	var inputs: Array = state["inputs"]
	return outgoing[index] >= 0 or inputs[index * 3] >= 0 or inputs[index * 3 + 1] >= 0 or inputs[index * 3 + 2] >= 0


static func _execute(
	operation: Dictionary, world: VoxelWorldData, subject: LogisticsData, reference: Reference,
	result: Dictionary, before: Dictionary
) -> bool:
	var kind: String = operation["kind"]
	match kind:
		"advance":
			var delta: float = operation["delta"]
			# A replay observation must contain at most one actual logic boundary.
			if not is_finite(delta) or delta < 0.0 or delta > STEP:
				return false
			reference.advance(delta)
			subject.advance(delta)
			var expected: Dictionary = reference.save_state()
			result["checked_ticks"] += int(expected["tick"]) - int(before["tick"])
			result["production"] += production_between(before, int(expected["tick"]))
		"place":
			var cell: Vector3i = operation["cell"]
			var block: int = operation["block"]
			var direction: Vector3i = operation["direction"]
			if not world.place_block(cell, block):
				return false
			result["placements"] += 1
			return subject.set_direction(cell, direction) and reference.set_direction(cell, direction)
		"delete":
			var cell: Vector3i = operation["cell"]
			# Deletion removes that facility's entire inventory, including produced ore.
			var rows: Array = before["machines"]
			for index: int in range(rows.size()):
				var row: Dictionary = rows[index]
				if row["cell"] == cell:
					result["removed"] += int(row["quantity"])
					if index != rows.size() - 1:
						result["non_last_deletions"] += 1
					if _connected(before, index):
						result["connected_deletions"] += 1
					if VoxelWorldData.is_belt(int(row["block"])) and int(row["quantity"]) > 0:
						result["loaded_belt_deletions"] += 1
					break
			result["deletions"] += 1
			return world.break_block(cell)
		"rotate":
			result["rotations"] += 1
			return subject.set_direction(operation["cell"], operation["direction"]) and reference.set_direction(operation["cell"], operation["direction"])
		"configure":
			subject.configure_miners(operation["interval"], operation["amount"])
			reference.configure_miners(operation["interval"], operation["amount"])
		"restore":
			# Use each simulator's own saved state; do not overwrite a divergence.
			var actual: Dictionary = subject.save_state()
			result["restores"] += 1
			return subject.restore_state(actual) and reference.restore_state(before)
		"inventory":
			var expected: Dictionary = before.duplicate(true)
			var actual: Dictionary = subject.save_state()
			var amount: int = operation["amount"]
			var cell: Vector3i = operation["cell"]
			var rows: Array = before["machines"]
			for index: int in range(rows.size()):
				if rows[index]["cell"] == cell and _connected(before, index):
					result["connected_inventory_edits"] += 1
					break
			if not _change_inventory(expected, cell, amount) or not _change_inventory(actual, cell, amount):
				return false
			result["inserted" if amount > 0 else "removed"] += absi(amount)
			return subject.restore_state(actual) and reference.restore_state(expected)
		_:
			return false
	return true


static func _change_inventory(state: Dictionary, cell: Vector3i, amount: int) -> bool:
	var rows: Array = state["machines"]
	for row: Dictionary in rows:
		if row["cell"] != cell:
			continue
		if row["block"] != VoxelWorldData.Block.CHEST or int(row["quantity"]) + amount < 0:
			return false
		row["quantity"] += amount
		# Inventory editing does not make arrivals eligible for a second same-tick flush.
		row["eligible"] = mini(int(row["eligible"]), int(row["quantity"]))
		return true
	return false


static func first_difference(expected: Variant, actual: Variant, path: String = "state") -> Dictionary:
	if typeof(expected) != typeof(actual):
		return _difference(path, expected, actual)
	if expected is Dictionary:
		var left: Dictionary = expected
		var right: Dictionary = actual
		if left.size() != right.size():
			return _difference(path + ".keys", left.keys(), right.keys())
		for key: Variant in left:
			if not right.has(key):
				return _difference(path + ".keys", left.keys(), right.keys())
			var difference: Dictionary = first_difference(left[key], right[key], path + "." + str(key))
			if not difference.is_empty():
				return difference
		return {}
	if expected is Array:
		var left: Array = expected
		var right: Array = actual
		if left.size() != right.size():
			return _difference(path + ".size", left.size(), right.size())
		for index: int in range(left.size()):
			var difference: Dictionary = first_difference(left[index], right[index], "%s[%d]" % [path, index])
			if not difference.is_empty():
				return difference
		return {}
	if expected is float and path.ends_with(".progress"):
		var left: float = expected
		var right: float = actual
		if is_finite(left) and is_finite(right) and absf(left - right) <= 0.000001:
			return {}
	return {} if expected == actual else _difference(path, expected, actual)


static func _difference(path: String, expected: Variant, actual: Variant) -> Dictionary:
	return {"path": path, "expected": expected, "actual": actual}


static func encode_failure(context: Dictionary) -> PackedByteArray:
	# Text formatting rounds float64 clock compensation; binary Variant keeps it exact.
	return var_to_bytes(context)


static func canonical_state(state: Dictionary) -> Dictionary:
	var rows: Array = state["machines"]
	var outgoing: Array = state["outgoing"]
	var inputs: Array = state["inputs"]
	# Put lengths first in both valid and malformed results, so the comparator
	# reports the broken array and both lengths before examining any row.
	var result: Dictionary = {"adjacency_lengths": {"outgoing": outgoing.size(), "inputs": inputs.size()}}
	result.merge(state.duplicate(true))
	result.erase("outgoing")
	result.erase("inputs")
	if outgoing.size() != rows.size() or inputs.size() != rows.size() * 3:
		return result
	var canonical: Array[Dictionary] = []
	for index: int in range(rows.size()):
		var source: Dictionary = rows[index]
		var row: Dictionary = source.duplicate(true)
		row["outgoing"] = _edge_cell(rows, outgoing[index])
		var ports: Array = []
		for port: int in range(3):
			var input: int = inputs[index * 3 + port]
			ports.append(_edge_cell(rows, input))
		row["inputs"] = ports
		canonical.append(row)
	canonical.sort_custom(_row_less)
	result["machines"] = canonical
	return result


static func _edge_cell(rows: Array, index: int) -> Variant:
	if index == -1:
		return null
	if index < -1 or index >= rows.size():
		return {"invalid_index": index}
	return rows[index]["cell"]


static func _row_less(a: Dictionary, b: Dictionary) -> bool:
	var left: Vector3i = a["cell"]
	var right: Vector3i = b["cell"]
	if left.x != right.x:
		return left.x < right.x
	if left.y != right.y:
		return left.y < right.y
	return left.z < right.z


static func failure_context(
	seed_value: int, tick: int, difference: Dictionary, initial: Dictionary,
	before: Dictionary, operations: Array[Dictionary]
) -> Dictionary:
	return {
		"seed": seed_value, "tick": tick, "difference": difference.duplicate(true),
		"initial": initial.duplicate(true), "before": before.duplicate(true),
		"operations": operations.duplicate(true),
	}
