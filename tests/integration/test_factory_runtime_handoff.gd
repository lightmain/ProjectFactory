extends GdUnitTestSuite

const Fake: Script = preload("res://tests/helpers/fake_handoff_backend.gd")
const StaticTests: Script = preload("res://tests/integration/test_factory_static_view.gd")
var _backend: RefCounted
var _presentation: RefCounted
var _coordinator: FactoryRuntimeCoordinator
var _host: FactoryRuntimeHost
var _handoff: FactoryRuntimeHandoff
var _player: FactoryPlayer
var _camera: Camera3D
var _view: FactoryStaticView
var _menu: SessionMenu
var _keys: Array[Vector3i] = [Vector3i(-1, 0, 0)]


func before_test() -> void:
	_backend = Fake.new()
	_presentation = _backend.get("presentation") as RefCounted
	_round(1)
	var scene: PackedScene = load("res://scenes/player.tscn") as PackedScene
	_player = auto_free(scene.instantiate()) as FactoryPlayer
	add_child(_player)
	_player.set_physics_process(false)
	_player.position = Vector3(-3, 0.5, 1)
	_camera = auto_free(Camera3D.new()) as Camera3D
	add_child(_camera)
	_view = auto_free(FactoryStaticView.new()) as FactoryStaticView
	add_child(_view)
	_menu = auto_free(SessionMenu.new()) as SessionMenu
	add_child(_menu)
	_coordinator = FactoryRuntimeCoordinator.new(_backend, 1)
	_host = FactoryRuntimeHost.new(_coordinator, _player, _camera, _menu)
	_host.set_session({"world_id": "07070707070707070707070707070707",
		"world_name": "原世界", "autosave_minutes": 5.0, "autosave_retention": 3})
	_handoff = FactoryRuntimeHandoff.new(_backend, _coordinator, _host, _view,
		func(_candidate: Dictionary) -> Array[Vector3i]: return _keys.duplicate())
	_host.pump()


func after_test() -> void:
	_handoff.close()
	_host.disconnect_inputs()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _round(snapshot: int) -> void:
	_presentation.set("info", StaticTests._info(snapshot, 1))
	var pages: Array[Dictionary] = [StaticTests._page(snapshot, 0, 1)]
	_presentation.set("pages", pages)


func _initial() -> void:
	assert_bool(_handoff.request_current(_keys)).is_true()
	_handoff.pump()
	_handoff.physics_frame()
	assert_int(_view.get_child_count()).is_equal(1)


func _prepare() -> void:
	_host.request_load("08080808080808080808080808080808")
	_host.pump()
	_host.pump()
	_backend.call("emit_command", 1, "paused", {"paused": true})
	_host.pump()
	_host.pump()
	_backend.call("emit_command", 2, "load_prepared", {"job_id": 2})
	_backend.set("candidate", {"ok": true, "job_id": 2, "session": _session(),
		"minimum": Vector3i(-8, -3, -8), "maximum": Vector3i(9, 12, 9), "floor_depth": 3})
	_round(2)
	_host.pump()
	_handoff.pump()


func _session() -> Dictionary:
	return {"world_id": "08080808080808080808080808080808", "world_name": "候选世界",
		"autosave_minutes": 0.0, "autosave_retention": 2, "ruleset": "legacy_discrete_v1",
		"player": {"frame": 8, "position": Vector3(-2, 1, 1), "velocity": Vector3(0.1, 0.2, 0.3),
			"spawn": Vector3(-2, 0, 1), "body_rotation": Vector3(0, 0.3, 0),
			"rotation": Vector3(-0.4, 0, 0), "free_position": Vector3(-2, 2, 2),
			"free_rotation": Vector3(-0.5, 0.4, 0), "tool": 13, "build_rotation": 3, "free_view": true}}


func _decide() -> void:
	_handoff.physics_frame()
	_host.pump()
	_backend.call("emit_command", 3, "commit_decided", {"job_id": 2, "next_epoch": 2})
	_host.pump()
	_handoff.pump()


func test_current_resources_install_only_at_physics_boundary() -> void:
	assert_bool(_handoff.request_current(_keys)).is_true()
	assert_bool(_host.can_step_physics()).is_false()
	_handoff.pump()
	assert_int(_view.get_child_count()).is_equal(0)
	_handoff.physics_frame()
	assert_int(_view.get_child_count()).is_equal(1)
	assert_bool(_host.can_step_physics()).is_true()


func test_decision_installs_resources_player_camera_and_session_in_one_physics_frame() -> void:
	_initial()
	if _view.get_child_count() == 0:
		return
	var old_root: int = _view.get_child(0).get_instance_id()
	var old_position: Vector3 = _player.position
	_prepare()
	assert_int(_view.get_child(0).get_instance_id()).is_equal(old_root)
	assert_vector(_player.position).is_equal(old_position)
	_decide()
	assert_int(_view.get_child(0).get_instance_id()).is_equal(old_root)
	assert_vector(_player.position).is_equal(old_position)
	_handoff.physics_frame()
	assert_bool(is_instance_id_valid(old_root)).is_false()
	assert_vector(_player.position).is_equal(_session().player.position)
	assert_vector(_player.velocity).is_equal(_session().player.velocity)
	assert_vector(_camera.rotation).is_equal(_session().player.free_rotation)
	assert_str((_host.get("_session") as Dictionary).world_name).is_equal("候选世界")
	assert_str((_menu.get("_backend_name") as LineEdit).text).is_equal("候选世界")
	assert_bool(_host.can_step_physics()).is_false()
	var installed: int = _view.get_child(0).get_instance_id()
	_handoff.physics_frame()
	assert_int(_view.get_child(0).get_instance_id()).is_equal(installed)
	assert_str(_handoff.state().error).is_empty()


func test_invalid_session_after_decision_keeps_old_scene_and_can_retry() -> void:
	_initial()
	if _view.get_child_count() == 0:
		return
	var old_root: int = _view.get_child(0).get_instance_id()
	var old_position: Vector3 = _player.position
	_prepare()
	_decide()
	var invalid: Dictionary = _host.get("_candidate")
	invalid.session.player.rotation = Vector3(NAN, 0, 0)
	_handoff.physics_frame()
	assert_int(_view.get_child(0).get_instance_id()).is_equal(old_root)
	assert_vector(_player.position).is_equal(old_position)
	assert_bool(_host.can_step_physics()).is_false()
	assert_bool(_host.get("_switch_requested")).is_false()
	invalid.session.player.rotation = Vector3(-0.4, 0, 0)
	_handoff.physics_frame()
	assert_bool(is_instance_id_valid(old_root)).is_false()
	assert_vector(_player.position).is_equal(_session().player.position)


func test_cancel_keeps_old_scene_and_reuses_increasing_generation() -> void:
	_initial()
	if _view.get_child_count() == 0:
		return
	var old_root: int = _view.get_child(0).get_instance_id()
	var old_position: Vector3 = _player.position
	_prepare()
	assert_bool(_host.cancel_load()).is_true()
	_host.pump()
	_backend.call("emit_command", 2, "load_failed", {"job_id": 2, "error": "cancelled"})
	_host.pump()
	assert_int(_view.get_child(0).get_instance_id()).is_equal(old_root)
	assert_vector(_player.position).is_equal(old_position)
	_round(3)
	_handoff.pump()
	var subscriptions: Array = _presentation.get("subscriptions")
	assert_int(subscriptions.size()).is_equal(3)
	if subscriptions.size() == 3:
		assert_int(subscriptions[2].generation).is_equal(3)
		assert_int(subscriptions[2].job).is_equal(0)
	assert_str(_handoff.state().error).is_empty()


func test_ack_busy_holds_old_scene_and_does_not_send_ready() -> void:
	_initial()
	if _view.get_child_count() == 0:
		return
	var old_root: int = _view.get_child(0).get_instance_id()
	_prepare()
	_presentation.set("ack_busy", true)
	_handoff.physics_frame()
	_host.pump()
	assert_int((_backend.get("inputs") as Array).size()).is_equal(2)
	assert_int(_view.get_child(0).get_instance_id()).is_equal(old_root)
	_presentation.set("ack_busy", false)
	_handoff.physics_frame()
	_host.pump()
	assert_str((_backend.get("inputs") as Array)[2].kind).is_equal("ready")


func test_cancel_terminal_discards_ready_that_was_never_submitted() -> void:
	_initial()
	_prepare()
	_handoff.physics_frame()
	assert_bool(_host.cancel_load()).is_true()
	_backend.set("submit_error", "invalid_argument")
	_backend.call("emit_command", 2, "load_failed", {"job_id": 2, "error": "cancelled"})
	_host.pump()
	assert_str(_coordinator.state().error).is_empty()
	assert_str(_host.get("_error")).is_empty()
	assert_bool(_host.get("_load_requested")).is_false()
	assert_int((_backend.get("inputs") as Array).size()).is_equal(2)
	_backend.set("submit_error", "")
	_host.pump()
	var inputs: Array = _backend.get("inputs")
	assert_str(inputs[-1].kind).is_equal("resume")


func test_cancel_before_prepared_delivery_does_not_wait_for_retired_candidate_payload() -> void:
	var outcomes: Array[bool] = []
	_host.load_finished.connect(func(success: bool) -> void: outcomes.append(success))
	_host.request_load("08080808080808080808080808080808")
	_host.pump()
	_host.pump()
	_backend.call("emit_command", 1, "paused", {"paused": true})
	_host.pump()
	_host.pump()
	assert_bool(_host.cancel_load()).is_true()
	_backend.set("candidate", {"ok": false, "error": "invalid_argument"})
	_backend.call("emit_command", 2, "load_prepared", {"job_id": 2})
	_host.pump()
	assert_str(_host.get("_error")).is_empty()
	assert_array(_coordinator.pending_results()).is_empty()
	_backend.call("emit_command", 2, "load_failed", {"job_id": 2, "error": "cancelled"})
	_host.pump()
	assert_array(outcomes).is_equal([false])
	assert_bool(_host.get("_load_requested")).is_false()
	assert_str(_coordinator.state().error).is_empty()


func test_completed_switch_requires_fresh_epoch_resources_before_resume() -> void:
	_initial()
	if _view.get_child_count() == 0:
		return
	_prepare()
	_decide()
	_handoff.physics_frame()
	_host.pump()
	_backend.set("epoch", 2)
	_backend.call("emit_command", 4, "load_completed", {"job_id": 2, "next_epoch": 2})
	_host.pump()
	assert_int(_coordinator.state().epoch).is_equal(2)
	_host.request_pause(false)
	_host.pump()
	_host.pump()
	_backend.call("emit_command", 5, "paused", {"paused": false})
	_host.pump()
	assert_bool(_host.can_step_physics()).is_false()
	_round(3)
	_handoff.pump()
	_handoff.physics_frame()
	assert_bool(_host.can_step_physics()).is_true()
	var subscriptions: Array = _presentation.get("subscriptions")
	assert_int(subscriptions.size()).is_equal(3)
	if subscriptions.size() == 3:
		assert_int(subscriptions[2].epoch).is_equal(2)
		assert_int(subscriptions[2].generation).is_equal(1)
		assert_int(subscriptions[2].job).is_equal(0)


func test_motion_requires_matching_revision_and_full_sweep_coverage() -> void:
	_initial()
	var start: Vector3 = Vector3(-3, 1, 1)
	assert_bool(_handoff.guard_motion(start, Vector3(-2, 1, 1), Vector3.ONE * 0.1, 5)).is_true()
	assert_bool(_host.can_step_physics()).is_true()
	assert_bool(_handoff.guard_motion(start, Vector3(1, 1, 1), Vector3.ONE * 0.1, 5)).is_false()
	assert_bool(_host.can_step_physics()).is_false()
	assert_bool(_handoff.guard_motion(start, Vector3(-2, 1, 1), Vector3.ONE * 0.1, 6)).is_false()
	assert_bool(_host.can_step_physics()).is_false()
	assert_bool(_handoff.guard_motion(start, Vector3(-2, 1, 1), Vector3.ONE * 0.1, 5)).is_true()
	assert_bool(_host.can_step_physics()).is_true()
	_prepare()
	assert_bool(_handoff.guard_motion(start, start, Vector3.ONE * 0.1, 5)).is_false()


func test_interest_is_bounded_unique_and_includes_player_camera_negative_edges() -> void:
	var keys: Array[Vector3i] = FactoryRuntimeHandoff.interest_keys(Vector3(-0.01, 0, -0.01),
		Vector3(100, 20, 100))
	assert_int(keys.size()).is_less_equal(FactoryStaticView.MAX_KEYS)
	assert_bool(keys.has(Vector3i(-1, -1, -1))).is_true()
	assert_bool(keys.has(Vector3i(25, 5, 25))).is_true()
	var unique: Dictionary[Vector3i, bool] = {}
	for key: Vector3i in keys:
		unique[key] = true
	assert_int(unique.size()).is_equal(keys.size())
	assert_array(FactoryRuntimeHandoff.interest_keys(Vector3(NAN, 0, 0), Vector3.ZERO)).is_empty()
	assert_array(FactoryRuntimeHandoff.interest_keys(Vector3(1e20, 0, 0), Vector3.ZERO)).is_empty()


func test_default_candidate_interest_excludes_chunks_outside_saved_world() -> void:
	_handoff.set("_candidate_interest", Callable())
	_initial()
	_prepare()
	var subscriptions: Array = _presentation.get("subscriptions")
	assert_int(subscriptions.size()).is_equal(2)
	if subscriptions.size() != 2:
		return
	# The original save bounds are [-4,4.5) x [-1.5,6) x [-4,4.5) metres.
	for key: Vector3i in subscriptions[1].keys:
		assert_bool(key.x >= -1 and key.x <= 1 and key.y >= -1 and key.y <= 1 \
			and key.z >= -1 and key.z <= 1).is_true()


func test_candidate_page_failure_then_cancel_recovers_old_world_subscription() -> void:
	_initial()
	if _view.get_child_count() == 0:
		return
	var old_root: int = _view.get_child(0).get_instance_id()
	_prepare()
	_presentation.set("page_error", "geometry_failed")
	_round(3)
	_handoff.pump()
	assert_str(_handoff.state().error).is_not_empty()
	assert_int(_view.get_child(0).get_instance_id()).is_equal(old_root)
	assert_bool(_host.cancel_load()).is_true()
	_host.pump()
	_backend.call("emit_command", 2, "load_failed", {"job_id": 2, "error": "cancelled"})
	_host.pump()
	_presentation.set("page_error", "")
	_round(4)
	_handoff.pump()
	_handoff.physics_frame()
	assert_str(_handoff.state().error).is_empty()
	assert_bool(_handoff.state().waiting_current).is_false()
	var subscriptions: Array = _presentation.get("subscriptions")
	assert_int(subscriptions.size()).is_equal(3)
	if subscriptions.size() == 3:
		assert_int(subscriptions[2].generation).is_equal(3)
		assert_int(subscriptions[2].job).is_equal(0)


func test_invalid_session_metadata_cannot_replace_old_scene(field: String, value: Variant,
		player_field: bool, test_parameters: Array = [
			["world_id", "broken", false],
			["autosave_minutes", -1.0, false],
			["autosave_retention", 0, false],
			["tool", 100, true],
			["build_rotation", 4, true],
		]) -> void:
	_initial()
	if _view.get_child_count() == 0:
		return
	var old_root: int = _view.get_child(0).get_instance_id()
	_prepare()
	_decide()
	var candidate: Dictionary = _host.get("_candidate")
	var target: Dictionary = candidate.session.player if player_field else candidate.session
	target[field] = value
	_handoff.physics_frame()
	assert_int(_view.get_child(0).get_instance_id()).is_equal(old_root)
	assert_bool(_host.get("_switch_requested")).is_false()
