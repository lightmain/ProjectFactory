class_name SaveGameStore
extends RefCounted
## Named snapshots use an atomic catalog; each payload reuses the verified bank writer.

const SESSION_LIMIT: int = SaveGameFiles.SESSION_LIMIT
const HEADER_SIZE: int = SaveGameFiles.HEADER_SIZE
const MAGIC: int = SaveGameFiles.MAGIC

var directory: String = "user://saves/world"
var last_error: String = ""
var snapshot_decodes: int = 0
var loaded_state_sha256: String = ""
## Optional benchmark observer; receives only stage names and boundaries.
var phase_observer: Callable = Callable()
var _files: SaveGameFiles = SaveGameFiles.new()


func list_saves() -> Array[Dictionary]:
	var catalog: Dictionary = _read_catalog()
	var result: Array[Dictionary] = []
	if catalog.is_empty():
		return result
	var records: Array = catalog["saves"]
	for record: Dictionary in records:
		result.append(record.duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["sequence"] > b["sequence"])
	# Preserve the previous single-slot file without silently migrating or overwriting it.
	if has_save() and not catalog.get("legacy_hidden", false):
		result.append({
			"id": "legacy", "name": "旧世界存档", "world_name": "旧世界",
			"world_id": directory.sha256_text().substr(0, 32),
			"kind": "manual", "saved_at": float(FileAccess.get_modified_time(directory.path_join("current"))), "sequence": 0,
		})
	return result


func latest_id() -> String:
	var saves: Array[Dictionary] = list_saves()
	if saves.is_empty():
		return ""
	var save_id: String = saves[0]["id"]
	return save_id


func save_named(state: Dictionary, save_name: String, overwrite: bool = false,
		kind: String = "manual", retention: int = 3) -> bool:
	last_error = ""
	save_name = save_name.strip_edges()
	if not SaveGameFiles.valid_name(save_name) or kind not in ["manual", "auto", "exit"]:
		return _fail("存档名称不能为空，且最多 160 字。")
	if not SaveGameFiles.valid_id(state.get("world_id")) or not SaveGameFiles.valid_name(state.get("world_name")):
		return _fail("世界身份无效。")
	if kind == "auto" and retention < 1:
		return _fail("自动存档保留数量必须大于零。")
	var catalog: Dictionary = _read_catalog()
	if catalog.is_empty():
		return false
	if save_name == "旧世界存档" and has_save() and not catalog.get("legacy_hidden", false):
		if not overwrite:
			return _fail("与现有存档名称重复，是否覆盖")
		# Commit visibility with the new snapshot, retaining the legacy bank as a backup.
		catalog["legacy_hidden"] = true
	var records: Array = catalog["saves"]
	var replaced: Dictionary = {}
	for record: Dictionary in records:
		if record["name"] == save_name:
			if not overwrite:
				return _fail("与现有存档名称重复，是否覆盖")
			replaced = record
			break
	var payload: String = new_id()
	var writer: SaveGameStore = SaveGameStore.new()
	writer.phase_observer = phase_observer
	writer.directory = directory.path_join("snapshots").path_join(payload)
	var written: bool = writer.save_game(state)
	snapshot_decodes += writer.snapshot_decodes
	if not written:
		_remove_directory(writer.directory)
		return _fail(writer.last_error)
	var obsolete: Array[String] = []
	if not replaced.is_empty():
		records.erase(replaced)
		obsolete.append(replaced["payload"])
	var sequence: int = catalog["sequence"] + 1
	catalog["sequence"] = sequence
	var record: Dictionary = {
		"id": payload if replaced.is_empty() else replaced["id"],
		"payload": payload, "name": save_name, "world_id": state["world_id"],
		"world_name": state["world_name"], "kind": kind,
		"saved_at": Time.get_unix_time_from_system(), "sequence": sequence,
	}
	records.append(record)
	SaveGameFiles.rebuild_automatic(catalog)
	if kind == "auto":
		var automatic: Dictionary = catalog["automatic"]
		var ids: Array = automatic[state["world_id"]]
		while ids.size() > retention:
			var oldest: String = ids.pop_front()
			for candidate: Dictionary in records:
				if candidate["id"] == oldest:
					obsolete.append(candidate["payload"])
					records.erase(candidate)
					break
		SaveGameFiles.rebuild_automatic(catalog)
	if not _commit_catalog(catalog):
		_remove_directory(writer.directory)
		return false
	for old_payload: String in obsolete:
		_remove_directory(directory.path_join("snapshots").path_join(old_payload))
	return true


func load_named(save_id: String) -> Dictionary:
	var result: Dictionary = _load_named_result(save_id)
	return result.get("state", {})


func load_named_snapshot(save_id: String, fingerprint: bool = false) -> SessionSnapshot:
	var result: Dictionary = _load_named_result(save_id, fingerprint)
	return result.get("snapshot")


func _load_named_result(save_id: String, fingerprint: bool = false) -> Dictionary:
	last_error = ""
	loaded_state_sha256 = ""
	if save_id == "legacy":
		var legacy: Dictionary = _load_game_result(fingerprint)
		if not legacy.is_empty():
			var state: Dictionary = legacy["state"]
			var snapshot: SessionSnapshot = legacy["snapshot"]
			snapshot.world_id = directory.sha256_text().substr(0, 32)
			snapshot.world_name = "旧世界"
			state["world_id"] = snapshot.world_id
			state["world_name"] = snapshot.world_name
			loaded_state_sha256 = legacy["state_sha256"]
		return legacy
	var catalog: Dictionary = _read_catalog()
	if catalog.is_empty():
		return {}
	var records: Array = catalog["saves"]
	for record: Dictionary in records:
		if record["id"] != save_id:
			continue
		var reader: SaveGameStore = SaveGameStore.new()
		reader.phase_observer = phase_observer
		var payload: String = record["payload"]
		reader.directory = directory.path_join("snapshots").path_join(payload)
		var result: Dictionary = reader._load_game_result(fingerprint)
		snapshot_decodes += reader.snapshot_decodes
		if result.is_empty():
			_fail(reader.last_error)
			return {}
		var state: Dictionary = result["state"]
		if state.get("world_id") != record["world_id"] or state.get("world_name") != record["world_name"]:
			_fail("存档与索引中的世界身份不一致。")
			return {}
		loaded_state_sha256 = result["state_sha256"]
		return result
	_fail("未找到该存档。")
	return {}


func delete_save(save_id: String) -> bool:
	last_error = ""
	if save_id == "legacy":
		if not has_save() or DirAccess.remove_absolute(directory.path_join("current")) != OK:
			return _fail("无法删除旧存档。")
		return true
	var catalog: Dictionary = _read_catalog()
	if catalog.is_empty():
		return false
	var records: Array = catalog["saves"]
	for record: Dictionary in records:
		if record["id"] != save_id:
			continue
		records.erase(record)
		SaveGameFiles.rebuild_automatic(catalog)
		if not _commit_catalog(catalog):
			return false
		var payload: String = record["payload"]
		_remove_directory(directory.path_join("snapshots").path_join(payload))
		return true
	return _fail("未找到该存档。")


func _read_catalog() -> Dictionary:
	last_error = ""
	var catalog: Dictionary = _files.read_catalog(directory)
	if catalog.is_empty():
		_fail(_files.last_error)
	return catalog


func _commit_catalog(catalog: Dictionary) -> bool:
	if not SaveGameFiles.make_directory(directory) or not _write_blob(directory.path_join("index.tmp"), var_to_bytes(catalog)):
		return _fail("无法写入存档索引，旧存档已保留。")
	if DirAccess.rename_absolute(directory.path_join("index.tmp"), directory.path_join("index.bin")) != OK:
		return _fail("无法提交存档索引，旧存档已保留。")
	return true


static func new_id() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()


static func _remove_directory(path: String) -> void:
	SaveGameFiles.remove_directory(path)


func has_save() -> bool:
	return FileAccess.file_exists(directory.path_join("current"))


func save_game(state: Dictionary) -> bool:
	last_error = ""
	if _decode_snapshot(state) == null:
		return _fail("Invalid game state.")
	if not SaveGameFiles.make_directory(directory):
		return _fail("Cannot create save directory.")
	var active: String = _active_bank()
	if has_save() and active.is_empty():
		return _fail("Invalid save pointer.")
	var bank: String = "b" if active == "a" else "a"
	var path: String = directory.path_join(bank)
	if not SaveGameFiles.make_directory(path):
		return _fail("Cannot create save generation.")
	var folder: DirAccess = DirAccess.open(path)
	if folder == null:
		return _fail("Cannot open save generation.")
	for filename: String in folder.get_files():
		if folder.remove(filename) != OK:
			return _fail("Cannot replace save generation.")
	var manifest: Dictionary = state.duplicate()
	var chunks: Dictionary = manifest["chunks"]
	var keys: Array[Vector3i] = []
	for chunk: Vector3i in chunks:
		keys.append(chunk)
		var records: PackedByteArray = chunks[chunk]
		if not _write_blob(path.path_join(_chunk_name(chunk)), records):
			return false
	manifest["chunks"] = keys
	_phase("manifest_encode", true)
	var encoded: PackedByteArray = var_to_bytes(manifest)
	_phase("manifest_encode", false)
	if not _write_blob(path.path_join("session.bin"), encoded):
		return false
	encoded = PackedByteArray()
	if _read_bank_result(bank).is_empty():
		return _fail("Save verification failed: " + last_error)
	var temporary: String = directory.path_join("current.tmp")
	var pointer: FileAccess = FileAccess.open(temporary, FileAccess.WRITE)
	if pointer == null:
		return _fail("Cannot write save pointer.")
	pointer.store_string(bank)
	pointer.flush()
	var error: Error = pointer.get_error()
	pointer.close()
	if error != OK or DirAccess.rename_absolute(temporary, directory.path_join("current")) != OK:
		return _fail("Cannot commit save pointer.")
	return true


func load_game() -> Dictionary:
	var result: Dictionary = _load_game_result()
	return result.get("state", {})


func load_snapshot(fingerprint: bool = false) -> SessionSnapshot:
	var result: Dictionary = _load_game_result(fingerprint)
	return result.get("snapshot")


func _load_game_result(fingerprint: bool = false) -> Dictionary:
	last_error = ""
	loaded_state_sha256 = ""
	var bank: String = _active_bank()
	if bank.is_empty():
		_fail("No valid save is available.")
		return {}
	var result: Dictionary = _read_bank_result(bank, fingerprint)
	loaded_state_sha256 = result.get("state_sha256", "")
	return result


func _active_bank() -> String:
	var pointer: FileAccess = FileAccess.open(directory.path_join("current"), FileAccess.READ)
	if pointer == null or pointer.get_length() != 1:
		return ""
	var bank: String = pointer.get_as_text()
	return bank if bank in ["a", "b"] else ""


func _read_bank_result(bank: String, fingerprint: bool = false) -> Dictionary:
	var path: String = directory.path_join(bank)
	var bytes: PackedByteArray = _read_blob(path.path_join("session.bin"), SESSION_LIMIT)
	if bytes.is_empty():
		return {}
	_phase("manifest_decode", true)
	var value: Variant = bytes_to_var(bytes)
	_phase("manifest_decode", false)
	# The manifest is now owned by its Variant containers. Do not keep a
	# second encoded payload alive while rebuilding the complete factory.
	bytes = PackedByteArray()
	if not value is Dictionary:
		_fail("Invalid save manifest.")
		return {}
	var state: Dictionary = value
	if not state.get("chunks") is Array:
		_fail("Invalid chunk manifest.")
		return {}
	var keys: Array = state["chunks"]
	if keys.size() > VoxelWorldData.MAX_CHUNKS:
		_fail("Too many chunks.")
		return {}
	var chunks: Dictionary[Vector3i, PackedByteArray] = {}
	for key: Variant in keys:
		if not key is Vector3i:
			_fail("Invalid chunk coordinate.")
			return {}
		var chunk: Vector3i = key
		if chunk.x < 0 or chunk.x > 3 or chunk.y < 0 or chunk.y > 3 or chunk.z < 0 or chunk.z > 3 or chunks.has(chunk):
			_fail("Invalid or duplicate chunk.")
			return {}
		var records: PackedByteArray = _read_blob(path.path_join(_chunk_name(chunk)), VoxelWorldData.CHUNK_VOLUME * 3)
		if records.is_empty():
			return {}
		chunks[chunk] = records
	state["chunks"] = chunks
	# Benchmark fingerprints belong to the validated input. Calculate them
	# before allocating the decoded world rather than on top of its peak.
	var state_sha256: String = _state_fingerprint(state) if fingerprint else ""
	var snapshot: SessionSnapshot = _decode_snapshot(state)
	if snapshot == null:
		_fail("Unsupported or invalid save state.")
		return {}
	return {
		"state": state, "snapshot": snapshot,
		"state_sha256": state_sha256,
	}


func _decode_snapshot(state: Dictionary) -> SessionSnapshot:
	snapshot_decodes += 1
	_phase("snapshot_decode", true)
	var snapshot: SessionSnapshot = SessionSnapshot.decode(state, phase_observer)
	_phase("snapshot_decode", false)
	return snapshot


func _phase(name: String, entering: bool) -> void:
	if phase_observer.is_valid():
		phase_observer.call(name, entering)


static func _state_fingerprint(state: Dictionary) -> String:
	# GDScript expression temporaries can live until their function returns.
	# Keep the encoded payload in this scope so it is gone before decoding.
	return _digest(var_to_bytes(state)).hex_encode()


func _write_blob(path: String, bytes: PackedByteArray) -> bool:
	_files.phase_observer = phase_observer
	if not _files.write_blob(path, bytes):
		return _fail(_files.last_error)
	return true


func _read_blob(path: String, limit: int) -> PackedByteArray:
	_files.phase_observer = phase_observer
	var bytes: PackedByteArray = _files.read_blob(path, limit)
	if bytes.is_empty():
		_fail(_files.last_error)
	return bytes


static func _digest(bytes: PackedByteArray) -> PackedByteArray:
	return SaveGameFiles.digest(bytes)


static func _chunk_name(chunk: Vector3i) -> String:
	return "chunk_%d_%d_%d.bin" % [chunk.x, chunk.y, chunk.z]


func _fail(message: String) -> bool:
	last_error = message
	return false
