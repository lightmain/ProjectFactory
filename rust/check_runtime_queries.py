#!/usr/bin/env python3
"""Verify the bounded query bridge without replacing a loaded native library."""
import os
from pathlib import Path
import shutil
import tempfile

from verify import ROOT, run


def main():
    logs = Path(tempfile.mkdtemp(prefix="factory-runtime-queries-"))
    project = logs / "project"
    project.mkdir()
    (project / "project.godot").write_text(
        '[application]\nconfig/name="Factory runtime queries"\n'
        '[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
    shutil.copy2(ROOT / "rust/tests/runtime_queries.gd", project / "runtime_queries.gd")
    environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    engine = environment.get("GODOT_BIN", "godot")
    print(f"Runtime query logs: {logs}", flush=True)
    run(["bash", str(ROOT / "rust/install.sh"), str(project), "debug"],
        "install", logs, environment)
    # Match the established first-use startup contract for native extensions.
    run([engine, "--headless", "--disable-crash-handler", "--path", str(project),
         "--editor", "--quit-after", "120", "--max-fps", "60"],
        "editor", logs, environment, timeout=30)
    run([engine, "--headless", "--disable-crash-handler", "--path", str(project), "--import"],
        "import", logs, environment, timeout=30)
    run([engine, "--headless", "--disable-crash-handler", "--path", str(project),
         "-s", "res://runtime_queries.gd", "--quit-after", "600"],
        "queries", logs, environment, marker="FACTORY_RUNTIME_QUERIES_PASS", timeout=30)
    print("FACTORY_RUNTIME_QUERIES_CHECK_PASS", flush=True)


if __name__ == "__main__":
    main()
