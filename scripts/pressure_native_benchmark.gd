extends SceneTree
## -- SIZE HEIGHT OUTPUT [SAMPLES WARMUP BACKEND PROVENANCE CAMERA_TRACK]
## Uses the original pressure generator and the complete mounted FactoryGame.
## Each measured frame advances one fixed tick and submits the real nearby view.

var _game: FactoryGame
var _output: String
var _samples: int = 300
var _warmup: int = 120
var _sampled: int = 0
var _initial_ore: int = 0
var _sink: Vector3i
var _start_sink: int = 0
var _start_tick: int = 0
var _started: int = 0
var _previous_frame_usec: int = 0
var _pending_measured_interval: bool = false
var _drawn_frames: int = 0
var _window_start_drawn_frames: int = 0
var _inventory_cells: Array[Vector3i] = []
var _work_samples: Array[Dictionary] = []
var _report: Dictionary = {}
var _times: Dictionary[String, Array] = {}
var _camera_track: String = "fixed"
var _camera_start: Transform3D
var _camera_frames: int = 0
var _load_started_usec: int = 0
var _first_actionable: bool = false
var _switch_count: int = 0
var _alternate_save: String = ""


func _initialize() -> void:
	if DisplayServer.get_name() != "headless":
		root.mode = Window.MODE_WINDOWED
		root.show()
		DisplayServer.window_move_to_foreground()
		RenderingServer.frame_post_draw.connect(_on_frame_drawn)
	call_deferred("_mount")


func _on_frame_drawn() -> void:
	_drawn_frames += 1
	if _first_actionable and not _report.has("load_to_first_draw_seconds"):
		_report["load_to_first_draw_seconds"] = float(Time.get_ticks_usec() - _load_started_usec) / 1000000.0


func _mount() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 3:
		printerr("Usage: -- SIZE HEIGHT NEW_OUTPUT [SAMPLES WARMUP rust|gdscript PROVENANCE fixed|small_translation]")
		quit(2)
		return
	var size: int = int(args[0])
	var height: int = int(args[1])
	_output = args[2]
	_samples = int(args[3]) if args.size() > 3 else 300
	_warmup = int(args[4]) if args.size() > 4 else 120
	var backend: String = args[5] if args.size() > 5 else "rust"
	_report["provenance"] = args[6] if args.size() > 6 else "unavailable: direct script invocation"
	_camera_track = args[7] if args.size() > 7 else "fixed"
	_switch_count = int(args[9]) if args.size() > 9 else 0
	_alternate_save = args[10] if args.size() > 10 else ""
	if _samples < 1 or _samples > 100000 or _warmup < 0 or _warmup > 3600 or (
		backend not in ["rust", "gdscript"] or _camera_track not in ["fixed", "small_translation"]
		or DirAccess.dir_exists_absolute(_output)
		or _switch_count < 0 or _switch_count > 3
		or (_switch_count > 0 and not DirAccess.dir_exists_absolute(_alternate_save))
	):
		quit(2)
		return
	if DirAccess.make_dir_recursive_absolute(_output) != OK:
		quit(1)
		return
	var load_directory: String = args[8] if args.size() > 8 else ""
	_report["mode"] = "independent_load" if not load_directory.is_empty() else "generate_save_load"
	_report["cache_status"] = "OS cache uncontrolled; no forced eviction"
	_report["requested_switch_count"] = _switch_count
	_report["switches"] = []
	var snapshot: SessionSnapshot
	var route: Dictionary = {}
	var started: int
	var store: SaveGameStore = SaveGameStore.new()
	store.phase_observer = _phase
	store.directory = load_directory if not load_directory.is_empty() else _output.path_join("save")
	_report["save_directory"] = store.directory
	if load_directory.is_empty():
		var builder: PressureSaveBuilder = PressureSaveBuilder.new()
		_phase("build", true)
		started = Time.get_ticks_usec()
		snapshot = builder.build_complex(backend) if size == 0 else builder.build(size, height, backend)
		_report["build_seconds"] = float(Time.get_ticks_usec() - started) / 1000000.0
		_phase("build", false)
		if snapshot == null:
			printerr(builder.last_error)
			quit(1)
			return
		_phase("save_operation", true)
		var save_started: int = Time.get_ticks_usec()
		_phase("checkpoint", true)
		started = Time.get_ticks_usec()
		var state: Dictionary = PressureSaveBuilder.state_for(snapshot)
		_report["checkpoint_seconds"] = float(Time.get_ticks_usec() - started) / 1000000.0
		_phase("checkpoint", false)
		_phase("save", true)
		started = Time.get_ticks_usec()
		var saved: bool = store.save_game(state)
		_report["disk_save_seconds"] = float(Time.get_ticks_usec() - started) / 1000000.0
		_phase("save", false)
		_report["save_operation_seconds"] = float(Time.get_ticks_usec() - save_started) / 1000000.0
		_phase("save_operation", false)
		if not saved:
			printerr("Pressure save failed: ", store.last_error)
			quit(1)
			return
		state.clear()
		_phase("route_audit", true)
		started = Time.get_ticks_usec()
		route = PressureSaveBuilder.complex_certificate(snapshot) if size == 0 else PressureSaveBuilder.route_certificate(snapshot)
		route["initial_ores"] = snapshot.logistics.total_ore()
		route["world_id"] = snapshot.world_id
		_report["route_validation_seconds"] = float(Time.get_ticks_usec() - started) / 1000000.0
		_phase("route_audit", false)
		var certificate: FileAccess = FileAccess.open(_output.path_join("route.bin"), FileAccess.WRITE)
		if certificate == null:
			quit(1)
			return
		certificate.store_buffer(var_to_bytes(route))
		certificate.close()
		snapshot = null
	else:
		# Read the small certificate BEFORE the player load clock. Full snapshot
		# exports/audits belong to the generating process, never isolated load RSS.
		var certificate: FileAccess = FileAccess.open(load_directory.get_base_dir().path_join("route.bin"), FileAccess.READ)
		if certificate == null or certificate.get_length() > 4096:
			printerr("Independent load requires the fixture's route.bin certificate.")
			quit(1)
			return
		var value: Variant = bytes_to_var(certificate.get_buffer(certificate.get_length()))
		if not value is Dictionary:
			quit(1)
			return
		route = value
	if route.is_empty() or not route.has("sink"):
		printerr("Pressure topology certificate failed.")
		quit(1)
		return
	_phase("load_operation", true)
	_phase("load", true)
	started = Time.get_ticks_usec()
	_load_started_usec = started
	snapshot = store.load_snapshot()
	_report["disk_load_decode_seconds"] = float(Time.get_ticks_usec() - started) / 1000000.0
	_phase("load", false)
	if snapshot == null or snapshot.logistics.transport_backend() != backend or snapshot.world_id != route["world_id"]:
		printerr("Pressure disk load failed: ", store.last_error)
		quit(1)
		return
	_report["route"] = route
	_sink = route["sink"]
	var producer_cells: Array[Vector3i] = route["producer_cells"]
	var inventory_cells: Array = route.get("inventory_cells", producer_cells + [_sink])
	_inventory_cells.assign(inventory_cells)
	_initial_ore = route["initial_ores"]
	_report["incoming_initial_entries"] = snapshot.logistics.work_stats().get("rust_incoming_entries", 0)
	print("NATIVE_PRESSURE_BUILT belts=", route["belts"], " ores=", _initial_ore,
		" seconds=", _report.get("build_seconds", "independent load"))
	_phase("mount", true)
	started = Time.get_ticks_usec()
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_game = scene.instantiate() as FactoryGame
	_game.initial_snapshot = snapshot
	root.add_child(_game)
	current_scene = _game
	isolate_game(_game)
	_camera_start = _game.player.camera.global_transform
	_report["camera_track"] = _camera_track
	_report["mount_seconds"] = float(Time.get_ticks_usec() - started) / 1000000.0
	_phase("mount", false)
	_report["backend"] = _game.logistics_data.transport_backend()
	_report["warmup_ticks"] = _warmup
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	for name: String in ["frame", "process_interval", "advance", "prepare", "binding", "settle", "core",
		"candidate", "decoration", "sample", "mapping", "submission", "display_query", "display_xyz"]:
		_times[name] = []
	_previous_frame_usec = Time.get_ticks_usec()
	process_frame.connect(_measure)


static func isolate_game(game: FactoryGame) -> void:
	# Pause only player controls, never the tree or the manual logistics tick.
	# Disabling processing alone leaves _input, _unhandled_input and GUI live.
	game.player.set_session_paused(true)
	game.set_process_input(false)
	game.player.set_process_unhandled_input(false)
	game.get_viewport().gui_disable_input = true
	game.set_physics_process(false)
	game.set_process(false)
	game.player.set_physics_process(false)
	game.player.set_process(false)
	game.logistics_view.set_process(false)
	game.free_camera.set_process(false)
	game.free_camera.set_physics_process(false)
	game.free_camera.set_input_enabled(false)


func _measure() -> void:
	var started: int = Time.get_ticks_usec()
	if _pending_measured_interval:
		# This interval belongs to the preceding measured tick. Observe the
		# boundary after the final tick before collecting any report metadata.
		_times["process_interval"].append(float(started - _previous_frame_usec) / 1000.0)
		_pending_measured_interval = false
		if _sampled == _samples:
			process_frame.disconnect(_measure)
			_finish(started)
			return
	_previous_frame_usec = started
	if not _first_actionable:
		_game.logistics_data.advance(LogisticsData.LOGIC_STEP)
		_game.logistics_view.refresh_from_data(0.0)
		if not _game.logistics_data.transport_error().is_empty() or not _game.logistics_view.display_error().is_empty():
			printerr("Initial tick/display failed.")
			quit(1)
			return
		_first_actionable = true
		_report["load_to_first_actionable_seconds"] = float(Time.get_ticks_usec() - _load_started_usec) / 1000000.0
		_phase("load_operation", false)
		# The first tick belongs to the requested preheat window. With zero
		# preheat it is an explicitly reported bootstrap, outside measured ticks.
		_report["bootstrap_ticks"] = 1 if _warmup == 0 else 0
		_warmup = maxi(0, _warmup - 1)
		_phase("warmup", true)
		return
	if _warmup == 0 and _sampled == 0:
		_phase("warmup", false)
		_phase("start_audit", true)
		var audit_started: int = Time.get_ticks_usec()
		_report["window_start"] = _population()
		_report["window_start_work"] = _game.logistics_data.work_stats()
		_report["start_audit_seconds"] = float(Time.get_ticks_usec() - audit_started) / 1000000.0
		_phase("start_audit", false)
		_phase("steady", true)
		started = Time.get_ticks_usec()
		_previous_frame_usec = started
		_started = started
		_start_tick = _game.logistics_data.logic_tick()
		_start_sink = _game.logistics_data.ore_count(_sink)
		_window_start_drawn_frames = _drawn_frames
	_game.logistics_data.advance(LogisticsData.LOGIC_STEP)
	if not _game.logistics_data.transport_error().is_empty():
		printerr(_game.logistics_data.transport_error())
		quit(1)
		return
	var advance_usec: int = Time.get_ticks_usec() - started
	_update_camera_track()
	_game.logistics_view.refresh_from_data(0.0)
	if not _game.logistics_view.display_error().is_empty():
		printerr("Pressure display failed: ", _game.logistics_view.display_error())
		quit(1)
		return
	var elapsed_usec: int = Time.get_ticks_usec() - started
	if _warmup > 0:
		_warmup -= 1
		return
	var stats: Dictionary[String, int] = _game.logistics_data.work_stats()
	var view: Dictionary[String, int] = _game.logistics_view.stage_stats()
	_times["frame"].append(float(elapsed_usec) / 1000.0)
	_times["advance"].append(float(advance_usec) / 1000.0)
	for name: String in ["prepare", "binding", "settle"]:
		var stage_usec: int = stats.get("rust_" + name + "_usec", 0)
		_times[name].append(float(stage_usec) / 1000.0)
	var core_nsec: int = stats.get("rust_core_ns", 0)
	_times["core"].append(float(core_nsec) / 1000000.0)
	for name: String in ["query", "xyz"]:
		var nanoseconds: int = stats.get("rust_display_" + name + "_ns", 0)
		_times["display_" + name].append(float(nanoseconds) / 1000000.0)
	for name: String in ["candidate", "decoration", "sample", "mapping", "submission"]:
		var stage_usec: int = view.get(name + "_usec", 0)
		_times[name].append(float(stage_usec) / 1000.0)
	_sampled += 1
	_pending_measured_interval = true
	_work_samples.append({"tick": _game.logistics_data.logic_tick(),
		"window_focused": root.has_focus(),
		"work": stats, "view": view, "camera_position": [
			_game.player.camera.global_position.x,
			_game.player.camera.global_position.y,
			_game.player.camera.global_position.z,
		]})


func _update_camera_track() -> void:
	if _camera_track == "fixed":
		return
	_camera_frames += 1
	# Continuous small horizontal motion and turning, within the anchor budget.
	# Tick advances and user input isolation remain identical to the fixed run.
	var phase: float = float(_camera_frames) * 0.02
	var position: Vector3 = _camera_start.origin + Vector3(0.2 * sin(phase), 0, 0.2 * (cos(phase) - 1.0))
	_game.player.camera.global_transform = Transform3D(
		Basis(Vector3.UP, 0.05 * sin(phase)) * _camera_start.basis, position
	)


func _population() -> Dictionary:
	var total: int = _game.logistics_data.total_ore()
	var inventory: int = 0
	for cell: Vector3i in _inventory_cells:
		inventory += _game.logistics_data.ore_count(cell)
	return {"total": total, "inventory": inventory, "on_belt": total - inventory,
		"sink": _game.logistics_data.ore_count(_sink)}


func _finish(ended: int) -> void:
	_phase("steady", false)
	_report["wall_seconds"] = float(ended - _started) / 1000000.0
	_report["drawn_frames_during_window"] = _drawn_frames - _window_start_drawn_frames
	if DisplayServer.get_name() != "headless" and _report["drawn_frames_during_window"] < 1:
		printerr("Graphical measurement window did not draw any frame.")
		quit(1)
		return
	_phase("end_audit", true)
	var audit_started: int = Time.get_ticks_usec()
	var stats: Dictionary[String, int] = _game.logistics_data.work_stats()
	var view: Dictionary[String, int] = _game.logistics_view.stage_stats()
	_report["window_end"] = _population()
	var population_start: Dictionary = _report["window_start"]
	var population_end: Dictionary = _report["window_end"]
	_report["generated_inventory_during_window"] = population_end["total"] - population_start["total"]
	var work_start: Dictionary = _report["window_start_work"]
	var transactions: Dictionary = {}
	for counter: String in ["rust_produced", "rust_consumed", "rust_transferred"]:
		transactions[counter] = stats[counter] - work_start[counter] if stats.has(counter) else "unavailable"
	_report["native_transactions_during_window"] = transactions
	_report["engine"] = Engine.get_version_info()["string"]
	_report["renderer"] = RenderingServer.get_current_rendering_method()
	_report["display"] = DisplayServer.get_name()
	_report["cpu"] = OS.get_processor_name()
	_report["initial_ores"] = _initial_ore
	_report["final_ores"] = population_end["total"]
	_report["logic_ticks"] = _game.logistics_data.logic_tick() - _start_tick
	if _report["logic_ticks"] != _samples:
		printerr("Measured tick window does not match sample count.")
		quit(1)
		return
	_report["consumed_during_window"] = _game.logistics_data.ore_count(_sink) - _start_sink
	_report["stages_ms"] = _summaries()
	_report["last_work"] = stats
	var display_bind_usec: int = stats.get("rust_display_bind_usec", 0)
	_report["display_geometry_bind_seconds"] = float(display_bind_usec) / 1000000.0
	_report["last_view"] = view
	_report["static_memory_peak_bytes"] = Performance.get_monitor(Performance.MEMORY_STATIC_MAX)
	_report["end_audit_seconds"] = float(Time.get_ticks_usec() - audit_started) / 1000000.0
	_phase("end_audit", false)
	if DisplayServer.get_name() != "headless" and not _capture():
		quit(1)
		return
	if _switch_count > 0:
		if not await _measure_switches():
			quit(1)
			return
	_report["limits"] = ["Explicit fixed ticks; wall time includes frame scheduling.",
		"frame measures advance + view refresh CPU; process_interval includes intervening engine work and scheduling.",
		"Binding includes native core duration; core is a nested measurement.",
		"Mounted from a validated disk save created by the existing full pressure generator.",
		"Headless runs submit the scene view without GPU rasterization.",
		"Native sampling currently shows committed fixed-tick positions.",
		"Each process_interval is associated with its preceding measured tick; the last interval ends at the next callback.",
		"wall_seconds excludes population audits and report writing; includes per-tick measurement bookkeeping.",
		"Native transfers count logical-segment crossings, not voxel-cell crossings; backend work counters have different semantics.",
		"Per-item moving distance is unavailable; on-belt population, native tree visits, transactions and view counters are recorded."]
	var file: FileAccess = FileAccess.open(_output.path_join("samples.json"), FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(JSON.stringify(_times))
	file.close()
	file = FileAccess.open(_output.path_join("work_samples.json"), FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(JSON.stringify(_work_samples))
	file.close()
	file = FileAccess.open(_output.path_join("performance.json"), FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(JSON.stringify(_report, "\t"))
	file.close()
	print("NATIVE_PRESSURE_RESULT ", JSON.stringify(_report))
	quit(0)


func _capture() -> bool:
	# Report timing has ended. Explicit capture avoids waiting forever when the
	# window is occluded or normal rendering stops delivering frame_post_draw.
	RenderingServer.force_draw()
	var image: Image = root.get_texture().get_image()
	if image == null or image.save_png(_output.path_join("run.png")) != OK:
		return false
	return true


func _summaries() -> Dictionary:
	var result: Dictionary = {}
	for name: String in _times:
		var ordered: Array = _times[name].duplicate()
		ordered.sort()
		var over_budget: int = 0
		for value: float in ordered:
			over_budget += 1 if value > 1000.0 * LogisticsData.LOGIC_STEP else 0
		result[name] = {"samples": ordered.size(), "p50": ordered[ordered.size() / 2],
			"p95": ordered[ceili(ordered.size() * 0.95) - 1],
			"p99": ordered[ceili(ordered.size() * 0.99) - 1],
			"max": ordered[-1], "over_budget": over_budget}
	return result


func _phase(name: String, entering: bool) -> void:
	print("PRESSURE_PHASE ", JSON.stringify({"phase": name, "entering": entering,
		"usec": Time.get_ticks_usec(),
		"static_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"static_peak_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC_MAX)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT))}))


func _measure_switches() -> bool:
	var switches: Array[Dictionary] = []
	var store: SaveGameStore = SaveGameStore.new()
	store.directory = _report["save_directory"]
	store.phase_observer = _phase
	for index: int in range(_switch_count):
		var phase: String = "switch_%d" % (index + 1)
		_phase(phase + "_save", true)
		var save_started: int = Time.get_ticks_usec()
		var state: Dictionary = _game.save_state(true)
		var mounted_store: SaveGameStore = SaveGameStore.new()
		mounted_store.directory = _output.path_join("lifecycle/round_%d" % (index + 1))
		mounted_store.phase_observer = _phase
		var saved: bool = mounted_store.save_game(state)
		state.clear()
		if not saved:
			printerr(mounted_store.last_error)
			return false
		var save_seconds: float = float(Time.get_ticks_usec() - save_started) / 1000000.0
		_phase(phase + "_save", false)
		_phase(phase + "_load", true)
		store.directory = _alternate_save if index % 2 == 0 else _report["save_directory"]
		var started: int = Time.get_ticks_usec()
		# As in FactorySession.load_game: retain the active world until decoding
		# succeeds, then release it before mounting the new validated snapshot.
		var snapshot: SessionSnapshot = store.load_snapshot()
		if snapshot == null or snapshot.world_id == _game.world_id or (
			snapshot.logistics.transport_backend() != _report["backend"]
		):
			printerr(store.last_error)
			return false
		var decode_seconds: float = float(Time.get_ticks_usec() - started) / 1000000.0
		var mounted: int = Time.get_ticks_usec()
		root.remove_child(_game)
		_game.free()
		var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
		_game = scene.instantiate() as FactoryGame
		_game.initial_snapshot = snapshot
		root.add_child(_game)
		current_scene = _game
		isolate_game(_game)
		var mount_seconds: float = float(Time.get_ticks_usec() - mounted) / 1000000.0
		await process_frame
		_game.logistics_data.advance(LogisticsData.LOGIC_STEP)
		_game.logistics_view.refresh_from_data(0.0)
		if not _game.logistics_data.transport_error().is_empty() or not _game.logistics_view.display_error().is_empty():
			return false
		var actionable_seconds: float = float(Time.get_ticks_usec() - started) / 1000000.0
		_phase(phase + "_load", false)
		snapshot = null
		_phase(phase + "_settle", true)
		for frame: int in range(12):
			await process_frame
		_phase(phase + "_settle", false)
		switches.append({"decode_seconds": decode_seconds, "mount_seconds": mount_seconds,
			"to_first_actionable_seconds": actionable_seconds, "save_seconds": save_seconds,
			"different_world": true, "settle_frames": 12,
			"world_id": _game.world_id,
			"static_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
			"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
			"work": _game.logistics_data.work_stats(), "view": _game.logistics_view.stage_stats()})
	_report["switches"] = switches
	return true
