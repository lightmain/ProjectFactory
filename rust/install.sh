#!/usr/bin/env bash
set -euo pipefail
RUST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${1:?Usage: bash rust/install.sh /path/to/godot/project [debug|release]}"
PROFILE="${2:-release}"
python3 "$RUST_ROOT/build.py" "$PROJECT" "$PROFILE"
