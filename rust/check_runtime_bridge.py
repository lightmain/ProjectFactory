#!/usr/bin/env python3
"""Build and exercise the actual runtime bridge in a fresh isolated project."""
import os
from pathlib import Path
import shutil
import tempfile

from verify import ROOT, run


def main():
    logs = Path(tempfile.mkdtemp(prefix="factory-runtime-bridge-"))
    project = logs / "project"
    project.mkdir()
    (project / "project.godot").write_text(
        '[application]\nconfig/name="Factory runtime bridge"\n'
        '[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
    shutil.copy2(ROOT / "rust/tests/runtime.gd", project / "runtime.gd")
    environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    engine = environment.get("GODOT_BIN", "godot")
    print(f"Runtime bridge logs: {logs}", flush=True)
    run(["bash", str(ROOT / "rust/install.sh"), str(project), "debug"],
        "install", logs, environment)
    for name, arguments in [
        ("editor", ["--editor", "--quit-after", "120", "--max-fps", "60"]),
        ("import", ["--import"]),
        ("runtime", ["-s", "res://runtime.gd", "--quit-after", "600"]),
    ]:
        run([engine, "--headless", "--disable-crash-handler", "--path", str(project), *arguments],
            name, logs, environment,
            marker="FACTORY_RUNTIME_BRIDGE_PASS" if name == "runtime" else None,
            timeout=30)
    print("FACTORY_RUNTIME_BRIDGE_CHECK_PASS", flush=True)


if __name__ == "__main__":
    main()
