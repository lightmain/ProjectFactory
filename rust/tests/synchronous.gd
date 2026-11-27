extends SceneTree
## Normal playable bridge contract, checked against the actual loaded extension.


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var backend: RefCounted = ClassDB.instantiate(&"FactoryBackend") as RefCounted
	assert(backend != null)
	assert(backend.has_method("create_factory"), "M05 synchronous factory is missing")
	assert(_result(backend, "open_backend", [{"api_version": 1}]).ok)
	for ruleset: String in ["legacy_discrete_v1", "conveyor_continuous_v1"]:
		assert(_result(backend, "create_factory", [ruleset]).ok)
		var before: Dictionary = _result(backend, "observe_factory")
		assert(before.ok and before.ruleset == ruleset)
		assert(before.machines.size() == 6)
		var hit: Dictionary = _result(backend, "cast_ray", [Vector3(0.25, 4, 0.25), Vector3.DOWN, 10.0])
		assert(hit.ok and hit.hit and hit.cell == Vector3i(0, 0, 0))
		assert(_result(backend, "place_block", [Vector3i(2, 0, 0), 5, 3]).ok)
		assert(not _result(backend, "place_block", [Vector3i(2, 0, 0), 5, 3]).ok)
		assert(_result(backend, "rotate_block", [Vector3i(2, 0, 0), 0]).ok)
		assert(_result(backend, "remove_block", [Vector3i(2, 0, 0)]).ok)
		for tick: int in range(600):
			assert(_result(backend, "advance_factory", [1.0 / 60.0]).ok)
		var after: Dictionary = _result(backend, "observe_factory")
		var total: int = 0
		var chest: int = 0
		for machine: Dictionary in after.machines:
			total += int(machine.quantity)
			if machine.block == 7:
				chest += int(machine.quantity)
		assert(chest > 0)
		assert(total == after.produced + after.initial - after.removed)
		_check_route(backend)
	_check_split(backend)
	assert(_result(backend, "close_backend").ok)
	assert(not _result(backend, "advance_factory", [0.1]).ok)
	print("FACTORY_SYNCHRONOUS_PASS")
	quit()


func _result(backend: RefCounted, method: String, arguments: Array = []) -> Dictionary:
	var value: Variant = backend.callv(method, arguments)
	assert(value is Dictionary)
	return value as Dictionary


func _check_route(backend: RefCounted) -> void:
	assert(backend.has_method("begin_belt_route"), "Complete route bridge is missing")
	assert(_result(backend, "begin_belt_route", [Vector3i(2, 0, 0), 0]).ok)
	var route: Dictionary = _result(backend, "preview_belt_route", [Vector3i(4, 0, 2), 0])
	assert(route.ok and route.active and route.cells.size() == 5)
	assert(Vector3i(route.cells[1]) == Vector3i(2, 0, 1))
	assert(_result(backend, "toggle_belt_route_order").ok)
	route = _result(backend, "preview_belt_route", [Vector3i(4, 0, 2), 0])
	assert(route.ok and Vector3i(route.cells[1]) == Vector3i(3, 0, 0))
	assert(_result(backend, "lock_belt_route").ok)
	route = _result(backend, "preview_belt_route", [Vector3i(4, 0, 4), 0])
	assert(route.ok and route.locked_points.size() == 1 and route.cells.size() == 7)
	assert(_result(backend, "commit_belt_route").ok)
	assert(not _result(backend, "preview_belt_route", [null, 0]).active)
	assert(_result(backend, "begin_belt_route", [Vector3i(2, 0, 0), 0]).ok)
	route = _result(backend, "preview_belt_route", [Vector3i(5, 0, 0), 0])
	assert(not route.ok, "Existing intermediate belt must reject crossing")
	var before: Dictionary = _result(backend, "observe_factory")
	assert(not _result(backend, "commit_belt_route").ok)
	var after: Dictionary = _result(backend, "observe_factory")
	assert(after.revision == before.revision and after.cells == before.cells)
	assert(_result(backend, "cancel_belt_route").ok)
	assert(_result(backend, "place_block", [Vector3i(-3, 0, 2), 1, 0]).ok)
	assert(_result(backend, "begin_belt_route", [Vector3i(-5, 0, 2), 3]).ok)
	route = _result(backend, "preview_belt_route", [Vector3i(-1, 0, 2), 3])
	assert(route.ok)
	var has_slope: bool = false
	for block: int in route.blocks:
		has_slope = has_slope or block >= 9
	assert(has_slope, "Terrain must produce ramps")
	assert(_result(backend, "commit_belt_route").ok)


func _check_split(backend: RefCounted) -> void:
	assert(_result(backend, "create_factory", ["conveyor_continuous_v1"]).ok)
	assert(_result(backend, "begin_belt_route", [Vector3i(0, 0, 2), 3]).ok)
	assert(_result(backend, "preview_belt_route", [Vector3i(2, 0, 2), 3]).ok)
	assert(_result(backend, "commit_belt_route").ok)
	var state: Dictionary = _result(backend, "observe_factory")
	for row: Dictionary in state.machines:
		if row.cell == Vector3i(0, 0, 2):
			assert(row.inputs.size() == 1 and row.outputs.size() == 2)
	assert(_result(backend, "place_block", [Vector3i(3, 0, 2), 7, 3]).ok)
	for tick: int in range(600):
		assert(_result(backend, "advance_factory", [1.0 / 60.0]).ok)
	state = _result(backend, "observe_factory")
	var total: int = 0
	for row: Dictionary in state.machines:
		total += int(row.quantity)
		if row.block == 7:
			assert(row.quantity > 0, "Both split outputs must receive items")
	assert(total == state.produced)
	var tick_before: int = state.tick
	assert(_result(backend, "remove_block", [Vector3i(1, 0, 2)]).ok)
	state = _result(backend, "observe_factory")
	assert(state.tick == tick_before)
	for row: Dictionary in state.machines:
		if row.cell == Vector3i(0, 0, 2):
			assert(row.outputs.size() == 1)
