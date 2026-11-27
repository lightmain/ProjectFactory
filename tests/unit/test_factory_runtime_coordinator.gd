extends GdUnitTestSuite

const FakeBackend: Script = preload("res://tests/helpers/fake_runtime_backend.gd")


static func player(frame: int) -> Dictionary:
	return {"frame": frame, "position": Vector3.ZERO, "velocity": Vector3.ZERO,
		"spawn": Vector3.ZERO, "body_rotation": Vector3.ZERO, "rotation": Vector3.ZERO,
		"tool": 6, "build_rotation": 0, "free_view": false,
		"free_position": Vector3.ZERO, "free_rotation": Vector3.ZERO}


func test_only_unaccepted_busy_request_is_retried_and_second_operation_waits() -> void:
	var backend: RefCounted = FakeBackend.new()
	var coordinator: FactoryRuntimeCoordinator = FactoryRuntimeCoordinator.new(backend)
	backend.set("submit_busy", true)
	coordinator.pump()
	var original: Dictionary = {"kind": "frame", "frame_seq": 1, "delta": 0.012}
	var request: Dictionary = coordinator.enqueue(original)
	assert_bool(request.ok).is_true()
	original.delta = 0.03
	coordinator.pump()
	coordinator.pump()
	var attempts: Array = backend.get("attempts")
	assert_int(attempts.size()).is_equal(2)
	assert_dict(attempts[0].input).is_equal(attempts[1].input)
	assert_float(attempts[0].input.delta).is_equal(0.012)
	assert_bool(attempts[0].input.has("player")).is_false()
	assert_str(coordinator.enqueue({"kind": "pause"}).error).is_equal("busy")
	backend.set("submit_busy", false)
	coordinator.pump()
	coordinator.pump()
	assert_int((backend.get("inputs") as Array).size()).is_equal(1)
	assert_bool(coordinator.motion_frozen()).is_true()
	backend.call("emit_command", request.request_id, "frame_completed", {"frame_seq": 1})
	coordinator.pump()
	assert_int(coordinator.pending_results().size()).is_equal(1)
	coordinator.pump()
	var budgets: Array = backend.get("poll_budgets")
	assert_int(budgets[-1]).is_equal(0)
	assert_bool(coordinator.take_result(request.request_id)).is_true()
	assert_bool(coordinator.take_result(request.request_id)).is_false()
	assert_bool(coordinator.motion_frozen()).is_false()


func test_pause_then_resume_is_confirmed_in_order() -> void:
	var backend: RefCounted = FakeBackend.new()
	var coordinator: FactoryRuntimeCoordinator = FactoryRuntimeCoordinator.new(backend)
	coordinator.pump()
	var pause_request: Dictionary = coordinator.enqueue({"kind": "pause"})
	coordinator.pump()
	assert_bool(coordinator.motion_frozen()).is_true()
	assert_bool(coordinator.state().pause_confirmed).is_false()
	backend.call("emit_command", pause_request.request_id, "paused", {"paused": true})
	coordinator.pump()
	assert_bool(coordinator.take_result(pause_request.request_id)).is_true()
	assert_bool(coordinator.state().pause_confirmed).is_true()
	var resume_request: Dictionary = coordinator.enqueue({"kind": "resume"})
	coordinator.pump()
	assert_bool(coordinator.motion_frozen()).is_true()
	backend.call("emit_command", resume_request.request_id, "paused", {"paused": false})
	coordinator.pump()
	coordinator.take_result(resume_request.request_id)
	assert_bool(coordinator.motion_frozen()).is_false()


func test_capture_completion_allows_world_work_while_disk_terminal_remains_pending() -> void:
	var backend: RefCounted = FakeBackend.new()
	var coordinator: FactoryRuntimeCoordinator = FactoryRuntimeCoordinator.new(backend)
	coordinator.pump()
	var pause_request: Dictionary = coordinator.enqueue({"kind": "pause"})
	coordinator.pump()
	backend.call("emit_command", pause_request.request_id, "paused", {"paused": true})
	coordinator.pump()
	coordinator.take_result(pause_request.request_id)
	var save_request: Dictionary = coordinator.enqueue({"kind": "save", "player": player(0)})
	coordinator.pump()
	backend.call("emit_command", save_request.request_id, "save_started", {"job_id": save_request.request_id})
	coordinator.pump()
	coordinator.take_result(save_request.request_id)
	assert_bool(coordinator.state().disk_pending).is_true()
	var resume_request: Dictionary = coordinator.enqueue({"kind": "resume"})
	coordinator.pump()
	backend.call("emit_command", resume_request.request_id, "paused", {"paused": false})
	backend.call("emit_command", save_request.request_id, "save_completed", {"job_id": save_request.request_id})
	coordinator.pump()
	assert_int(coordinator.pending_results().size()).is_equal(2)
	coordinator.take_result(resume_request.request_id)
	coordinator.take_result(save_request.request_id)
	assert_bool(coordinator.state().disk_pending).is_false()
	assert_bool(coordinator.motion_frozen()).is_false()


func test_cancel_sets_flag_without_a_control_sequence_or_result() -> void:
	var backend: RefCounted = FakeBackend.new()
	var coordinator: FactoryRuntimeCoordinator = FactoryRuntimeCoordinator.new(backend)
	coordinator.pump()
	var response: Dictionary = coordinator.queue_control("cancel", 17)
	assert_bool(response.ok).is_true()
	assert_bool(response.cancelled).is_true()
	var controls: Array = backend.get("controls")
	assert_dict(controls[0]).is_equal({"kind": "cancel", "epoch": 1, "job": 17})
	assert_array(coordinator.pending_results()).is_empty()


func test_bad_identity_and_close_freeze_motion() -> void:
	var backend: RefCounted = FakeBackend.new()
	var coordinator: FactoryRuntimeCoordinator = FactoryRuntimeCoordinator.new(backend)
	coordinator.pump()
	backend.call("emit_command", 91, "committed")
	coordinator.pump()
	assert_str(coordinator.state().error).is_equal("invalid_result_identity")
	assert_bool(coordinator.motion_frozen()).is_true()
	coordinator.close()
	assert_bool(backend.get("closed")).is_true()
	backend.set("stopped", true)
	coordinator.pump()
	assert_bool(coordinator.state().stopped).is_true()


func test_payload_bounds_reject_objects_before_serialization() -> void:
	var backend: RefCounted = FakeBackend.new()
	var coordinator: FactoryRuntimeCoordinator = FactoryRuntimeCoordinator.new(backend)
	var object: Node = auto_free(Node.new())
	assert_bool(coordinator.enqueue({"kind": "cell", "bad": object}).ok).is_false()
	assert_bool(coordinator.enqueue({"kind": "unknown"}).ok).is_false()
	var rows: Array = []
	rows.resize(257)
	assert_bool(coordinator.accepts_payload({"rows": rows})).is_false()


func test_switch_fault_before_epoch_change_keeps_the_original_fault_identity() -> void:
	var backend: RefCounted = FakeBackend.new()
	var coordinator: FactoryRuntimeCoordinator = FactoryRuntimeCoordinator.new(backend)
	coordinator.pump()
	var pause_request: Dictionary = coordinator.enqueue({"kind": "pause"})
	coordinator.pump()
	backend.call("emit_command", pause_request.request_id, "paused", {"paused": true})
	coordinator.pump()
	coordinator.take_result(pause_request.request_id)
	var load_request: Dictionary = coordinator.enqueue({"kind": "prepare_load",
		"save_id": "07070707070707070707070707070707"})
	coordinator.pump()
	backend.call("emit_command", load_request.request_id, "load_prepared",
		{"job_id": load_request.request_id})
	coordinator.pump()
	coordinator.take_result(load_request.request_id)
	assert_bool(coordinator.begin_handoff(load_request.request_id)).is_true()
	var ready_request: Dictionary = coordinator.queue_control("ready", load_request.request_id)
	coordinator.pump()
	backend.call("emit_command", ready_request.request_id, "commit_decided",
		{"job_id": load_request.request_id, "next_epoch": 2})
	coordinator.pump()
	coordinator.take_result(ready_request.request_id)
	var switch_request: Dictionary = coordinator.queue_control("switch", load_request.request_id, 2)
	coordinator.pump()
	backend.set("status", "faulted")
	backend.call("emit_command", switch_request.request_id, "faulted")
	coordinator.pump()
	assert_str(coordinator.state().error).is_equal("faulted")
	assert_int(coordinator.pending_results().size()).is_equal(1)
	if coordinator.pending_results().size() == 1:
		assert_int(coordinator.pending_results()[0].world_epoch).is_equal(1)
	assert_bool(coordinator.motion_frozen()).is_true()
