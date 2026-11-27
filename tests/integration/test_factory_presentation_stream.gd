extends GdUnitTestSuite

const Fake: Script = preload("res://tests/helpers/fake_presentation_backend.gd")
const StaticTests: Script = preload("res://tests/integration/test_factory_static_view.gd")
var _backend: RefCounted
var _view: FactoryStaticView
var _stream: FactoryPresentationStream


func before_test() -> void:
	_backend = Fake.new()
	_backend.set("info", StaticTests._info(1, 2))
	var pages: Array[Dictionary] = [StaticTests._page(1, 0, 2), StaticTests._page(1, 1, 2)]
	_backend.set("pages", pages)
	_view = auto_free(FactoryStaticView.new()) as FactoryStaticView
	add_child(_view)
	_stream = FactoryPresentationStream.new(_backend, _view)


func after_test() -> void:
	_stream.close()


func test_busy_preserves_generation_and_one_page_is_copied_per_pump() -> void:
	var keys: Array[Vector3i] = [Vector3i(-1, 0, 0)]
	assert_bool(_stream.request(1, 0, keys)).is_true()
	keys.clear()
	_backend.set("busy", true)
	_stream.pump()
	assert_int(_stream.state().generation).is_equal(1)
	assert_array(_backend.get("reads")).is_empty()
	_backend.set("busy", false)
	_stream.pump()
	assert_int(_stream.state().page_index).is_equal(1)
	assert_bool(_stream.state().prepared).is_false()
	_stream.pump()
	assert_bool(_stream.state().prepared).is_true()
	assert_array(_backend.get("reads")).is_equal([0, 1])
	assert_int(_view.get_child_count()).is_equal(0)
	_backend.set("busy", true)
	assert_bool(_stream.confirm_prepared()).is_false()
	assert_bool(_stream.state().prepared).is_true()
	assert_int(_stream.state().page_index).is_equal(2)
	_backend.set("busy", false)
	_backend.set("ack_busy", true)
	assert_bool(_stream.confirm_prepared()).is_false()
	assert_bool(_stream.activate()).is_false()
	_backend.set("ack_busy", false)
	assert_bool(_stream.confirm_prepared()).is_true()
	assert_bool(_stream.confirm_prepared()).is_true()
	assert_int((_backend.get("acknowledgements") as Array).size()).is_equal(1)
	assert_bool(_stream.activate()).is_true()
	assert_int(_view.get_child_count()).is_equal(1)
	var subscriptions: Array = _backend.get("subscriptions")
	assert_int(subscriptions.size()).is_equal(1)
	if subscriptions.is_empty():
		return
	assert_array(subscriptions[0].keys).is_equal([Vector3i(-1, 0, 0)])


func test_changed_round_discards_partial_resources_before_reading_new_pages() -> void:
	assert_bool(_stream.request(1, 0, [Vector3i(-1, 0, 0)])).is_true()
	_stream.pump()
	var info: Dictionary = StaticTests._info(2, 2)
	_backend.set("info", info)
	var pages: Array[Dictionary] = [StaticTests._page(2, 0, 2), StaticTests._page(2, 1, 2)]
	_backend.set("pages", pages)
	_stream.pump()
	assert_int(_stream.state().page_index).is_equal(1)
	assert_bool(_stream.state().prepared).is_false()
	assert_array(_backend.get("reads")).is_equal([0, 0])
	_stream.pump()
	assert_bool(_stream.confirm_prepared()).is_true()
	assert_bool(_stream.activate()).is_true()
	var acknowledgements: Array = _backend.get("acknowledgements")
	assert_int(acknowledgements.size()).is_equal(1)
	if acknowledgements.is_empty():
		return
	assert_int(acknowledgements[0].snapshot).is_equal(2)


func test_invalidation_between_preparation_and_ack_preserves_old_root_and_restarts() -> void:
	assert_bool(_stream.request(1, 0, [Vector3i(-1, 0, 0)])).is_true()
	_stream.pump()
	_stream.pump()
	assert_bool(_stream.confirm_prepared()).is_true()
	assert_bool(_stream.activate()).is_true()
	if _view.get_child_count() == 0:
		return
	var old_id: int = _view.get_child(0).get_instance_id()
	assert_bool(_stream.request(1, 0, [Vector3i(-1, 0, 0)])).is_true()
	_stream.pump()
	_stream.pump()
	var info: Dictionary = StaticTests._info(2, 2)
	info["view_generation"] = 2
	info["stage"] = "building"
	_backend.set("info", info)
	assert_bool(_stream.confirm_prepared()).is_false()
	assert_bool(_stream.activate()).is_false()
	assert_int(_view.get_child(0).get_instance_id()).is_equal(old_id)
	info["stage"] = "aborted"
	_backend.set("info", info)
	_stream.pump()
	assert_int(_stream.state().generation).is_equal(3)
	_stream.close()
	assert_bool(_backend.get("unsubscribed")).is_true()
	assert_int(_view.get_child(0).get_instance_id()).is_equal(old_id)


func test_close_retires_accepted_generation_when_new_subscription_was_busy() -> void:
	assert_bool(_stream.request(1, 0, [Vector3i(-1, 0, 0)])).is_true()
	_stream.pump()
	_stream.pump()
	assert_bool(_stream.confirm_prepared()).is_true()
	assert_bool(_stream.activate()).is_true()
	assert_bool(_stream.request(1, 0, [Vector3i(-1, 0, 0)])).is_true()
	_backend.set("busy", true)
	_stream.pump()
	assert_int(_stream.state().generation).is_equal(2)
	assert_int(_backend.get("accepted_generation")).is_equal(1)
	_stream.close()
	assert_bool(_backend.get("unsubscribed")).is_true()
	assert_bool(_stream.state().closed).is_true()
	assert_str(_stream.state().error).is_empty()
	var attempts: Array = _backend.get("unsubscribe_attempts")
	assert_int(attempts.size()).is_equal(1)
	if not attempts.is_empty():
		assert_int(attempts[0].generation).is_equal(1)


func test_candidate_or_epoch_retirement_allows_explicit_fresh_subscription() -> void:
	for error: String in ["not_ready", "stale_epoch"]:
		assert_bool(_stream.request(1, 7, [Vector3i(-1, 0, 0)])).is_true()
		_stream.pump()
		var generation: int = _stream.state().generation
		_backend.set("poll_error", error)
		_stream.pump()
		assert_str(_stream.state().error).is_empty()
		assert_bool(_stream.state().prepared).is_false()
		assert_int(_stream.state().generation).is_equal(generation)
		_backend.set("poll_error", "")
		var epoch: int = 2 if error == "stale_epoch" else 1
		assert_bool(_stream.request(epoch, 0, [Vector3i(-1, 0, 0)])).is_true()
		_stream.pump()
		_stream.pump()
		assert_bool(_stream.confirm_prepared()).is_true()
		assert_bool(_stream.activate()).is_true()
		assert_int(_stream.state().generation).is_equal(1 if epoch == 2 else generation + 1)


func test_epoch_retirement_between_info_and_page_or_ack_allows_fresh_request() -> void:
	var keys: Array[Vector3i] = [Vector3i(-1, 0, 0)]
	for operation: String in ["page", "ack"]:
		_stream.close()
		_stream = FactoryPresentationStream.new(_backend, _view)
		var epoch: int = 1 if operation == "page" else 2
		assert_bool(_stream.request(epoch, 0, keys)).is_true()
		if operation == "page":
			_backend.set("page_error", "stale_epoch")
			_stream.pump()
			_backend.set("page_error", "")
		else:
			_stream.pump()
			_stream.pump()
			_backend.set("ack_error", "stale_epoch")
			assert_bool(_stream.confirm_prepared()).is_false()
			_backend.set("ack_error", "")
		assert_str(_stream.state().error).is_empty()
		assert_bool(_stream.state().prepared).is_false()
		assert_bool(_stream.request(epoch + 1, 0, keys)).is_true()
		_stream.pump()
		_stream.pump()
		assert_bool(_stream.confirm_prepared()).is_true()
		assert_bool(_stream.activate()).is_true()
