extends "res://tests/helpers/fake_runtime_backend.gd"

const PresentationFake: Script = preload("res://tests/helpers/fake_presentation_backend.gd")
var presentation: RefCounted = PresentationFake.new()
var candidate: Dictionary = {}


func poll_candidate_runtime(_epoch: int, _job: int, _bytes: int) -> Dictionary:
	return candidate.duplicate(true)


func subscribe_presentation_runtime(origin: int, generation: int, job: int,
		keys: Array[Vector3i]) -> Dictionary:
	return presentation.call("subscribe_presentation_runtime", origin, generation, job, keys)


func poll_presentation_runtime(origin: int) -> Dictionary:
	return presentation.call("poll_presentation_runtime", origin)


func poll_presentation_page_runtime(origin: int, generation: int, snapshot: int,
		index: int, bytes: int) -> Dictionary:
	return presentation.call("poll_presentation_page_runtime", origin, generation, snapshot, index, bytes)


func ack_presentation_runtime(origin: int, generation: int, snapshot: int) -> Dictionary:
	return presentation.call("ack_presentation_runtime", origin, generation, snapshot)


func unsubscribe_presentation_runtime(origin: int, generation: int) -> Dictionary:
	return presentation.call("unsubscribe_presentation_runtime", origin, generation)
