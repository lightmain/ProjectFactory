#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)"
GODOT_BIN="${GODOT_BIN:-godot}"
if ! command -v "$GODOT_BIN" >/dev/null 2>&1; then
  if [[ -x /Applications/Godot.app/Contents/MacOS/Godot ]]; then
    GODOT_BIN=/Applications/Godot.app/Contents/MacOS/Godot
  else
    echo "请设置 GODOT_BIN，指向 Godot 4.7.2 可执行文件。" >&2
    exit 1
  fi
fi

VERSION="$("$GODOT_BIN" --version)"
if [[ "$VERSION" != 4.7.2.* ]]; then
  echo "需要 Godot 4.7.2，当前为 $VERSION" >&2
  exit 1
fi

for plugin in godot_ai gdUnit4; do
  test -f "$PROJECT_ROOT/addons/$plugin/plugin.cfg"
done
grep -q 'version="4.2.3"' "$PROJECT_ROOT/addons/godot_ai/plugin.cfg"
grep -q 'version="6.2.1"' "$PROJECT_ROOT/addons/gdUnit4/plugin.cfg"

CHECK_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/project-factory-check.XXXXXX")"
echo "验证日志：$CHECK_LOG_DIR"

run_checked() {
  local step_name="$1"
  shift
  local output="$CHECK_LOG_DIR/$step_name.log"
  echo "正在执行：$step_name"
  "$GODOT_BIN" --headless --path "$PROJECT_ROOT" "$@" 2>&1 | tee "$output"
  # Godot can return 0 even after parse/load/runtime errors.
  if grep -Eq '(^|[[:space:]])(SCRIPT ERROR:|ERROR:|Shader compilation failed|Script check failed:)' "$output"; then
    echo "$step_name 发现 Godot 错误，详见 $output" >&2
    return 1
  fi
}

run_checked import --import
echo "正在执行：type_safety"
python3 "$PROJECT_ROOT/scripts/check_types.py" "$GODOT_BIN" 2>&1 | tee "$CHECK_LOG_DIR/type_safety.log"
run_checked tests -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd \
  --ignoreHeadlessMode -a res://tests -rd user://project-factory-test-reports
run_checked main_scene --quit-after 120
git -C "$PROJECT_ROOT" diff --check
echo "项目验证通过：导入、类型检查、全部测试、主场景运行、diff 检查。"
