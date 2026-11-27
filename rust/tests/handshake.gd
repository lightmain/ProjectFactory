extends SceneTree
## Explicit extension contract. No fallback to the legacy rules.


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	if not ClassDB.class_exists(&"FactoryBackend"):
		printerr("FACTORY_BACKEND_MISSING_LIBRARY")
		quit(3)
		return
	var first: RefCounted = ClassDB.instantiate(&"FactoryBackend") as RefCounted
	var second: RefCounted = ClassDB.instantiate(&"FactoryBackend") as RefCounted
	var old_transport: RefCounted
	assert(first != null and second != null)
	if "--coexist" in OS.get_cmdline_user_args():
		assert(ClassDB.class_exists(&"RustConveyorNetwork"))
		old_transport = ClassDB.instantiate(&"RustConveyorNetwork") as RefCounted
		assert(old_transport != null)
		assert(_dictionary(old_transport.call("configure", 0.5, 1.0 / 60.0, 0.25)).get("ok") == true)
		assert(_dictionary(old_transport.call("capabilities")).get("inputs") == 3)
	for options: Dictionary in [
		{}, {"api_version": 0}, {"api_version": 2}, {"api_version": -1},
		{"api_version": 4294967296}, {"api_version": 1.0},
		{"api_version": true}, {"api_version": "1"}, {"api_version": 1, "unknown": 7},
	]:
		var rejected: Dictionary = _dictionary(first.call("open_backend", options))
		assert(rejected.get("ok") == false)
		assert(rejected.get("is_open") == false)
		var protocol_mismatch: bool = options.get("api_version") is int and (
			options.get("api_version") == 0 or options.get("api_version") == 2
		)
		assert(rejected.get("error") == ("unsupported_protocol" if protocol_mismatch else "invalid_argument"))
	var opened: Dictionary = _dictionary(first.call("open_backend", {"api_version": 1}))
	assert(opened.get("ok") == true and opened.get("is_open") == true)
	var capabilities: Dictionary = _dictionary(opened.get("capabilities"))
	assert(capabilities.get("api_version") == 1)
	assert(capabilities.get("features") == PackedStringArray(["handshake", "synchronous_factory", "checkpoint_jobs"]))
	assert(capabilities.get("rulesets") == PackedStringArray(["legacy_discrete_v1", "conveyor_continuous_v1"]))
	assert(capabilities.get("background") == false and capabilities.get("persistence") == true)
	var build: Dictionary = _dictionary(opened.get("build"))
	assert(build.get("package_version") == "0.1.0")
	assert(str(build.get("inputs_sha256", "")).length() == 64)
	assert(str(build.get("target", "")) == "aarch64-apple-darwin")
	var duplicate: Dictionary = _dictionary(first.call("open_backend", {"api_version": 1}))
	assert(duplicate.get("ok") == false and duplicate.get("error") == "already_open")
	assert(duplicate.get("is_open") == true)
	assert(_dictionary(second.call("open_backend", {"api_version": 1})).get("ok") == true)
	for index: int in range(2):
		var closed: Dictionary = _dictionary(first.call("close_backend"))
		assert(closed.get("ok") == true and closed.get("is_open") == false)
	assert(_dictionary(second.call("open_backend", {"api_version": 1})).get("error") == "already_open")
	assert(_dictionary(first.call("open_backend", {"api_version": 1})).get("ok") == true)
	first.call("close_backend")
	second.call("close_backend")
	if old_transport != null:
		assert(_dictionary(old_transport.call("stats")).get("items") == 0)
	print("FACTORY_BACKEND_HANDSHAKE_PASS")
	quit(0)


func _dictionary(value: Variant) -> Dictionary:
	assert(value is Dictionary)
	return value as Dictionary
