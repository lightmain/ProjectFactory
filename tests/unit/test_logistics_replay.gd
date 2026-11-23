extends GdUnitTestSuite

const Replay = preload("res://tests/support/logistics_replay.gd")


func test_comparator_reports_first_field_and_exact_integer_and_id_changes() -> void:
	var expected: Dictionary = {"tick": 17, "ores": [{"id": 9, "progress": 0.5}]}
	var changed: Dictionary = expected.duplicate(true)
	changed["tick"] = 18
	var difference: Dictionary = Replay.first_difference(expected, changed)
	assert_bool(difference.is_empty()).is_false()
	assert_str(str(difference.get("path"))).is_equal("state.tick")
	assert_int(int(difference.get("expected", -1))).is_equal(17)
	assert_int(int(difference.get("actual", -1))).is_equal(18)
	changed = expected.duplicate(true)
	var ores: Array = changed["ores"]
	var ore: Dictionary = ores[0]
	ore["id"] = 10
	assert_str(str(Replay.first_difference(expected, changed).get("path"))).is_equal("state.ores[0].id")


func test_only_ore_progress_uses_tolerance_and_nonfinite_phase_is_exact() -> void:
	var expected: Dictionary = {"placed": 0.5, "next": INF, "ores": [{"progress": 0.5}]}
	var changed: Dictionary = expected.duplicate(true)
	var ores: Array = changed["ores"]
	var ore: Dictionary = ores[0]
	ore["progress"] = 0.5000005
	assert_bool(Replay.first_difference(expected, changed).is_empty()).is_true()
	ore["progress"] = 0.500002
	assert_str(str(Replay.first_difference(expected, changed).get("path"))).is_equal("state.ores[0].progress")
	changed = expected.duplicate(true)
	changed["placed"] = 0.5000000001
	assert_str(str(Replay.first_difference(expected, changed).get("path"))).is_equal("state.placed")
	changed = expected.duplicate(true)
	assert_bool(Replay.first_difference(expected, changed).is_empty()).is_true()
	changed["next"] = -INF
	assert_str(str(Replay.first_difference(expected, changed).get("path"))).is_equal("state.next")


func test_dictionary_keys_array_order_and_pending_state_are_not_ignored() -> void:
	assert_bool(Replay.first_difference({"a": 1}, {"b": 1}).is_empty()).is_false()
	assert_bool(Replay.first_difference([1, 2], [2, 1]).is_empty()).is_false()
	for field: String in ["cursor", "cycles", "last_output", "eligible", "dirty", "settled"]:
		assert_bool(Replay.first_difference({field: 0}, {field: 1}).is_empty()).is_false()


func test_machine_storage_permutation_is_canonicalized_with_edges() -> void:
	var a: Vector3i = Vector3i(-2, 0, 0)
	var b: Vector3i = Vector3i(-1, 0, 0)
	var first: Dictionary = {
		"machines": [{"cell": a, "quantity": 1}, {"cell": b, "quantity": 2}],
		"outgoing": [1, -1], "inputs": [-1, -1, -1, 0, -1, -1], "tick": 1,
	}
	var second: Dictionary = {
		"machines": [{"cell": b, "quantity": 2}, {"cell": a, "quantity": 1}],
		"outgoing": [-1, 0], "inputs": [1, -1, -1, -1, -1, -1], "tick": 1,
	}
	assert_bool(Replay.canonical_state(first) == Replay.canonical_state(second)).is_true()
	second["outgoing"] = [-1, -1]
	assert_bool(Replay.first_difference(Replay.canonical_state(first), Replay.canonical_state(second)).is_empty()).is_false()


func test_failure_context_owns_replayable_snapshots_and_operation_prefix() -> void:
	var initial: Dictionary = {"world": {"seed": 4}}
	var before: Dictionary = {"tick": 12}
	var operations: Array[Dictionary] = [{"kind": "advance", "delta": 0.1}]
	var context: Dictionary = Replay.failure_context(42, 13, {"path": "state.tick"}, initial, before, operations)
	initial.clear()
	before.clear()
	operations.clear()
	assert_int(context["seed"]).is_equal(42)
	assert_int(context["tick"]).is_equal(13)
	assert_int(context["operations"].size()).is_equal(1)
	assert_int(context["before"]["tick"]).is_equal(12)
	assert_int(context["initial"]["world"]["seed"]).is_equal(4)


func test_production_ledger_uses_prior_phase_not_observed_quantity_delta() -> void:
	var state: Dictionary = {"machines": [
		{"block": VoxelWorldData.Block.MINER, "placed": 0.003, "interval": 0.17, "amount": 2, "cycles": 2},
		{"block": VoxelWorldData.Block.MINER, "placed": 0.2, "interval": 0.1, "amount": 3, "cycles": 2},
		{"block": VoxelWorldData.Block.MINER, "placed": 0.0, "interval": 0.0, "amount": 5, "cycles": 0},
		{"block": VoxelWorldData.Block.CHEST, "placed": 0.0, "interval": 0.1, "amount": 5, "cycles": 0},
	]}
	# At t=1: first has 5 cycles (6 ore new), second 8 cycles (18 ore new).
	assert_int(Replay.production_between(state, 60)).is_equal(24)


func test_seeded_whole_factory_replay_checks_every_tick_and_accounts_for_edits() -> void:
	for seed_value: int in [7, 42, 601, 20261109]:
		var result: Dictionary = Replay.run_seed(seed_value, 240)
		assert_bool(result.has("failure")).is_true()
		if not result.has("failure"):
			continue
		assert_bool(result["failure"].is_empty()).override_failure_message(var_to_str(result["failure"])).is_true()
		if not result["failure"].is_empty():
			continue
		assert_int(result["checked_ticks"]).is_greater_equal(240)
		assert_int(result["production"]).is_greater(0)
		assert_int(result["inserted"]).is_greater(0)
		assert_int(result["removed"]).is_greater(0)
		assert_int(result["restores"]).is_greater(0)
		assert_int(result["rotations"]).is_greater(0)
		assert_int(result["placements"]).is_greater(0)
		assert_int(result["deletions"]).is_greater(0)
		assert_int(result.get("non_last_deletions", 0)).is_greater(0)
		assert_int(result.get("connected_deletions", 0)).is_greater(0)
		assert_int(result.get("loaded_belt_deletions", 0)).is_greater(0)
		assert_int(result.get("connected_inventory_edits", 0)).is_greater(0)
		assert_int(result["final_total"]).is_equal(result["initial_total"] + result["production"] + result["inserted"] - result["removed"])


func test_replay_seed_reproduces_world_operations_and_final_state() -> void:
	var first: Dictionary = Replay.run_seed(42, 60)
	var second: Dictionary = Replay.run_seed(42, 60)
	assert_bool(first == second).is_true()
	assert_int(first.get("checked_ticks", 0)).is_greater_equal(60)
	if not first.has("initial"):
		return
	var operations: Array[Dictionary] = []
	operations.assign(first["operations"])
	var replayed: Dictionary = Replay.run_operations(42, first["initial"], operations)
	assert_bool(replayed == first).is_true()


func test_first_failure_prefix_survives_serialization_and_replays_same_tick() -> void:
	var valid: Dictionary = Replay.run_seed(7, 17)
	assert_bool(valid.get("failure", {"missing": true}).is_empty()).is_true()
	if not valid.has("initial") or not valid["failure"].is_empty():
		return
	var operations: Array[Dictionary] = []
	operations.assign(valid["operations"])
	operations.append({"kind": "invalid_operation"})
	operations.append({"kind": "advance", "delta": 1.0})
	var failed: Dictionary = Replay.run_operations(7, valid["initial"], operations)
	var failure: Dictionary = failed["failure"]
	assert_int(failure["operations"].size()).is_equal(operations.size() - 1)
	assert_int(failure["tick"]).is_equal(17)
	assert_str(failure["difference"]["path"]).is_equal("operation.accepted")
	var decoded: Variant = bytes_to_var(Replay.encode_failure(failure))
	assert_bool(decoded is Dictionary).is_true()
	if not decoded is Dictionary:
		return
	var restored: Dictionary = decoded
	var prefix: Array[Dictionary] = []
	prefix.assign(restored["operations"])
	var replayed: Dictionary = Replay.run_operations(restored["seed"], restored["initial"], prefix)
	assert_bool(replayed["failure"] == failure).is_true()
	assert_bool(restored["before"].has("world")).is_true()
	if not restored["before"].has("world"):
		return
	var from_before: Dictionary = Replay.run_operations(7, restored["before"], [])
	assert_bool(from_before["failure"].is_empty()).is_true()
	assert_bool(from_before["final_state"] == valid["final_state"]).is_true()
	assert_vector(restored["before"]["minimum"]).is_equal(Vector3i(-12, -4, -12))
	assert_vector(restored["before"]["maximum"]).is_equal(Vector3i(12, 12, 12))


func test_replay_rejects_multi_tick_input_before_advancing() -> void:
	var valid: Dictionary = Replay.run_seed(42, 0)
	var result: Dictionary = Replay.run_operations(42, valid["initial"], [{"kind": "advance", "delta": 1.0}])
	assert_bool(result["failure"].is_empty()).is_false()
	assert_int(result["checked_ticks"]).is_equal(0)
	assert_bool(result["final_state"] == Replay.canonical_state(valid["initial"]["logistics"])).is_true()


func test_comparator_reports_invalid_adjacency_without_indexing_outside_rows() -> void:
	var valid: Dictionary = {
		"machines": [{"cell": Vector3i.ZERO}], "outgoing": [-1], "inputs": [-1, -1, -1],
	}
	var corrupt: Dictionary = valid.duplicate(true)
	corrupt["outgoing"] = [7]
	var difference: Dictionary = Replay.first_difference(Replay.canonical_state(valid), Replay.canonical_state(corrupt))
	assert_str(str(difference.get("path"))).is_equal("state.machines[0].outgoing")
	corrupt["outgoing"] = [-1]
	corrupt["inputs"] = [-1, -2, -1]
	difference = Replay.first_difference(Replay.canonical_state(valid), Replay.canonical_state(corrupt))
	assert_str(str(difference.get("path"))).is_equal("state.machines[0].inputs[1]")
	corrupt["inputs"] = [-1]
	difference = Replay.first_difference(Replay.canonical_state(valid), Replay.canonical_state(corrupt))
	assert_str(str(difference.get("path"))).is_equal("state.adjacency_lengths.inputs")
	assert_that(difference.get("expected")).is_equal(3)
	assert_that(difference.get("actual")).is_equal(1)
	corrupt["inputs"] = [-1, -1, -1]
	corrupt["outgoing"] = [-1, -1]
	difference = Replay.first_difference(Replay.canonical_state(valid), Replay.canonical_state(corrupt))
	assert_str(str(difference.get("path"))).is_equal("state.adjacency_lengths.outgoing")
	assert_that(difference.get("expected")).is_equal(1)
	assert_that(difference.get("actual")).is_equal(2)
