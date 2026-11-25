use std::{
    fs,
    io::Write,
    process::{Command, Stdio},
};

#[test]
fn separate_processes_generate_load_edit_and_audit_without_overwriting() {
    let path = std::env::temp_dir().join(format!("factory-world-cli-{}.world", std::process::id()));
    let binary = env!("CARGO_BIN_EXE_factory_world_probe");
    let generated = Command::new(binary)
        .args(["generate", "--size", "32,16,32", "--output"])
        .arg(&path)
        .output()
        .unwrap();
    assert!(generated.status.success(), "{:?}", generated);
    assert!(String::from_utf8_lossy(&generated.stdout).contains("\"population\":16384"));
    assert!(
        !Command::new(binary)
            .args(["generate", "--size", "32,16,32", "--output"])
            .arg(&path)
            .output()
            .unwrap()
            .status
            .success()
    );
    let mut child = Command::new(binary)
        .args(["probe", "--input"])
        .arg(&path)
        .args(["--warmup", "2", "--samples", "20"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"continue\n")
        .unwrap();
    let result = child.wait_with_output().unwrap();
    fs::remove_file(&path).unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let output = String::from_utf8(result.stdout).unwrap();
    assert!(output.contains("\"stage\":\"loaded\""));
    assert!(output.contains("\"stage\":\"edited\""));
    assert!(output.contains("\"audit\":true"));
    assert!(output.contains("\"modifications\":20"));
    assert!(output.contains("\"moving\":null"));
    assert!(!output.contains("\"stage\":\"load_only\""));
}

#[test]
fn cli_rejects_unknown_duplicate_or_unbounded_workloads() {
    let binary = env!("CARGO_BIN_EXE_factory_world_probe");
    for arguments in [
        vec![
            "generate",
            "--size",
            "16,16,16",
            "--output",
            "unused.world",
            "--unknown",
            "1",
        ],
        vec![
            "probe",
            "--input",
            "missing.world",
            "--samples",
            "1000000000",
        ],
        vec![
            "generate",
            "--size",
            "16,16,16",
            "--size",
            "32,16,32",
            "--output",
            "unused.world",
        ],
    ] {
        assert!(
            !Command::new(binary)
                .args(arguments)
                .output()
                .unwrap()
                .status
                .success()
        );
    }
}
