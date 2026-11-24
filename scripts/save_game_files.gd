class_name SaveGameFiles
extends RefCounted
## Save files and catalog validation, independent of snapshot reconstruction.

const SESSION_LIMIT: int = 384 * 1024 * 1024
const HEADER_SIZE: int = 40
const MAGIC: int = 0x31534650

var last_error: String = ""
var phase_observer: Callable = Callable()


func read_catalog(directory: String) -> Dictionary:
	last_error = ""
	var path: String = directory.path_join("index.bin")
	if not FileAccess.file_exists(path):
		if DirAccess.dir_exists_absolute(path):
			_fail("存档索引路径不可读。")
			return {}
		return {"version": 1, "sequence": 0, "saves": [], "automatic": {}}
	var bytes: PackedByteArray = read_blob(path, SESSION_LIMIT)
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
		if not valid_id(record.get("id")) or not valid_id(record.get("payload")) or (
			not valid_id(record.get("world_id")) or not valid_name(record.get("name"))
			or not valid_name(record.get("world_name")) or record.get("kind") not in ["manual", "auto", "exit"]
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
	rebuild_automatic(catalog)
	return catalog


static func rebuild_automatic(catalog: Dictionary) -> void:
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


static func valid_id(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	return text.length() == 32 and text.to_lower() == text and text.is_valid_hex_number()


static func valid_name(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	return not text.strip_edges().is_empty() and text.length() <= 160 and not text.contains("\n") and not text.contains("\r")


func write_blob(path: String, bytes: PackedByteArray) -> bool:
	last_error = ""
	if bytes.size() > SESSION_LIMIT:
		return _fail("Save exceeds file size limit.")
	_phase("checksum", true)
	var checksum: PackedByteArray = digest(bytes)
	_phase("checksum", false)
	_phase("compress", true)
	var compressed: PackedByteArray = bytes.compress(FileAccess.COMPRESSION_DEFLATE)
	_phase("compress", false)
	_phase("disk_write", true)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_phase("disk_write", false)
		return _fail("Cannot write save file.")
	file.store_32(MAGIC)
	file.store_32(bytes.size())
	file.store_buffer(checksum)
	file.store_buffer(compressed)
	file.flush()
	var error: Error = file.get_error()
	file.close()
	_phase("disk_write", false)
	return true if error == OK else _fail("Save file write failed.")


func read_blob(path: String, limit: int) -> PackedByteArray:
	last_error = ""
	_phase("disk_read", true)
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() <= HEADER_SIZE or file.get_length() > limit + 1024:
		_phase("disk_read", false)
		_fail("Missing or oversized save file.")
		return PackedByteArray()
	if file.get_32() != MAGIC:
		_phase("disk_read", false)
		_fail("Unknown save file format.")
		return PackedByteArray()
	var length: int = file.get_32()
	var checksum: PackedByteArray = file.get_buffer(32)
	if length <= 0 or length > limit:
		_phase("disk_read", false)
		_fail("Invalid uncompressed length.")
		return PackedByteArray()
	var compressed: PackedByteArray = file.get_buffer(file.get_length() - HEADER_SIZE)
	_phase("disk_read", false)
	_phase("decompress", true)
	var bytes: PackedByteArray = compressed.decompress(length, FileAccess.COMPRESSION_DEFLATE)
	_phase("decompress", false)
	_phase("checksum", true)
	var valid: bool = bytes.size() == length and digest(bytes) == checksum
	_phase("checksum", false)
	if not valid:
		_fail("Save checksum failed.")
		return PackedByteArray()
	return bytes


func _phase(name: String, entering: bool) -> void:
	if phase_observer.is_valid():
		phase_observer.call(name, entering)


static func digest(bytes: PackedByteArray) -> PackedByteArray:
	var hash: HashingContext = HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return hash.finish()


static func remove_directory(path: String) -> void:
	var folder: DirAccess = DirAccess.open(path)
	if folder == null:
		return
	for child: String in folder.get_directories():
		remove_directory(path.path_join(child))
	for filename: String in folder.get_files():
		folder.remove(filename)
	DirAccess.remove_absolute(path)


static func make_directory(path: String) -> bool:
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


func _fail(message: String) -> bool:
	last_error = message
	return false
