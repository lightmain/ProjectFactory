# PF Verification Execution Environment

Date: 2026-11-23. Scope: execution environment only, for the developer who will
run full verification after the game changes are complete. No game acceptance,
performance, or visual validation is claimed here.

## Findings

- **Important, addressed locally:** importing a disposable project does not
  itself isolate Godot's global editor settings or game `user://` directory.
  These are separate from the project cache isolated by
  [the project copier](../../scripts/verification_project.py).
- The installed executable is `/Applications/Godot.app/Contents/MacOS/Godot`,
  not a file named `Godot4.7.2`. It reports
  `4.7.2.stable.official.ed1daf0bf`; its help identifies an editor build and
  exposes no `--user-data-dir` option.
- `_sc_` beside a standalone executable enables the supported self-contained
  editor mode. It redirects editor data and settings to `editor_data/`, and
  editor cache to `editor_data/cache/`.
- Self-contained mode alone does not redirect macOS game `user://`. The
  macOS data-path implementation derives it from `HOME`. A child-process-only
  `HOME` override is therefore also necessary for this setup.
- No `/tmp/pf*verify*` entries were present when queried. Historical failure
  details were supplied by the requester, not independently recovered.

Sources: [official data-path documentation](https://docs.godotengine.org/en/stable/tutorials/io/data_paths.html#self-contained-mode),
[upstream editor paths](https://github.com/godotengine/godot/blob/master/editor/file_system/editor_paths.cpp),
[upstream macOS paths](https://github.com/godotengine/godot/blob/master/platform/macos/os_macos.mm),
and the installed binary's help and runtime probes. The exact reported commit
was not retrievable from upstream; upstream source is explanatory, not proof
that the installed binary was built from that revision.

## Reversible Local Setup

All executable, wrapper, fixture, data, and log artifacts live under ignored
`.tmp/pf-verification/`. The existing copier excludes `.tmp`, avoiding recursion
and copying the local engine into verification projects.

- `engine/Godot` is a copy of the installed executable, confirmed identical
  with `cmp`. Its dependencies reported by `otool -L` are system libraries
  and frameworks; no engine compilation or bundle modification was needed.
- `engine/_sc_` enables self-contained editor paths.
- `godot.sh` forwards arguments unchanged and uses `exec env` to set `HOME`
  to the local `home/` and `TMPDIR` to the local `tmp/` for Godot only.
  The verifier, Python orchestration, and Git retain their original `HOME`.
  The wrapper refuses to run without the executable or marker.
- No existing verification script, game file, vendored addon, original project
  cache, or global Godot configuration was edited by this investigation.

From the repository root, **only after authorization to run full verification**:

```bash
GODOT_BIN="$PWD/.tmp/pf-verification/godot.sh" TMPDIR="$PWD/.tmp/pf-verification/tmp/" bash scripts/verify.sh
```

This preserves all verification stages and error checks. Full-verification
logs and disposable copies will also stay inside the workspace via `TMPDIR`.
Undo by ceasing to select this wrapper; its entire newly created local directory
can be removed separately without touching the installed engine or original data.
The ignored setup is not distributed by Git.

## Evidence And Limits

- Minimal fixture `--headless --import`: completed, emitted
  `PF_EDITOR_ISOLATION_OK`, with no error-pattern matches. Reported editor
  data, settings, cache, and user-data paths all lie under the local setup.
  Both editor-settings and `user://` writes succeeded; Godot saved
  `engine/editor_data/editor_settings-4.7.tres`.
- A separate `--headless --script res://runtime_probe.gd` process emitted
  `PF_RUNTIME_ISOLATION_OK` and wrote a runtime probe inside local `user://`.
- `TMPDIR="$PWD/.tmp/pf-verification/tmp/" python3 -B scripts/test_verify.py`:
  all five existing regression tests passed, without modifying their expectations.
- Bash syntax validation passed for the wrapper and existing verifier.
- Full PF verification was deliberately not run. Game parsing, extension loading,
  all GdUnit4 tests, actual startup, and original-editor cache validity remain
  unverified for the in-progress game changes.
- This validation agent is independent of the game implementation. A separate
  subagent facility was unavailable; the newly authored local wrapper has not
  received a second-agent review. These probes do not substitute for that review
  or for full game verification.
