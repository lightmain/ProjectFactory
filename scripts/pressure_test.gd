extends SceneTree
## godot --path PROJECT -s res://scripts/pressure_test.gd -- generate|run OUTPUT [SIZE HEIGHT]
## "run" mounts the real FactoryGame, renders its default first-person camera,
## measures completed ticks/drawn frames against wall time, and quits.

var _game: FactoryGame
var _directory: String
var _load_seconds: float = 0.0
var _mount_seconds: float = 0.0
var _warmup: int = 2
var _frames: int = 0
var _start_tick: int = 0
var _start_drawn: int = 0
var _start_usec: int = 0
var _duration: float = 15.0
var _machines: int = 0
var _ore_count: int = 0
var _route: Dictionary = {}
var _route_seconds: float = 0.0


func _initialize() -> void:
	root.grab_focus()
	call_deferred("_run")


func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 2 or args[0] not in ["generate", "run", "benchmark"]:
		printerr("Usage: -- generate|run SAVE_DIRECTORY [SIZE HEIGHT | SECONDS]")
		printerr("       -- benchmark SAVE_DIRECTORY REPORT_DIRECTORY [SAMPLES SECONDS ROUNDS TIMEOUT]")
		quit(2)
		return
	_directory = args[1]
	var store: SaveGameStore = SaveGameStore.new()
	store.directory = _directory
	if args[0] == "benchmark":
		_benchmark(args, store)
		return
	if args[0] == "generate":
		var size: int = int(args[2]) if args.size() > 2 else 128
		var height: int = int(args[3]) if args.size() > 3 else 64
		var started: int = Time.get_ticks_usec()
		var builder: PressureSaveBuilder = PressureSaveBuilder.new()
		var snapshot: SessionSnapshot = builder.build(size, height)
		if snapshot == null:
			printerr(builder.last_error)
			quit(1)
			return
		print("PRESSURE_BUILD ", float(Time.get_ticks_usec() - started) / 1000000.0)
		var route: Dictionary = PressureSaveBuilder.route_certificate(snapshot)
		if route.is_empty():
			printerr("Pressure route is not one complete belt chain.")
			quit(1)
			return
		var state: Dictionary = PressureSaveBuilder.state_for(snapshot)
		var machines: int = snapshot.logistics.machine_cells().size()
		var ores: int = snapshot.logistics.total_ore()
		snapshot = null
		var write_start: int = Time.get_ticks_usec()
		var save_name: String = state["world_name"]
		if not store.save_named(state, save_name):
			printerr(store.last_error)
			quit(1)
			return
		var report: Dictionary = {"size": [size, height, size], "machines": machines,
			"miners": 4, "chests": 1, "belts": machines - 5, "ores": ores,
			"save_id": store.latest_id(), "route": route,
			"write_seconds": float(Time.get_ticks_usec() - write_start) / 1000000.0}
		if not _write_json("generation.json", report):
			quit(1)
			return
		print("PRESSURE_GENERATED ", JSON.stringify(report))
		quit()
		return
	if DisplayServer.get_name() == "headless":
		printerr("Rendering measurement requires a graphical Godot process.")
		quit(2)
		return
	_duration = maxf(1.0, float(args[2])) if args.size() > 2 else 15.0
	var started: int = Time.get_ticks_usec()
	var snapshot: SessionSnapshot = store.load_named_snapshot(store.latest_id())
	if snapshot == null:
		printerr("Load failed: ", store.last_error)
		quit(1)
		return
	_load_seconds = float(Time.get_ticks_usec() - started) / 1000000.0
	started = Time.get_ticks_usec()
	_route = PressureSaveBuilder.route_certificate(snapshot)
	_route_seconds = float(Time.get_ticks_usec() - started) / 1000000.0
	if _route.is_empty():
		printerr("Restored pressure route is not one complete belt chain.")
		quit(1)
		return
	_machines = snapshot.logistics.machine_cells().size()
	_ore_count = snapshot.logistics.total_ore()
	print("PRESSURE_LOADED ", _load_seconds, " machines=", _machines, " ores=", _ore_count)
	var scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	_game = scene.instantiate() as FactoryGame
	_game.initial_snapshot = snapshot
	started = Time.get_ticks_usec()
	root.add_child(_game)
	current_scene = _game
	_mount_seconds = float(Time.get_ticks_usec() - started) / 1000000.0
	print("PRESSURE_MOUNTED ", _mount_seconds)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	root.grab_focus()
	RenderingServer.frame_post_draw.connect(_measure)


func _benchmark(args: PackedStringArray, store: SaveGameStore) -> void:
	if args.size() < 3 or args.size() > 7:
		printerr("benchmark requires a new report directory.")
		quit(2)
		return
	for index: int in range(3, args.size()):
		var integer_argument: bool = index == 3 or index == 5
		if (integer_argument and not args[index].is_valid_int()) or (
			not integer_argument and not args[index].is_valid_float()
		):
			printerr("Invalid benchmark number: ", args[index])
			quit(2)
			return
	var count: int = int(args[3]) if args.size() > 3 else 120
	var seconds: float = float(args[4]) if args.size() > 4 else 30.0
	var rounds: int = int(args[5]) if args.size() > 5 else 3
	var timeout: float = float(args[6]) if args.size() > 6 else 120.0
	if count < 1 or count > 100000 or rounds < 1 or rounds > 10 or (
		not is_finite(seconds) or seconds < 0.0 or seconds > 600.0
		or not is_finite(timeout) or timeout < 0.0 or timeout > 600.0
	):
		printerr("Invalid benchmark samples, duration, rounds or timeout.")
		quit(2)
		return
	var output: String = args[2]
	if DirAccess.dir_exists_absolute(output) or FileAccess.file_exists(output):
		printerr("Report directory already exists: ", output)
		quit(2)
		return
	var save_id: String = store.latest_id()
	if save_id.is_empty() or DirAccess.make_dir_recursive_absolute(output) != OK:
		printerr("Missing save or cannot create report directory.")
		quit(1)
		return
	_directory = output
	var reports: Array[Dictionary] = []
	var fingerprint: String = ""
	var complete: bool = true
	for round_index: int in range(rounds):
		var before_decodes: int = store.snapshot_decodes
		var started: int = Time.get_ticks_usec()
		var snapshot: SessionSnapshot = store.load_named_snapshot(save_id, true)
		var load_seconds: float = float(Time.get_ticks_usec() - started) / 1000000.0
		if snapshot == null:
			printerr("Load failed: ", store.last_error)
			quit(1)
			return
		var state_hash: String = store.loaded_state_sha256
		if not fingerprint.is_empty() and fingerprint != state_hash:
			printerr("Save content changed between benchmark rounds.")
			quit(1)
			return
		fingerprint = state_hash
		var rebuilds: int = store.snapshot_decodes - before_decodes
		if rebuilds != 1:
			printerr("Successful load must rebuild exactly once.")
			quit(1)
			return
		var route: Dictionary = PressureSaveBuilder.route_certificate(snapshot)
		if route.is_empty():
			printerr("Restored baseline is not a complete pressure belt chain.")
			quit(1)
			return
		var initial_ores: int = snapshot.logistics.total_ore()
		var report: Dictionary = PressureBenchmark.measure(snapshot, count, seconds, timeout)
		report["load_validate_seconds"] = load_seconds
		report["snapshot_rebuilds"] = rebuilds
		report["route"] = route
		report["initial_ores"] = initial_ores
		report["final_ores"] = snapshot.logistics.total_ore()
		report["round"] = round_index + 1
		report["save_id"] = save_id
		report["state_sha256"] = state_hash
		var samples_file: String = "round_%02d.json" % (round_index + 1)
		if not _write_json(samples_file, report):
			quit(1)
			return
		complete = complete and report["complete"]
		snapshot = null
		# Each round's raw arrays are already on disk; retain summaries only.
		var summary: Dictionary = report.duplicate()
		summary.erase("tick_ms")
		summary.erase("display_ms")
		summary["samples_file"] = samples_file
		reports.append(summary)
		print("PRESSURE_BENCHMARK_ROUND ", round_index + 1,
			" tick=", JSON.stringify(report["tick"]), " complete=", report["complete"])
	var result: Dictionary = {
		"schema": 3, "mode": "isolated_rules", "save_id": save_id,
		"state_sha256": fingerprint, "engine": Engine.get_version_info()["string"],
		"cpu": OS.get_processor_name(), "complete": complete, "rounds": reports,
		"static_memory_peak_bytes": Performance.get_monitor(Performance.MEMORY_STATIC_MAX),
		"limits": [
			"Rule timings include cold caches; no scene mounting or graphical rendering.",
			"Display timings measure full sample_belts only; observer scans are timed separately.",
			"Memory is engine static allocation peak for this process, not peak RSS.",
			"Observer includes work accounting and result cleanup; display measures the call only.",
			"Timeout covers measurement only, excluding load, decode and route audit.",
			"Raw samples capped at 100000 per round; capacity exhaustion is incomplete.",
			"Timeout checked between completed tick/sample pairs; an in-flight pair may exceed it.",
		],
	}
	if not _write_json("benchmark.json", result):
		quit(1)
		return
	print("PRESSURE_BENCHMARK_RESULT ", output.path_join("benchmark.json"))
	quit(0 if complete else 3)


func _measure() -> void:
	if _warmup > 0:
		_warmup -= 1
		_start_tick = _game.logistics_data.logic_tick()
		_start_drawn = Engine.get_frames_drawn()
		_start_usec = Time.get_ticks_usec()
		if _warmup == 0:
			print("PRESSURE_MEASURING")
		return
	_frames += 1
	var elapsed: float = float(Time.get_ticks_usec() - _start_usec) / 1000000.0
	if elapsed < _duration:
		return
	RenderingServer.frame_post_draw.disconnect(_measure)
	var ticks: int = _game.logistics_data.logic_tick() - _start_tick
	var drawn: int = Engine.get_frames_drawn() - _start_drawn
	var report: Dictionary = {
		"engine": Engine.get_version_info()["string"],
		"renderer": RenderingServer.get_current_rendering_method(),
		"gpu": RenderingServer.get_video_adapter_name(), "cpu": OS.get_processor_name(),
		"machines": _machines, "belts": _machines - 5, "initial_ores": _ore_count,
		"load_seconds": _load_seconds, "mount_seconds": _mount_seconds,
		"route": _route, "route_validation_seconds": _route_seconds,
		"warmup_frames": 2, "measurement_seconds": elapsed,
		"logic_ticks": ticks, "render_frames": drawn, "post_draw_callbacks": _frames,
		"logic_fps": float(ticks) / elapsed, "render_fps": float(drawn) / elapsed,
		"target_logic_fps": Engine.physics_ticks_per_second,
		"viewport": root.size, "camera_position": _game.player.camera.global_position,
		"ore_render_distance": _game.logistics_view.render_distance,
		"final_ore": _game.logistics_data.total_ore(),
	}
	_game.set_physics_process(false)
	var image: Image = root.get_texture().get_image()
	if image == null or image.save_png(_directory.path_join("run.png")) != OK:
		printerr("Cannot save rendered screenshot.")
		quit(1)
		return
	if not _write_json("performance.json", report):
		quit(1)
		return
	print("PRESSURE_RESULT ", JSON.stringify(report))
	quit()


func _write_json(filename: String, value: Dictionary) -> bool:
	var file: FileAccess = FileAccess.open(_directory.path_join(filename), FileAccess.WRITE)
	if file == null:
		printerr("Cannot open report: ", filename)
		return false
	file.store_string(JSON.stringify(value, "\t"))
	file.flush()
	var error: Error = file.get_error()
	file.close()
	if error != OK:
		printerr("Cannot write report: ", filename)
	return error == OK
