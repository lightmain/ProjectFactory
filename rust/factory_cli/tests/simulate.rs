use std::process::Command;

#[test]
fn cli_runs_both_complete_factory_rulesets_without_godot() {
    for ruleset in ["legacy_discrete_v1", "conveyor_continuous_v1"] {
        let output = Command::new(env!("CARGO_BIN_EXE_factory_cli"))
            .args(["simulate", ruleset, "300"])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let text = String::from_utf8(output.stdout).unwrap();
        assert!(text.contains(&format!("\"ruleset\":\"{ruleset}\"")));
        assert!(text.contains("\"tick\":300"));
        assert!(text.contains("\"total\":50"));
        assert!(text.contains("\"produced\":50"));
        let chest = text
            .split("\"chest\":")
            .nth(1)
            .unwrap()
            .split(',')
            .next()
            .unwrap();
        assert!(chest.parse::<i64>().unwrap() > 0);
    }
}
