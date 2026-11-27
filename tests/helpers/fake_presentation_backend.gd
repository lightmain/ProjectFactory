extends RefCounted

var busy: bool = false
var ack_busy: bool = false
var poll_error: String = ""
var page_error: String = ""
var ack_error: String = ""
var accepted_epoch: int = 0
var accepted_generation: int = 0
var info: Dictionary = {}
var pages: Array[Dictionary] = []
var subscriptions: Array[Dictionary] = []
var reads: Array[int] = []
var acknowledgements: Array[Dictionary] = []
var unsubscribed: bool = false
var unsubscribe_attempts: Array[Dictionary] = []


func subscribe_presentation_runtime(epoch: int, generation: int, job: int,
		keys: Array[Vector3i]) -> Dictionary:
	if busy:
		return {"ok": false, "error": "busy"}
	subscriptions.append({"epoch": epoch, "generation": generation, "job": job, "keys": keys.duplicate()})
	accepted_epoch = epoch
	accepted_generation = generation
	info["world_epoch"] = epoch
	info["job_id"] = job
	info["view_generation"] = generation
	for page: Dictionary in pages:
		page["view_generation"] = generation
		page["world_epoch"] = epoch
		page["job_id"] = job
	return {"ok": true}


func poll_presentation_runtime(_epoch: int) -> Dictionary:
	if not poll_error.is_empty():
		return {"ok": false, "error": poll_error}
	if busy:
		return {"ok": false, "error": "busy"}
	return info.duplicate(true)


func poll_presentation_page_runtime(_epoch: int, _generation: int, _snapshot: int,
		index: int, _bytes: int) -> Dictionary:
	if not page_error.is_empty():
		return {"ok": false, "error": page_error}
	if busy:
		return {"ok": false, "error": "busy"}
	reads.append(index)
	return pages[index].duplicate(true)


func ack_presentation_runtime(epoch: int, generation: int, snapshot: int) -> Dictionary:
	if not ack_error.is_empty():
		return {"ok": false, "error": ack_error}
	if ack_busy:
		return {"ok": false, "error": "busy"}
	acknowledgements.append({"epoch": epoch, "generation": generation, "snapshot": snapshot})
	return {"ok": true}


func unsubscribe_presentation_runtime(epoch: int, generation: int) -> Dictionary:
	unsubscribe_attempts.append({"epoch": epoch, "generation": generation})
	if epoch != accepted_epoch or generation != accepted_generation:
		return {"ok": false, "error": "invalid_argument"}
	unsubscribed = true
	return {"ok": true}
