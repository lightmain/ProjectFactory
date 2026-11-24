"""Required evidence for the declared benchmark mode, independent of gains."""

REQUIRED_STAGES = ("frame", "process_interval", "sample", "submission",
                   "candidate", "decoration", "display_query")
PERCENTILES = ("p50", "p95", "p99", "max", "over_budget")


def evidence_limits(mode, track, metrics, rows, expected_samples):
    required = ["load_seconds", "decode_seconds", "mount_seconds", "steady_rss_bytes",
                "load_peak_rss_bytes", "frame_p95_ms", "interval_p95_ms"]
    reasons = []
    if mode == "generate_save_load":
        required += ["save_seconds", "checkpoint_seconds", "save_peak_rss_bytes"]
    elif mode == "independent_load":
        if track == "fixed":
            required += ["player_save_seconds", "player_save_peak_rss_bytes"]
    else:
        reasons.append("unknown comparison mode: " + mode)
    for name in required:
        metric = metrics.get(name)
        if not isinstance(metric, dict) or len(metric.get("samples", [])) != expected_samples:
            reasons.append("required metric missing independent samples: " + name)
    for stage in REQUIRED_STAGES:
        if any(not isinstance(row.get("stages_ms", {}).get(stage), dict)
               or any(row["stages_ms"][stage].get(field) is None for field in PERCENTILES)
               for row in rows):
            reasons.append("required stage missing: " + stage)
    return reasons
