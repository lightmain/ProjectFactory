class_name PressureBenchmark
extends RefCounted
## Isolated rule timings; never mounted into a live game.


static func summarize(samples: Array[float]) -> Dictionary:
	if samples.is_empty():
		return {}
	var ordered: Array[float] = samples.duplicate()
	ordered.sort()
	var middle: int = ordered.size() / 2
	var median: float = ordered[middle]
	if ordered.size() % 2 == 0:
		median = (ordered[middle - 1] + median) * 0.5
	return {
		"samples": ordered.size(), "median_ms": median,
		"p95_ms": ordered[ceili(float(ordered.size()) * 0.95) - 1],
		"max_ms": ordered[-1],
	}


static func measure(
	snapshot: SessionSnapshot, minimum_samples: int, minimum_seconds: float,
	timeout_seconds: float, maximum_samples: int = 100000
) -> Dictionary:
	if snapshot == null or minimum_samples < 1 or maximum_samples < minimum_samples or (
		not is_finite(minimum_seconds) or minimum_seconds < 0.0
		or not is_finite(timeout_seconds) or timeout_seconds < 0.0
	):
		return {}
	var ticks: Array[float] = []
	var displays: Array[float] = []
	var work: Dictionary[String, int] = {
		"advance": 0, "batches": 0, "sample": 0,
		"copied_rows": 0, "copied_ores": 0,
		"sample_solves": 0, "cache_rows_peak": 0,
	}
	var last_solves: int = snapshot.logistics.work_stats()["sample_solves"]
	var start_tick: int = snapshot.logistics.logic_tick()
	var started: int = Time.get_ticks_usec()
	var observer_usec: int = 0
	var elapsed: float = 0.0
	var timed_out: bool = false
	var capacity_exhausted: bool = false
	while ticks.size() < minimum_samples or elapsed < minimum_seconds:
		if elapsed >= timeout_seconds:
			timed_out = true
			break
		if ticks.size() >= maximum_samples:
			capacity_exhausted = true
			break
		var step_start: int = Time.get_ticks_usec()
		snapshot.logistics.advance(LogisticsData.LOGIC_STEP)
		ticks.append(float(Time.get_ticks_usec() - step_start) / 1000.0)
		step_start = Time.get_ticks_usec()
		var samples: Array[LogisticsOreQueue] = snapshot.logistics.sample_belts(
			LogisticsData.LOGIC_STEP * 0.5
		)
		displays.append(float(Time.get_ticks_usec() - step_start) / 1000.0)
		step_start = Time.get_ticks_usec()
		var stats: Dictionary[String, int] = snapshot.logistics.work_stats()
		work["advance"] += stats["advance"]
		work["batches"] += stats["batches"]
		work["sample"] += stats["sample"]
		work["sample_solves"] += stats["sample_solves"] - last_solves
		last_solves = stats["sample_solves"]
		work["cache_rows_peak"] = maxi(work["cache_rows_peak"], stats["cache_rows"])
		work["copied_rows"] += samples.size()
		for queue: LogisticsOreQueue in samples:
			work["copied_ores"] += queue.ores.size()
		# Release measured result objects before starting the next tick timer.
		samples.clear()
		observer_usec += Time.get_ticks_usec() - step_start
		elapsed = float(Time.get_ticks_usec() - started) / 1000000.0
	var complete: bool = ticks.size() >= minimum_samples and elapsed >= minimum_seconds
	return {
		"tick": summarize(ticks), "display": summarize(displays),
		"tick_ms": ticks, "display_ms": displays, "work": work,
		"logic_ticks": snapshot.logistics.logic_tick() - start_tick,
		"display_samples": displays.size(), "measurement_seconds": elapsed,
		"minimum_samples": minimum_samples, "minimum_seconds": minimum_seconds,
		"timeout_seconds": timeout_seconds, "complete": complete,
		"timed_out": timed_out, "capacity_exhausted": capacity_exhausted,
		"maximum_samples": maximum_samples,
		"missing_samples": maxi(0, minimum_samples - ticks.size()),
		"observer_seconds": float(observer_usec) / 1000000.0,
	}
