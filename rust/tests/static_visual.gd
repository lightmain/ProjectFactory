extends SceneTree
## Isolated real window: native pages, transformed parent, physical ray and PNG.

var _backend: RefCounted


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	assert(args.size() == 1 and not FileAccess.file_exists(args[0]))
	_backend = ClassDB.instantiate(&"FactoryBackend") as RefCounted
	assert(_backend != null)
	assert(_call("open_backend", [{"api_version": 1}]).ok)
	assert(_call("open_runtime", [{"epoch": 1, "ruleset": "conveyor_continuous_v1",
		"minimum": Vector3i(-8, -4, -8), "maximum": Vector3i(16, 12, 16),
		"floor_depth": 4, "interval": 0.1, "amount": 1}]).ok)
	var commands: Array[Dictionary] = [{"seq": 1, "kind": "build",
		"cells": [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0),
			Vector3i(4, 0, 1), Vector3i(6, 0, 3)],
		"blocks": PackedInt32Array([5, 6, 7, 12, 8]),
		"directions": PackedInt32Array([3, 3, 3, 3, 3])}]
	assert((await _retry("submit_runtime", [1, commands])).ok)
	for frame: int in range(300):
		var page: Dictionary = await _retry("poll_runtime", [0, 256, 65536])
		if not page.results.is_empty():
			assert(page.results[0].outcome == "committed")
			break
		await process_frame
	var view: FactoryStaticView = FactoryStaticView.new()
	view.position = Vector3(1, 0.8, 2)
	view.rotation.y = 0.35
	view.scale = Vector3.ONE * 1.2
	root.add_child(view)
	var stream: FactoryPresentationStream = FactoryPresentationStream.new(_backend, view)
	var keys: Array[Vector3i] = []
	for x: int in range(-1, 2):
		for y: int in [-1, 0]:
			for z: int in range(-1, 2):
				keys.append(Vector3i(x, y, z))
	assert(stream.request(1, 0, keys))
	var deadline: int = Time.get_ticks_msec() + 5000
	while not stream.state().prepared:
		stream.pump()
		assert(stream.state().error == "" and Time.get_ticks_msec() < deadline)
		await process_frame
	while not stream.confirm_prepared():
		assert(stream.state().error == "" and Time.get_ticks_msec() < deadline)
		await process_frame
	await physics_frame
	assert(stream.activate())
	var camera: Camera3D = Camera3D.new()
	camera.position = Vector3(12, 11, 13)
	camera.far = 100
	root.add_child(camera)
	camera.look_at(view.to_global(Vector3(1.5, 0, 1.5)))
	camera.current = true
	var light: DirectionalLight3D = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -30, 0)
	light.shadow_enabled = true
	root.add_child(light)
	var environment: WorldEnvironment = WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("#a3bec9")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("#d8e5ef")
	environment.environment.ambient_light_energy = 0.7
	root.add_child(environment)
	for body: Node in view.get_child(0).get_children():
		var visual: MeshInstance3D = body.get_node("Mesh") as MeshInstance3D
		var material: ShaderMaterial = visual.material_override as ShaderMaterial
		material.set_shader_parameter("decorations_enabled", true)
		material.set_shader_parameter("decoration_distance", 100.0)
		material.set_shader_parameter("decoration_camera", camera.global_position)
	await physics_frame
	await physics_frame
	var ray: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		view.to_global(Vector3(-1, 5, -1)), view.to_global(Vector3(-1, -2, -1)), 1)
	var hit: Dictionary = root.world_3d.direct_space_state.intersect_ray(ray)
	assert(not hit.is_empty())
	assert((hit.position as Vector3).is_equal_approx(view.to_global(Vector3(-1, 0, -1))))
	assert(view.covers_sweep(view.to_global(Vector3(-1, 1, -1)),
		view.to_global(Vector3(2, 1, 2)), Vector3.ONE * 0.2, 1, 1))
	for frame: int in range(60):
		await process_frame
	assert(root.get_texture().get_image().save_png(args[0]) == OK)
	stream.close()
	while not stream.state().closed:
		stream.pump()
		assert(Time.get_ticks_msec() < deadline)
		await process_frame
	assert(_call("close_runtime", []).ok)
	while not _call("runtime_stopped", []).stopped:
		assert(Time.get_ticks_msec() < deadline)
		await process_frame
	assert(_call("close_backend", []).ok)
	print("FACTORY_STATIC_VISUAL_PASS")
	quit(0)


func _call(method: String, args: Array) -> Dictionary:
	var result: Variant = _backend.callv(method, args)
	assert(result is Dictionary)
	return result as Dictionary


func _retry(method: String, args: Array) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + 5000
	while true:
		var result: Dictionary = _call(method, args)
		if result.get("error", "") != "busy":
			return result
		assert(Time.get_ticks_msec() < deadline)
		await process_frame
	return {}
