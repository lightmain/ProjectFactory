extends SceneTree


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	assert(ResourceLoader.exists("res://scripts/backend/factory_playground.gd"), "M05 playable scene is missing")
	var script: Script = load("res://scripts/backend/factory_playground.gd") as Script
	var game: Node3D = Node3D.new()
	game.set_script(script)
	var save_root: String = "user://test_playground_" + str(Time.get_ticks_usec())
	game.set("save_root", save_root)
	root.add_child(game)
	assert(game.get("ready_for_play") == true)
	game.set_physics_process(false)
	game.set_process(false)
	var player: FactoryPlayer = game.get("player") as FactoryPlayer
	assert(player != null)
	player.set_physics_process(false)
	for frame: int in range(600):
		game.call("poll_persistence")
		if game.get("_job_id") == 0:
			break
		await process_frame
	assert(game.get("_job_id") == 0)
	var tab: InputEventAction = InputEventAction.new()
	tab.action = &"toggle_view"
	tab.pressed = true
	player.handle_input(tab)
	assert(game.get("free_view") == true)
	player.position.y = -0.5
	player.velocity = Vector3.DOWN
	game.call("start_factory", "legacy_discrete_v1")
	assert(game.get("ready_for_play") == true)
	assert(player.position.y > 0.0, "Recreated terrain must leave the player above the ground")
	assert(player.velocity == Vector3.ZERO)
	game.call("set_paused", true)
	var state: Dictionary = game.call("snapshot")
	game.call("advance", 1.0)
	var paused_state: Dictionary = game.call("snapshot")
	assert(paused_state.tick == state.tick)
	game.call("set_paused", false)
	game.call("advance", 10.0)
	state = game.call("snapshot")
	assert(state.produced > 0)
	var received: int = 0
	for machine: Dictionary in state.machines:
		if machine.block == 7:
			received += int(machine.quantity)
	assert(received > 0)
	assert(game.get("free_view") == true)
	game.call("start_factory", "conveyor_continuous_v1")
	game.call("advance", 10.0)
	if "--visual" in OS.get_cmdline_user_args():
		for frame: int in range(30):
			await process_frame
		await RenderingServer.frame_post_draw
		var arguments: PackedStringArray = OS.get_cmdline_user_args()
		var image: Image = root.get_texture().get_image()
		assert(image.save_png(arguments[arguments.size() - 1]) == OK)
	root.remove_child(game)
	game.free()
	for file: String in DirAccess.get_files_at(save_root):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(save_root.path_join(file)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_root))
	print("FACTORY_PLAYGROUND_PASS")
	quit()
