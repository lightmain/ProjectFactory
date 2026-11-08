extends GdUnitTestSuite


func test_sample_capacity_stops_without_claiming_a_complete_window() -> void:
	var snapshot: SessionSnapshot = PressureSaveBuilder.new().build(8, 6)
	var report: Dictionary = PressureBenchmark.measure(snapshot, 2, 30.0, 5.0, 2)
	assert_bool(report.get("complete", true)).is_false()
	assert_bool(report.get("capacity_exhausted", false)).is_true()
	assert_bool(report.get("timed_out", true)).is_false()
	assert_int(report.get("logic_ticks", -1)).is_equal(2)
	var samples: Array = report.get("tick_ms", [])
	assert_int(samples.size()).is_equal(2)


func test_summary_reports_nearest_rank_p95_and_keeps_input_order() -> void:
	var samples: Array[float] = [10.0, 1.0, 3.0, 2.0]
	var summary: Dictionary = PressureBenchmark.summarize(samples)
	assert_float(summary.get("median_ms", -1.0)).is_equal(2.5)
	assert_float(summary.get("p95_ms", -1.0)).is_equal(10.0)
	assert_float(summary.get("max_ms", -1.0)).is_equal(10.0)
	assert_int(summary.get("samples", -1)).is_equal(4)
	assert_array(samples).contains_exactly([10.0, 1.0, 3.0, 2.0])
	var empty: Array[float] = []
	assert_bool(PressureBenchmark.summarize(empty).is_empty()).is_true()


func test_measured_tick_and_display_sampling_match_unmeasured_evolution() -> void:
	var builder: PressureSaveBuilder = PressureSaveBuilder.new()
	var snapshot: SessionSnapshot = builder.build(8, 6)
	var reference: SessionSnapshot = SessionSnapshot.decode(PressureSaveBuilder.state_for(snapshot))
	var report: Dictionary = PressureBenchmark.measure(snapshot, 3, 0.0, 5.0)
	for tick: int in range(3):
		reference.logistics.advance(LogisticsData.LOGIC_STEP)
	assert_bool(snapshot.logistics.save_state() == reference.logistics.save_state()).is_true()
	assert_int(report.get("logic_ticks", -1)).is_equal(3)
	assert_int(report.get("display_samples", -1)).is_equal(3)
	assert_bool(report.get("complete", false)).is_true()
	var tick: Dictionary = report.get("tick", {})
	var display: Dictionary = report.get("display", {})
	assert_int(tick.get("samples", -1)).is_equal(3)
	assert_int(display.get("samples", -1)).is_equal(3)
	var work: Dictionary = report.get("work", {})
	assert_int(work.get("batches", -1)).is_equal(3)
	assert_int(work.get("advance", -1)).is_greater(0)
	assert_int(work.get("sample", -1)).is_greater(0)
	assert_int(work.get("copied_rows", -1)).is_equal(3 * 257)
	assert_int(work.get("sample_solves", -1)).is_equal(3)
	assert_int(work.get("cache_rows_peak", -1)).is_equal(257)


func test_timeout_records_missing_samples_instead_of_claiming_completion() -> void:
	var snapshot: SessionSnapshot = PressureSaveBuilder.new().build(8, 6)
	var report: Dictionary = PressureBenchmark.measure(snapshot, 120, 30.0, 0.0)
	assert_bool(report.get("complete", true)).is_false()
	assert_bool(report.get("timed_out", false)).is_true()
	assert_int(report.get("logic_ticks", -1)).is_equal(0)
	assert_int(report.get("missing_samples", -1)).is_equal(120)
	assert_int(snapshot.logistics.logic_tick()).is_equal(0)
