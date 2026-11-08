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
	if args.size() < 2 or args[0] not in ["generate", "run"]:
		printerr("Usage: -- generate|run SAVE_DIRECTORY [SIZE HEIGHT | SECONDS]")
		quit(2)
		return
	_directory = args[1]
	var store: SaveGameStore = SaveGameStore.new()
	store.directory = _directory
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
	var snapshot: SessionSnapshot = SessionSnapshot.decode(store.load_named(store.latest_id()))
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
