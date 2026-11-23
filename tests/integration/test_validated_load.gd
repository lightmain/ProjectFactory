extends GdUnitTestSuite

class ObservedStore extends SaveGameStore:
	var rebuild_memory_bytes: int = 0

	func _decode_snapshot(state: Dictionary) -> SessionSnapshot:
		rebuild_memory_bytes = int(Performance.get_monitor(Performance.MEMORY_STATIC))
		return super._decode_snapshot(state)


var _store: SaveGameStore


func before_test() -> void:
	_store = SaveGameStore.new()
	_store.directory = OS.get_cache_dir().path_join("factory_validated_load_%d" % Time.get_ticks_usec())


func after_test() -> void:
	get_tree().paused = false
	SaveGameStore._remove_directory(_store.directory)


func _available() -> bool:
	assert_bool(_store.has_method("load_snapshot")).is_true()
	assert_bool(_store.has_method("load_named_snapshot")).is_true()
	return _store.has_method("load_snapshot") and _store.has_method("load_named_snapshot")


func _state() -> Dictionary:
	return PressureSaveBuilder.state_for(PressureSaveBuilder.new().build(8, 6))


func _load_rebuild_memory(store: ObservedStore, fingerprint: bool) -> int:
	var snapshot: SessionSnapshot = store.load_snapshot(fingerprint)
	assert_bool(snapshot != null).is_true()
	# Only return a scalar, releasing this function's snapshot and temporaries
	# before the next load enters its rebuild phase.
	return store.rebuild_memory_bytes


func test_named_load_decodes_once_and_returns_independent_file_state() -> void:
	if not _available():
		return
	var state: Dictionary = _state()
	assert_bool(_store.save_named(state, "一次读取")).is_true()
	var save_id: String = _store.latest_id()
	var before: int = _store.get("snapshot_decodes")
	var snapshot: SessionSnapshot = _store.call("load_named_snapshot", save_id, true)
	assert_object(snapshot).is_not_null()
	assert_int(_store.get("snapshot_decodes") - before).is_equal(1)
	assert_str(_store.get("loaded_state_sha256")).is_equal(SaveGameStore._digest(var_to_bytes(state)).hex_encode())
	if snapshot == null:
		return
	assert_dict(snapshot.logistics.save_packed_state()).is_equal(state["logistics"])
	snapshot.logistics.advance(0.25)
	snapshot.world_name = "调用方修改"
	before = _store.get("snapshot_decodes")
	var second: SessionSnapshot = _store.call("load_named_snapshot", save_id)
	assert_int(_store.get("snapshot_decodes") - before).is_equal(1)
	assert_bool(is_same(snapshot, second)).is_false()
	assert_str(second.world_name).is_equal(state["world_name"])
	assert_dict(second.logistics.save_packed_state()).is_equal(state["logistics"])
	assert_dict(_store.load_named(save_id)).is_equal(state)


func test_single_slot_and_legacy_identity_match_compatible_dictionary() -> void:
	if not _available():
		return
	var state: Dictionary = _state()
	assert_bool(_store.save_game(state)).is_true()
	var snapshot: SessionSnapshot = _store.call("load_snapshot")
	assert_object(snapshot).is_not_null()
	assert_str(snapshot.world_id).is_equal(state["world_id"])
	var before: int = _store.get("snapshot_decodes")
	snapshot = _store.call("load_named_snapshot", "legacy")
	assert_int(_store.get("snapshot_decodes") - before).is_equal(1)
	var legacy: Dictionary = _store.load_named("legacy")
	assert_str(snapshot.world_id).is_equal(legacy["world_id"])
	assert_str(snapshot.world_name).is_equal(legacy["world_name"])
	assert_dict(snapshot.logistics.save_packed_state()).is_equal(legacy["logistics"])


func test_fingerprint_releases_encoded_payload_before_snapshot_rebuild() -> void:
	var store: ObservedStore = ObservedStore.new()
	store.directory = _store.directory
	var state: Dictionary = _state()
	# Unknown metadata is permitted by the existing format. Make its encoding
	# large enough to distinguish a live payload from ordinary test allocations.
	var payload: PackedByteArray = PackedByteArray()
	payload.resize(8 * 1024 * 1024)
	state["rebuild_memory_probe"] = payload
	assert_bool(store.save_game(state)).is_true()
	var plain_memory: int = _load_rebuild_memory(store, false)
	var fingerprint_memory: int = _load_rebuild_memory(store, true)
	assert_str(store.loaded_state_sha256).is_equal(SaveGameStore._digest(var_to_bytes(state)).hex_encode())
	assert_int(fingerprint_memory - plain_memory).is_less(payload.size() / 2)


func test_named_identity_mismatch_and_later_corruption_are_revalidated() -> void:
	if not _available():
		return
	assert_bool(_store.save_named(_state(), "身份")).is_true()
	var save_id: String = _store.latest_id()
	assert_object(_store.call("load_named_snapshot", save_id)).is_not_null()
	var catalog: Dictionary = _store._read_catalog()
	catalog["saves"][0]["world_name"] = "错误索引身份"
	assert_bool(_store._commit_catalog(catalog)).is_true()
	assert_object(_store.call("load_named_snapshot", save_id)).is_null()
	assert_str(_store.last_error).contains("身份不一致")
	assert_str(_store.get("loaded_state_sha256")).is_equal("")
	# Restore the exact persisted name rather than depending on builder labels.
	var reader: SaveGameStore = SaveGameStore.new()
	reader.directory = _store.directory.path_join("snapshots").path_join(catalog["saves"][0]["payload"])
	catalog["saves"][0]["world_name"] = reader.load_game()["world_name"]
	assert_bool(_store._commit_catalog(catalog)).is_true()
	assert_object(_store.call("load_named_snapshot", save_id)).is_not_null()
	var file: FileAccess = FileAccess.open(reader.directory.path_join("a/session.bin"), FileAccess.WRITE)
	file.store_buffer(PackedByteArray([1, 2, 3]))
	file.close()
	assert_object(_store.call("load_named_snapshot", save_id)).is_null()
	assert_bool(_store.last_error.is_empty()).is_false()
	assert_str(_store.get("loaded_state_sha256")).is_equal("")


func test_session_load_uses_one_decode_and_adopts_validated_rules() -> void:
	if not _available():
		return
	var session: FactorySession = auto_free(FactorySession.new())
	session.store = _store
	add_child(session)
	session.start_new("会话一次读取")
	session.pause_game()
	assert_bool(session.save_game("开始")).is_true()
	var expected: Dictionary = session.game.save_state()
	var before: int = _store.get("snapshot_decodes")
	assert_bool(session.load_game()).is_true()
	assert_int(_store.get("snapshot_decodes") - before).is_equal(1)
	assert_dict(session.game.save_state()).is_equal(expected)
	assert_object(session.game.initial_snapshot).is_null()
	session.pause_game()
	var original: FactoryGame = session.game
	assert_bool(session.load_game("不存在")).is_false()
	assert_bool(is_same(session.game, original)).is_true()
	assert_bool(get_tree().paused).is_true()


func test_valid_checksum_illegal_rules_never_reach_snapshot_consumer() -> void:
	if not _available():
		return
	var state: Dictionary = _state()
	assert_bool(_store.save_game(state)).is_true()
	var manifest: Dictionary = state.duplicate(true)
	manifest["chunks"] = state["chunks"].keys()
	manifest["logistics"]["tick"] = -1
	assert_bool(_store._write_blob(_store.directory.path_join("a/session.bin"), var_to_bytes(manifest))).is_true()
	assert_object(_store.call("load_snapshot")).is_null()
	assert_bool(_store.last_error.is_empty()).is_false()
	assert_str(_store.get("loaded_state_sha256")).is_equal("")
