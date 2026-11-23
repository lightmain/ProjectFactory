extends SceneTree
## -- SIZE HEIGHT OUTPUT [SAMPLES WARMUP BACKEND]
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
var _producer_cells: Array[Vector3i] = []
var _work_samples: Array[Dictionary] = []
var _report: Dictionary = {}
var _times: Dictionary[String, Array] = {}


func _initialize() -> void:
	if DisplayServer.get_name() != "headless":
		root.mode = Window.MODE_WINDOWED
		root.show()
		DisplayServer.window_move_to_foreground()
		RenderingServer.frame_post_draw.connect(_on_frame_drawn)
	call_deferred("_mount")


func _on_frame_drawn() -> void:
	_drawn_frames += 1


func _mount() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 3:
		printerr("Usage: -- SIZE HEIGHT NEW_OUTPUT [SAMPLES WARMUP rust|gdscript]")
		quit(2)
		return
	var size: int = int(args[0])
	var height: int = int(args[1])
	_output = args[2]
	_samples = int(args[3]) if args.size() > 3 else 300
	_warmup = int(args[4]) if args.size() > 4 else 120
	var backend: String = args[5] if args.size() > 5 else "rust"
	_report["provenance"] = args[6] if args.size() > 6 else "unavailable: direct script invocation"
	if _samples < 1 or _samples > 100000 or _warmup < 0 or _warmup > 3600 or (
		backend not in ["rust", "gdscript"] or DirAccess.dir_exists_absolute(_output)
	):
		quit(2)
		return
	if DirAccess.make_dir_recursive_absolute(_output) != OK:
		quit(1)
		return
	var builder: PressureSaveBuilder = PressureSaveBuilder.new()
	var started: int = Time.get_ticks_usec()
	var snapshot: SessionSnapshot = builder.build(size, height, backend)
	if snapshot == null:
		printerr(builder.last_error)
		quit(1)
		return
	_report["build_seconds"] = float(Time.get_ticks_usec() - started) / 1000000.0
	var store: SaveGameStore = SaveGameStore.new()
	store.directory = _output.path_join("save")
	started = Time.get_ticks_usec()
	var state: Dictionary = PressureSaveBuilder.state_for(snapshot)
	_report["checkpoint_seconds"] = float(Time.get_ticks_usec() - started) / 1000000.0
	started = Time.get_ticks_usec()
	if not store.save_game(state):
		printerr("Pressure save failed: ", store.last_error)
		quit(1)
		return
	_report["disk_save_seconds"] = float(Time.get_ticks_usec() - started) / 1000000.0
	state.clear()
	snapshot = null
	started = Time.get_ticks_usec()
	snapshot = store.load_snapshot()
	_report["disk_load_decode_seconds"] = float(Time.get_ticks_usec() - started) / 1000000.0
	if snapshot == null or snapshot.logistics.transport_backend() != backend:
		printerr("Pressure disk load failed: ", store.last_error)
		quit(1)
		return
	started = Time.get_ticks_usec()
	var route: Dictionary = PressureSaveBuilder.route_certificate(snapshot)
	if route.is_empty():
		printerr("Pressure topology is not a complete route. ", snapshot.logistics.transport_error())
		quit(1)
		return
	_report["route_validation_seconds"] = float(Time.get_ticks_usec() - started) / 1000000.0
	_report["route"] = route
	_sink = route["sink"]
	var producer_cells: Array[Vector3i] = route["producer_cells"]
	_producer_cells = producer_cells
	_initial_ore = snapshot.logistics.total_ore()
	print("NATIVE_PRESSURE_BUILT belts=", route["belts"], " ores=", _initial_ore,
		" seconds=", _report["build_seconds"])
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_game = scene.instantiate() as FactoryGame
	_game.initial_snapshot = snapshot
	started = Time.get_ticks_usec()
	root.add_child(_game)
	current_scene = _game
	isolate_game(_game)
	_report["mount_seconds"] = float(Time.get_ticks_usec() - started) / 1000000.0
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
	if _warmup == 0 and _sampled == 0:
		var audit_started: int = Time.get_ticks_usec()
		_report["window_start"] = _population()
		_report["window_start_work"] = _game.logistics_data.work_stats()
		_report["start_audit_seconds"] = float(Time.get_ticks_usec() - audit_started) / 1000000.0
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
		"work": stats, "view": view})


func _population() -> Dictionary:
	var total: int = _game.logistics_data.total_ore()
	var inventory: int = _game.logistics_data.ore_count(_sink)
	for cell: Vector3i in _producer_cells:
		inventory += _game.logistics_data.ore_count(cell)
	return {"total": total, "inventory": inventory, "on_belt": total - inventory,
		"sink": _game.logistics_data.ore_count(_sink)}


func _finish(ended: int) -> void:
	_report["wall_seconds"] = float(ended - _started) / 1000000.0
	_report["drawn_frames_during_window"] = _drawn_frames - _window_start_drawn_frames
	if DisplayServer.get_name() != "headless" and _report["drawn_frames_during_window"] < 1:
		printerr("Graphical measurement window did not draw any frame.")
		quit(1)
		return
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
	if DisplayServer.get_name() != "headless":
		call_deferred("_capture")
	else:
		quit(0)


func _capture() -> void:
	# Report timing has ended. Explicit capture avoids waiting forever when the
	# window is occluded or normal rendering stops delivering frame_post_draw.
	RenderingServer.force_draw()
	var image: Image = root.get_texture().get_image()
	if image == null or image.save_png(_output.path_join("run.png")) != OK:
		quit(1)
		return
	quit(0)


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
