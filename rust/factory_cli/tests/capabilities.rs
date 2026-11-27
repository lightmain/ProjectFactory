use std::process::Command;

#[test]
fn cli_reports_the_same_honest_capabilities_without_an_engine() {
    let output = Command::new(env!("CARGO_BIN_EXE_factory_cli"))
        .arg("capabilities")
        .output()
        .unwrap();
    assert!(output.status.success());
    let text = String::from_utf8(output.stdout).unwrap();
    assert_eq!(
        text.trim(),
        r#"{"api_version":1,"features":["handshake","synchronous_factory","checkpoint_jobs"],"rulesets":["legacy_discrete_v1","conveyor_continuous_v1"],"background":false,"persistence":true}"#
    );
}

#[test]
fn cli_rejects_unimplemented_operations_and_extra_arguments() {
    for args in [
        vec![],
        vec!["capabilities", "unexpected"],
        vec!["generate"],
        vec!["check-save"],
        vec!["import-legacy"],
        vec!["benchmark"],
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_factory_cli"))
            .args(args)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(2));
        assert!(output.stdout.is_empty());
        assert!(
            String::from_utf8(output.stderr)
                .unwrap()
                .contains("Usage: factory_cli capabilities")
        );
    }
}
