#!/usr/bin/env python3
"""Copy working resources without sharing generated editor state."""

from pathlib import Path
import shutil
import sys


def copy_project(source: Path, destination: Path) -> None:
    shutil.copytree(
        source, destination,
        ignore=shutil.ignore_patterns(
            ".git", ".godot", ".trae", ".vscode", ".venv", ".tmp",
            "__pycache__", ".pytest_cache", ".DS_Store",
            "reports", "build", "android", "*.pyc", "*.pyo",
            ".env", ".env.*", "*.log", "*.tmp", "*.bak", "*~",
            "export.cfg", "export_credentials.cfg",
        ),
        dirs_exist_ok=True,
    )


if __name__ == "__main__":
    copy_project(Path(sys.argv[1]), Path(sys.argv[2]))
