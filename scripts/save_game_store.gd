class_name SaveGameStore
extends RefCounted
## Named snapshots use an atomic catalog; each payload reuses the verified bank writer.

const SESSION_LIMIT: int = 16 * 1024 * 1024
const HEADER_SIZE: int = 40
const MAGIC: int = 0x31534650

var directory: String = "user://saves/world"
var last_error: String = ""


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
	if not _valid_name(save_name) or kind not in ["manual", "auto", "exit"]:
		return _fail("存档名称不能为空，且最多 160 字。")
	if not _valid_id(state.get("world_id")) or not _valid_name(state.get("world_name")):
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
	writer.directory = directory.path_join("snapshots").path_join(payload)
	if not writer.save_game(state):
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
	_rebuild_automatic(catalog)
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
		_rebuild_automatic(catalog)
	if not _commit_catalog(catalog):
		_remove_directory(writer.directory)
		return false
	for old_payload: String in obsolete:
		_remove_directory(directory.path_join("snapshots").path_join(old_payload))
	return true


func load_named(save_id: String) -> Dictionary:
	last_error = ""
	if save_id == "legacy":
		var legacy: Dictionary = load_game()
		if not legacy.is_empty():
			legacy["world_id"] = directory.sha256_text().substr(0, 32)
			legacy["world_name"] = "旧世界"
		return legacy
	var catalog: Dictionary = _read_catalog()
	if catalog.is_empty():
		return {}
	var records: Array = catalog["saves"]
	for record: Dictionary in records:
		if record["id"] != save_id:
			continue
		var reader: SaveGameStore = SaveGameStore.new()
		var payload: String = record["payload"]
		reader.directory = directory.path_join("snapshots").path_join(payload)
		var state: Dictionary = reader.load_game()
		if state.is_empty():
			_fail(reader.last_error)
		elif state.get("world_id") != record["world_id"] or state.get("world_name") != record["world_name"]:
			_fail("存档与索引中的世界身份不一致。")
			return {}
		return state
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
		_rebuild_automatic(catalog)
		if not _commit_catalog(catalog):
			return false
		var payload: String = record["payload"]
		_remove_directory(directory.path_join("snapshots").path_join(payload))
		return true
	return _fail("未找到该存档。")


func _read_catalog() -> Dictionary:
	last_error = ""
	var path: String = directory.path_join("index.bin")
	if not FileAccess.file_exists(path):
		if DirAccess.dir_exists_absolute(path):
			_fail("存档索引路径不可读。")
			return {}
		return {"version": 1, "sequence": 0, "saves": [], "automatic": {}}
	var bytes: PackedByteArray = _read_blob(path, SESSION_LIMIT)
	if bytes.is_empty():
		return {}
	var value: Variant = bytes_to_var(bytes)
	if not value is Dictionary:
		_fail("存档索引无效。")
		return {}
	var catalog: Dictionary = value
	if catalog.get("version") != 1 or not SnapshotValues.integer(catalog.get("sequence"), 0, 9223372036854775806) or (
		not catalog.get("saves") is Array or not catalog.get("automatic") is Dictionary
		or not catalog.get("legacy_hidden", false) is bool
	):
		_fail("存档索引无效。")
		return {}
	var ids: Dictionary[String, bool] = {}
	var names: Dictionary[String, bool] = {}
	var payloads: Dictionary[String, bool] = {}
	var maximum_sequence: int = catalog["sequence"]
	var previous_sequence: int = 0
	var records: Array = catalog["saves"]
	for item: Variant in records:
		if not item is Dictionary:
			_fail("存档条目无效。")
			return {}
		var record: Dictionary = item
		if not _valid_id(record.get("id")) or not _valid_id(record.get("payload")) or (
			not _valid_id(record.get("world_id")) or not _valid_name(record.get("name"))
			or not _valid_name(record.get("world_name")) or record.get("kind") not in ["manual", "auto", "exit"]
			or not SnapshotValues.integer(record.get("sequence"), 1, maximum_sequence)
			or not record.get("saved_at") is float
		):
			_fail("存档条目无效。")
			return {}
		var saved_at: float = record["saved_at"]
		if not is_finite(saved_at):
			_fail("存档时间无效。")
			return {}
		var sequence: int = record["sequence"]
		if ids.has(record["id"]) or names.has(record["name"]) or payloads.has(record["payload"]) or sequence <= previous_sequence:
			_fail("存档索引包含重复条目。")
			return {}
		ids[record["id"]] = true
		names[record["name"]] = true
		payloads[record["payload"]] = true
		previous_sequence = sequence
	_rebuild_automatic(catalog)
	return catalog


func _commit_catalog(catalog: Dictionary) -> bool:
	if not _make_directory(directory) or not _write_blob(directory.path_join("index.tmp"), var_to_bytes(catalog)):
		return _fail("无法写入存档索引，旧存档已保留。")
	if DirAccess.rename_absolute(directory.path_join("index.tmp"), directory.path_join("index.bin")) != OK:
		return _fail("无法提交存档索引，旧存档已保留。")
	return true


static func _rebuild_automatic(catalog: Dictionary) -> void:
	var automatic: Dictionary[String, Array] = {}
	var records: Array = catalog["saves"]
	for record: Dictionary in records:
		if record["kind"] != "auto":
			continue
		var world_id: String = record["world_id"]
		if not automatic.has(world_id):
			automatic[world_id] = []
		automatic[world_id].append(record["id"])
	catalog["automatic"] = automatic


static func new_id() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()


static func _valid_id(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	return text.length() == 32 and text.to_lower() == text and text.is_valid_hex_number()


static func _valid_name(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	return not text.strip_edges().is_empty() and text.length() <= 160 and not text.contains("\n") and not text.contains("\r")


static func _remove_directory(path: String) -> void:
	var folder: DirAccess = DirAccess.open(path)
	if folder == null:
		return
	for child: String in folder.get_directories():
		_remove_directory(path.path_join(child))
	for filename: String in folder.get_files():
		folder.remove(filename)
	DirAccess.remove_absolute(path)


func has_save() -> bool:
	return FileAccess.file_exists(directory.path_join("current"))


func save_game(state: Dictionary) -> bool:
	last_error = ""
	if SessionSnapshot.decode(state) == null:
		return _fail("Invalid game state.")
	if not _make_directory(directory):
		return _fail("Cannot create save directory.")
	var active: String = _active_bank()
	if has_save() and active.is_empty():
		return _fail("Invalid save pointer.")
	var bank: String = "b" if active == "a" else "a"
	var path: String = directory.path_join(bank)
	if not _make_directory(path):
		return _fail("Cannot create save generation.")
	var folder: DirAccess = DirAccess.open(path)
	if folder == null:
		return _fail("Cannot open save generation.")
	for filename: String in folder.get_files():
		if folder.remove(filename) != OK:
			return _fail("Cannot replace save generation.")
	var manifest: Dictionary = state.duplicate(true)
	var chunks: Dictionary = manifest["chunks"]
	var keys: Array[Vector3i] = []
	for chunk: Vector3i in chunks:
		keys.append(chunk)
		var records: PackedByteArray = chunks[chunk]
		if not _write_blob(path.path_join(_chunk_name(chunk)), records):
			return false
	manifest["chunks"] = keys
	if not _write_blob(path.path_join("session.bin"), var_to_bytes(manifest)):
		return false
	if _read_bank(bank).is_empty():
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
	last_error = ""
	var bank: String = _active_bank()
	if bank.is_empty():
		_fail("No valid save is available.")
		return {}
	return _read_bank(bank)


func _active_bank() -> String:
	var pointer: FileAccess = FileAccess.open(directory.path_join("current"), FileAccess.READ)
	if pointer == null or pointer.get_length() != 1:
		return ""
	var bank: String = pointer.get_as_text()
	return bank if bank in ["a", "b"] else ""


func _read_bank(bank: String) -> Dictionary:
	var path: String = directory.path_join(bank)
	var bytes: PackedByteArray = _read_blob(path.path_join("session.bin"), SESSION_LIMIT)
	if bytes.is_empty():
		return {}
	var value: Variant = bytes_to_var(bytes)
	if not value is Dictionary:
		_fail("Invalid save manifest.")
		return {}
	var state: Dictionary = value
	if not state.get("chunks") is Array:
		_fail("Invalid chunk manifest.")
		return {}
	var keys: Array = state["chunks"]
	if keys.size() > 8:
		_fail("Too many chunks.")
		return {}
	var chunks: Dictionary[Vector3i, PackedByteArray] = {}
	for key: Variant in keys:
		if not key is Vector3i:
			_fail("Invalid chunk coordinate.")
			return {}
		var chunk: Vector3i = key
		if chunk.x not in [0, 1] or chunk.y not in [0, 1] or chunk.z not in [0, 1] or chunks.has(chunk):
			_fail("Invalid or duplicate chunk.")
			return {}
		var records: PackedByteArray = _read_blob(path.path_join(_chunk_name(chunk)), VoxelWorldData.CHUNK_VOLUME * 3)
		if records.is_empty():
			return {}
		chunks[chunk] = records
	state["chunks"] = chunks
	if SessionSnapshot.decode(state) == null:
		_fail("Unsupported or invalid save state.")
		return {}
	return state


func _write_blob(path: String, bytes: PackedByteArray) -> bool:
	if bytes.size() > SESSION_LIMIT:
		return _fail("Save exceeds file size limit.")
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _fail("Cannot write save file.")
	file.store_32(MAGIC)
	file.store_32(bytes.size())
	file.store_buffer(_digest(bytes))
	file.store_buffer(bytes.compress(FileAccess.COMPRESSION_DEFLATE))
	file.flush()
	var error: Error = file.get_error()
	file.close()
	return true if error == OK else _fail("Save file write failed.")


func _read_blob(path: String, limit: int) -> PackedByteArray:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() <= HEADER_SIZE or file.get_length() > limit + 1024:
		_fail("Missing or oversized save file.")
		return PackedByteArray()
	if file.get_32() != MAGIC:
		_fail("Unknown save file format.")
		return PackedByteArray()
	var length: int = file.get_32()
	var checksum: PackedByteArray = file.get_buffer(32)
	if length <= 0 or length > limit:
		_fail("Invalid uncompressed length.")
		return PackedByteArray()
	var compressed: PackedByteArray = file.get_buffer(file.get_length() - HEADER_SIZE)
	var bytes: PackedByteArray = compressed.decompress(length, FileAccess.COMPRESSION_DEFLATE)
	if bytes.size() != length or _digest(bytes) != checksum:
		_fail("Save checksum failed.")
		return PackedByteArray()
	return bytes


static func _digest(bytes: PackedByteArray) -> PackedByteArray:
	var hash: HashingContext = HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return hash.finish()


static func _chunk_name(chunk: Vector3i) -> String:
	return "chunk_%d_%d_%d.bin" % [chunk.x, chunk.y, chunk.z]


func _fail(message: String) -> bool:
	last_error = message
	return false


static func _make_directory(path: String) -> bool:
	# A file occupying an ancestor is an ordinary save failure, not an engine error.
	var ancestor: String = ProjectSettings.globalize_path(path)
	while not DirAccess.dir_exists_absolute(ancestor):
		if FileAccess.file_exists(ancestor):
			return false
		var parent: String = ancestor.get_base_dir()
		if parent == ancestor:
			return false
		ancestor = parent
	return DirAccess.make_dir_recursive_absolute(path) == OK
