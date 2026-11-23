#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)"
OUTPUT="${1:?Usage: bash scripts/run_native_pressure.sh NEW_OUTPUT [rust|gdscript] [headless|window] [all|1k|10k|100k|million] [fixed|small_translation]}"
BACKEND="${2:-rust}"
DISPLAY_MODE="${3:-headless}"
SELECTED_CASE="${4:-all}"
CAMERA_TRACK="${5:-fixed}"
GODOT_BIN="${GODOT_BIN:-godot}"
[[ "$BACKEND" == rust || "$BACKEND" == gdscript ]]
[[ "$DISPLAY_MODE" == headless || "$DISPLAY_MODE" == window ]]
[[ "$CAMERA_TRACK" == fixed || "$CAMERA_TRACK" == small_translation ]]
if [[ -e "$OUTPUT" ]]; then
  echo "Output already exists: $OUTPUT" >&2
  exit 2
fi
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
DISPLAY_ARGS=()
[[ "$DISPLAY_MODE" != headless ]] || DISPLAY_ARGS=(--headless)
TIME_ARGS=(-v)
[[ "$(uname -s)" != Darwin ]] || TIME_ARGS=(-l)
CASES=(1k:16:6 10k:32:12 100k:64:27 million:128:64)
if [[ "$SELECTED_CASE" != all ]]; then
  case "$SELECTED_CASE" in
    1k) CASES=(1k:16:6) ;;
    10k) CASES=(10k:32:12) ;;
    100k) CASES=(100k:64:27) ;;
    million) CASES=(million:128:64) ;;
    *) echo "Unknown case: $SELECTED_CASE" >&2; exit 2 ;;
  esac
fi
INVOCATIONS="$(python3 -c 'import json,sys; engine,root,out,backend,display,track,*cases=sys.argv[1:]; print(json.dumps([[engine]+(["--headless"] if display=="headless" else [])+["--path",root,"-s","res://scripts/pressure_native_benchmark.gd","--",*case.split(":")[1:],out+"/"+case.split(":")[0],"300","120",backend,out+"/provenance.json",track] for case in cases]))' \
  "$GODOT_BIN" "$PROJECT_ROOT" "$OUTPUT" "$BACKEND" "$DISPLAY_MODE" "$CAMERA_TRACK" "${CASES[@]}")"
python3 "$PROJECT_ROOT/scripts/native_pressure_provenance.py" "$OUTPUT/provenance.json" "$INVOCATIONS"

# Each process finishes before the next starts; never benchmark concurrently.
for CASE in "${CASES[@]}"; do
  IFS=: read -r LABEL SIZE HEIGHT <<< "$CASE"
  LOG="$OUTPUT/$LABEL.log"
  echo "Measuring $LABEL ($BACKEND, $DISPLAY_MODE)"
  # macOS Bash 3.2 treats an empty array as unset with nounset enabled.
  /usr/bin/time "${TIME_ARGS[@]}" "$GODOT_BIN" ${DISPLAY_ARGS[@]+"${DISPLAY_ARGS[@]}"} \
    --path "$PROJECT_ROOT" -s res://scripts/pressure_native_benchmark.gd \
    -- "$SIZE" "$HEIGHT" "$OUTPUT/$LABEL" 300 120 "$BACKEND" "$OUTPUT/provenance.json" "$CAMERA_TRACK" > "$LOG" 2>&1
  if grep -Eq 'SCRIPT ERROR:|ERROR:' "$LOG" || ! grep -q '^NATIVE_PRESSURE_RESULT ' "$LOG"; then
    echo "Measurement failed; inspect $LOG" >&2
    exit 1
  fi
  python3 "$PROJECT_ROOT/scripts/check_native_pressure_report.py" "$OUTPUT/$LABEL"
  echo "Completed $LABEL: $OUTPUT/$LABEL/performance.json"
done
