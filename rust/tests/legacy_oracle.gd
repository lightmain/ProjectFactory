extends SceneTree
## Synthetic legacy saves, generated and re-read by the actual Godot rules.
## Only a new output directory is accepted. No player's save directory is used.

const REPLAY = preload("res://tests/support/logistics_replay.gd")
const STEP: float = LogisticsData.LOGIC_STEP
const WORLD_NAME: String = "黄金夹具"

var _output: String


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 2 or args[0] not in ["generate", "verify"]:
		printerr("Usage: legacy_oracle.gd -- generate|verify /path/to/fixtures")
		quit(2)
		return
	_output = args[1]
	if args[0] == "verify":
		_verify()
		return
	assert(not DirAccess.dir_exists_absolute(_output) and not FileAccess.file_exists(_output))
	assert(DirAccess.make_dir_recursive_absolute(_output) == OK)
	var manifest: Dictionary = {
		"engine": Engine.get_version_info()["string"],
		"synthetic_player_data": true,
		"fixtures": [],
		"variant_probes": _variant_probes(),
		"rejections": {},
		"rejection_files": {},
	}
	var provenance: String = OS.get_environment("FACTORY_ORACLE_PROVENANCE")
	assert(not provenance.is_empty())
	manifest["provenance"] = JSON.parse_string(FileAccess.get_file_as_string(provenance))
	assert(manifest["provenance"] is Dictionary)
	var cases: Array[Dictionary] = [
		{"version": 1, "layout": "dictionary", "scenario": "running"},
		{"version": 2, "layout": "dictionary", "scenario": "running"},
		{"version": 3, "layout": "dictionary", "scenario": "running"},
		{"version": 4, "layout": "dictionary", "scenario": "running"},
		{"version": 4, "layout": "packed", "scenario": "running"},
		{"version": 4, "layout": "continuous", "scenario": "running"},
		{"version": 1, "layout": "dictionary", "scenario": "empty"},
		{"version": 2, "layout": "dictionary", "scenario": "empty"},
		{"version": 3, "layout": "dictionary", "scenario": "empty"},
		{"version": 4, "layout": "packed", "scenario": "empty"},
		{"version": 4, "layout": "dictionary", "scenario": "running", "phase": "boundary_flush"},
		{"version": 4, "layout": "continuous", "scenario": "running", "phase": "native_run"},
	]
	var fixture_rows: Array = manifest["fixtures"]
	for configuration: Dictionary in cases:
		fixture_rows.append(_generate_fixture(configuration))
	manifest["rejections"] = _rejections(manifest["rejection_files"])
	var file: FileAccess = FileAccess.open(_output.path_join("manifest.json"), FileAccess.WRITE)
	assert(file != null)
	file.store_string(JSON.stringify(manifest, "\t") + "\n")
	file.close()
	print("LEGACY_ORACLE_GENERATED ", _output)
	quit(0)


func _new_snapshot(version: int, layout: String, scenario: String, phase: String = "pending") -> SessionSnapshot:
	var snapshot: SessionSnapshot = SessionSnapshot.new()
	if version < 4:
		assert(snapshot.world.generate_flat())
	else:
		assert(snapshot.world.generate_flat(Vector3i(-8, -4, -8), Vector3i(8, 12, 8), 4))
	snapshot.world_id = "synthetic_legacy_fixture".md5_text()
	snapshot.world_name = WORLD_NAME
	snapshot.position = Vector3(-0.5, 0.01, 2.25)
	snapshot.spawn = Vector3(-0.5, 0.01, 2.25)
	snapshot.velocity = Vector3(0.125, -0.25, 0.375)
	snapshot.view_rotation = Vector3(-0.25, 1.25, 0.0)
	snapshot.selected_block = VoxelWorldData.Block.BELT
	snapshot.build_rotation = 3
	snapshot.logistics.bind_world(snapshot.world, 0.17, 2)
	if scenario == "empty":
		return snapshot
	for x: int in range(-4, 2):
		var block: int = VoxelWorldData.Block.MINER if x == -4 else (
			VoxelWorldData.Block.CHEST if x == 1 else VoxelWorldData.Block.BELT)
		_place(snapshot, Vector3i(x, 0, 0), block, Vector3i.RIGHT)
	_place(snapshot, Vector3i(-2, 0, -1), VoxelWorldData.Block.MINER, Vector3i.BACK)
	_place(snapshot, Vector3i(-2, 0, 1), VoxelWorldData.Block.MINER, Vector3i.FORWARD)
	var ring: Array[Vector3i] = [
		Vector3i(2, 0, 3), Vector3i(3, 0, 3), Vector3i(3, 0, 4), Vector3i(2, 0, 4),
	]
	for index: int in range(ring.size()):
		_place(snapshot, ring[index], VoxelWorldData.Block.BELT,
			ring[(index + 1) % ring.size()] - ring[index])
	if version >= 2:
		assert(snapshot.world.place_structure(Vector3i(4, 0, -4), 3))
	if version >= 3:
		_place(snapshot, Vector3i(-4, 0, -4), VoxelWorldData.Block.MINER, Vector3i.RIGHT)
		_place(snapshot, Vector3i(-3, 0, -4), VoxelWorldData.Block.BELT_UP_EAST, Vector3i.RIGHT)
		_place(snapshot, Vector3i(-2, 1, -4), VoxelWorldData.Block.BELT, Vector3i.RIGHT)
		_place(snapshot, Vector3i(-1, 0, -4), VoxelWorldData.Block.BELT_DOWN_EAST, Vector3i.RIGHT)
		_place(snapshot, Vector3i(0, 0, -4), VoxelWorldData.Block.BELT, Vector3i.RIGHT)
		_place(snapshot, Vector3i(1, 0, -4), VoxelWorldData.Block.CHEST, Vector3i.RIGHT)
	assert(snapshot.logistics.prefill_belts())
	for delta: float in [0.2, 0.1, 0.013]:
		snapshot.logistics.advance(delta)
	# Save a changed topology before its next boundary settles.
	assert(snapshot.logistics.set_direction(Vector3i(-1, 0, 0), Vector3i.BACK))
	if layout == "continuous":
		# Legal queues may overlap across a newly connected seam. Preserve a
		# nonempty waiting edge in the actual native checkpoint, not a label.
		var discrete: Dictionary = snapshot.logistics.save_state()
		var rows: Array = discrete["machines"]
		for row: Dictionary in rows:
			if row["cell"] == ring[1]:
				var ores: Array = row["ores"]
				assert(ores.size() == 2)
				ores[0]["progress"] = 0.51
				ores[1]["progress"] = 0.01
		assert(snapshot.logistics.restore_state(discrete))
		assert(snapshot.logistics.enable_rust_transport(), snapshot.logistics.transport_error())
		if phase == "native_run":
			for tick: int in range(6):
				_step(snapshot)
	elif phase == "boundary_flush":
		var clock: Dictionary = snapshot.logistics.save_packed_state()
		snapshot.logistics.advance((float(clock["tick"]) + 1.0) * STEP - float(clock["time"]))
		_place(snapshot, Vector3i(6, 0, 6), VoxelWorldData.Block.MINER, Vector3i.RIGHT)
		snapshot.logistics.advance(1e-10)
		var flushed: Dictionary = snapshot.logistics.save_packed_state()
		assert(flushed["flushed"] == flushed["tick"])
	return snapshot


func _place(snapshot: SessionSnapshot, cell: Vector3i, block: int, direction: Vector3i) -> void:
	assert(snapshot.world.place_block(cell, block))
	assert(snapshot.logistics.set_direction(cell, direction))


func _state(snapshot: SessionSnapshot, version: int, layout: String) -> Dictionary:
	var state: Dictionary = PressureSaveBuilder.state_for(snapshot)
	state["version"] = version
	if layout == "dictionary":
		state["logistics"] = snapshot.logistics.save_state()
	if version == 1:
		state.erase("structures")
	return state


func _generate_fixture(configuration: Dictionary) -> Dictionary:
	var version: int = configuration["version"]
	var layout: String = configuration["layout"]
	var scenario: String = configuration["scenario"]
	var phase: String = configuration.get("phase", "pending")
	var name: String = "v%d_%s_%s" % [version, layout, scenario]
	if phase != "pending":
		name += "_" + phase
	print("LEGACY_FIXTURE_START ", name)
	var original: SessionSnapshot = _new_snapshot(version, layout, scenario, phase)
	var state: Dictionary = _state(original, version, layout)
	assert(SessionSnapshot.decode(state) != null, name)
	var store: SaveGameStore = SaveGameStore.new()
	store.directory = _output.path_join(name)
	assert(store.save_game(state), store.last_error)
	var restored: SessionSnapshot = store.load_snapshot()
	assert(restored != null, store.last_error)
	var time_state: Dictionary = original.logistics.save_packed_state()
	var pending_links: int = 0
	var native_version: int = 0
	var native_transactions: int = 0
	if layout == "continuous":
		var binding: Dictionary = time_state["binding"]
		var pending: PackedInt64Array = binding["pending"]
		pending_links = pending.size() / 4
		assert(pending_links > 0)
		var native: PackedByteArray = time_state["native"]
		assert(native.slice(0, 4).get_string_from_ascii() == "RCNV")
		native_version = native.decode_u32(4)
		assert(native.decode_u64(32) == time_state["tick"])
		native_transactions = native.decode_u64(48) + native.decode_u64(56) + native.decode_u64(64)
		if phase == "native_run":
			assert(native_version == 2 and native_transactions > 0)
	var row: Dictionary = {
		"name": name, "version": version, "layout": layout, "scenario": scenario,
		"phase": phase,
		"oracle_load_accepted": true, "oracle_continuation_equal": true,
		"replay_ticks": 120, "machines": original.logistics.machine_cells().size(),
		"ores": original.logistics.total_ore(),
		"time_remainder": float(time_state["time"]) - float(time_state["tick"]) * STEP,
		"compensation": time_state["compensation"],
		"flushed": time_state["flushed"],
		"pending_links": pending_links,
		"native_version": native_version, "native_transactions": native_transactions,
		"inventory_slots": original.inventory.save_state().size(),
		"world_name": original.world_name,
		"files": _files(store.directory), "continuation_sha256": [],
	}
	var continuation: Array = row["continuation_sha256"]
	_validate_layout(store.load_game(), row)
	_compare(original, restored)
	var base_state: Dictionary = _static_state(restored)
	for tick: int in range(121):
		_compare_logistics(original, restored)
		continuation.append(_observable_hash(restored, base_state))
		if tick < 120:
			_step(original)
			_step(restored)
	_compare(original, restored)
	assert(_static_state(restored) == base_state)
	print("LEGACY_FIXTURE_END ", name)
	return row


func _compare(left: SessionSnapshot, right: SessionSnapshot) -> void:
	assert(left.world.minimum == right.world.minimum and left.world.maximum == right.world.maximum)
	assert(left.world.floor_depth == right.world.floor_depth)
	assert(left.world.has_flat_baseline() == right.world.has_flat_baseline())
	assert(left.world_id == right.world_id and left.world_name == right.world_name)
	assert(left.world.chunk_deltas() == right.world.chunk_deltas())
	assert(left.world.structure_rows() == right.world.structure_rows())
	assert(left.inventory.save_state() == right.inventory.save_state())
	assert(left.position == right.position and left.velocity == right.velocity)
	assert(left.spawn == right.spawn and left.view_rotation == right.view_rotation)
	assert(left.selected_block == right.selected_block and left.build_rotation == right.build_rotation)
	_compare_logistics(left, right)


func _compare_logistics(left: SessionSnapshot, right: SessionSnapshot) -> void:
	if left.logistics.transport_backend() == "rust":
		assert(left.logistics.transport_error().is_empty() and right.logistics.transport_error().is_empty())
		assert(not left.logistics.save_packed_state().is_empty())
		assert(left.logistics.save_packed_state() == right.logistics.save_packed_state())
	else:
		var difference: Dictionary = REPLAY.first_difference(
			REPLAY.canonical_state(left.logistics.save_state()),
			REPLAY.canonical_state(right.logistics.save_state()))
		assert(difference.is_empty(), var_to_str(difference))


func _static_state(snapshot: SessionSnapshot) -> Dictionary:
	var state: Dictionary = PressureSaveBuilder.state_for(snapshot)
	state.erase("logistics")
	return state


func _observable_hash(snapshot: SessionSnapshot, base_state: Dictionary) -> String:
	assert(snapshot.logistics.transport_error().is_empty())
	var state: Dictionary = base_state.duplicate()
	state["logistics"] = snapshot.logistics.save_packed_state()
	assert(not (state["logistics"] as Dictionary).is_empty())
	return SaveGameFiles.digest(var_to_bytes(state)).hex_encode()


func _step(snapshot: SessionSnapshot) -> void:
	var before: int = snapshot.logistics.logic_tick()
	snapshot.logistics.advance(STEP)
	assert(snapshot.logistics.transport_error().is_empty(), snapshot.logistics.transport_error())
	assert(snapshot.logistics.logic_tick() == before + 1)


func _validate_layout(state: Dictionary, row: Dictionary) -> void:
	assert(not state.is_empty() and state["version"] == row["version"])
	var logistics: Dictionary = state["logistics"]
	assert(logistics["machines"] is Array if row["layout"] == "dictionary" else logistics["machines"] is PackedByteArray)
	assert(logistics.get("backend", "gdscript") == ("rust" if row["layout"] == "continuous" else "gdscript"))
	assert(state["world_name"] == WORLD_NAME and (state["inventory"] as Array).size() == 24)
	assert(logistics["flushed"] == row["flushed"])
	assert(is_equal_approx(float(logistics["compensation"]), float(row["compensation"])))
	if row["version"] < 4:
		assert(state["minimum"] == VoxelWorldData.MIN_CELL and state["maximum"] == VoxelWorldData.MAX_CELL)


func _files(directory: String, prefix: String = "") -> Dictionary:
	var result: Dictionary = {}
	var folder: DirAccess = DirAccess.open(directory.path_join(prefix))
	assert(folder != null)
	for name: String in folder.get_files():
		var relative: String = prefix.path_join(name) if not prefix.is_empty() else name
		var bytes: PackedByteArray = FileAccess.get_file_as_bytes(directory.path_join(relative))
		var record: Dictionary = {
			"bytes": bytes.size(), "sha256": SaveGameFiles.digest(bytes).hex_encode(),
		}
		if name.ends_with(".bin"):
			var raw: PackedByteArray = SaveGameFiles.new().read_blob(
				directory.path_join(relative), SaveGameFiles.SESSION_LIMIT)
			assert(not raw.is_empty())
			record["raw_sha256"] = SaveGameFiles.digest(raw).hex_encode()
			# The Python byte check independently establishes the wrapper.
			record["deflate_wrapper"] = "zlib"
		result[relative] = record
	for name: String in folder.get_directories():
		var relative: String = prefix.path_join(name) if not prefix.is_empty() else name
		result.merge(_files(directory, relative))
	return result


func _variant_probes() -> Dictionary:
	var typed_array: Array[int] = [-7, 0]
	var typed_dictionary: Dictionary[Vector3i, PackedByteArray] = {
		Vector3i(-1, 2, 3): PackedByteArray([0, 127, 255]),
	}
	var values: Dictionary = {
		"null": null, "bool": true, "integer": -7, "wide_integer": 1 << 40,
		"float": 1.5, "wide_float": 1.1, "chinese": WORLD_NAME,
		"vector3": Vector3(-0.5, 1.25, 2.0), "vector3i": Vector3i(-1, 2, 3),
		"array": [-7, null], "dictionary": {"a": -7},
		"bytes": PackedByteArray([0, 127, 255]), "int32s": PackedInt32Array([-1, 2]),
		"int64s": PackedInt64Array([-1, 1 << 40]),
		"float64s": PackedFloat64Array([1.1, -2.0]),
		"typed_array": typed_array, "typed_dictionary": typed_dictionary,
	}
	var probes: Dictionary = {}
	for name: String in values:
		probes[name] = var_to_bytes(values[name]).hex_encode()
	return probes


func _rejections(files: Dictionary) -> Dictionary:
	var rejected: Dictionary = {}
	assert(DirAccess.make_dir_recursive_absolute(_output.path_join("rejections")) == OK)
	var state: Dictionary = _state(_new_snapshot(4, "packed", "running"), 4, "packed")
	for name: String in ["unsupported_version", "bad_tick", "packed_truncation", "unknown_backend"]:
		var bad: Dictionary = state.duplicate(true)
		var logistics: Dictionary = bad["logistics"]
		match name:
			"unsupported_version":
				bad["version"] = 5
			"bad_tick":
				logistics["tick"] += 1
			"packed_truncation":
				var machines: PackedByteArray = logistics["machines"]
				machines.resize(machines.size() - 1)
				logistics["machines"] = machines
			"unknown_backend":
				logistics["backend"] = "unknown"
		rejected[name] = SessionSnapshot.decode(bad) == null
		assert(rejected[name])
		_save_rejection(name, bad, files)
	var with_structure: Dictionary = _state(_new_snapshot(2, "dictionary", "running"), 1, "dictionary")
	# Version one also rejects structure bytes if metadata is omitted.
	rejected["v1_structure"] = SessionSnapshot.decode(with_structure) == null
	assert(rejected["v1_structure"])
	_save_rejection("v1_structure", with_structure, files)
	var with_slope: Dictionary = _state(_new_snapshot(3, "dictionary", "running"), 2, "dictionary")
	rejected["v2_slope"] = SessionSnapshot.decode(with_slope) == null
	assert(rejected["v2_slope"])
	_save_rejection("v2_slope", with_slope, files)
	var path: String = _output.path_join("v4_packed_running/a/session.bin")
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	for name: String in ["corrupt_sha", "corrupt_magic"]:
		var bad: PackedByteArray = bytes.duplicate()
		bad[8 if name == "corrupt_sha" else 0] ^= 1
		var destination: String = _output.path_join("rejections/" + name + ".bin")
		var file: FileAccess = FileAccess.open(destination, FileAccess.WRITE)
		assert(file != null)
		file.store_buffer(bad)
		file.close()
		rejected[name] = SaveGameFiles.new().read_blob(destination, SaveGameFiles.SESSION_LIMIT).is_empty()
		assert(rejected[name])
		files[name] = {
			"file": "rejections/" + name + ".bin", "kind": "blob",
			"bytes": bad.size(), "sha256": SaveGameFiles.digest(bad).hex_encode(),
		}
	return rejected


func _save_rejection(name: String, state: Dictionary, files: Dictionary) -> void:
	var filename: String = "rejections/" + name + ".bin"
	assert(SaveGameFiles.new().write_blob(_output.path_join(filename), var_to_bytes(state)))
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(_output.path_join(filename))
	files[name] = {
		"file": filename, "kind": "semantic",
		"bytes": bytes.size(), "sha256": SaveGameFiles.digest(bytes).hex_encode(),
	}


func _verify() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_output.path_join("manifest.json")))
	assert(parsed is Dictionary)
	var manifest: Dictionary = parsed
	assert(_variant_probes() == manifest["variant_probes"])
	var fixtures: Array = manifest["fixtures"]
	for row: Dictionary in fixtures:
		print("LEGACY_VERIFY_START ", row["name"])
		var store: SaveGameStore = SaveGameStore.new()
		store.directory = _output.path_join(row["name"])
		_assert_files(_files(store.directory), row["files"])
		_validate_layout(store.load_game(), row)
		var snapshot: SessionSnapshot = store.load_snapshot()
		assert(snapshot != null, store.last_error)
		var expected: Array = row["continuation_sha256"]
		var base_state: Dictionary = _static_state(snapshot)
		assert(expected.size() == 121)
		for tick: int in range(expected.size()):
			assert(_observable_hash(snapshot, base_state) == expected[tick], "%s tick %d" % [row["name"], tick])
			if tick < 120:
				_step(snapshot)
		assert(_static_state(snapshot) == base_state)
		print("LEGACY_VERIFY_END ", row["name"])
	var rejections: Dictionary = manifest["rejection_files"]
	for name: String in rejections:
		var record: Dictionary = rejections[name]
		var path: String = _output.path_join(record["file"])
		var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
		assert(bytes.size() == record["bytes"] and SaveGameFiles.digest(bytes).hex_encode() == record["sha256"])
		var raw: PackedByteArray = SaveGameFiles.new().read_blob(path, SaveGameFiles.SESSION_LIMIT)
		if record["kind"] == "blob":
			assert(raw.is_empty())
		else:
			var bad: Variant = bytes_to_var(raw)
			assert(bad is Dictionary and SessionSnapshot.decode(bad) == null)
	print("LEGACY_ORACLE_VERIFY_PASS")
	quit(0)


func _assert_files(actual: Dictionary, expected: Dictionary) -> void:
	assert(actual.size() == expected.size())
	for name: String in actual:
		assert(expected.has(name), name)
		var observed: Dictionary = actual[name]
		var recorded: Dictionary = expected[name]
		assert(observed.size() == recorded.size(), name)
		for field: String in observed:
			assert(recorded.has(field), name + " " + field)
			# JSON parses numbers as floats; nested Dictionary equality also
			# compares their Variant types, even when the numeric value matches.
			if field == "bytes":
				assert(observed[field] == int(recorded[field]), name)
			else:
				assert(observed[field] == recorded[field], name + " " + field)
