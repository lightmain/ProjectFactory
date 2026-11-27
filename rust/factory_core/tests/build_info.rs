use factory_core::build_info::BUILD_INFO;

#[test]
fn build_identity_contains_no_local_paths_and_is_bound_to_the_inputs() {
    assert_eq!(BUILD_INFO.package_version, "0.1.0");
    assert_eq!(BUILD_INFO.inputs_sha256.len(), 64);
    assert!(
        BUILD_INFO
            .inputs_sha256
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
    );
    assert!(!BUILD_INFO.target.is_empty());
    assert!(!BUILD_INFO.profile.is_empty());
    assert!(!BUILD_INFO.rustc.is_empty());
    assert!(!BUILD_INFO.commit.is_empty());
    assert_eq!(BUILD_INFO.lock_sha256.len(), 64);
    for value in [
        BUILD_INFO.inputs_sha256,
        BUILD_INFO.commit,
        BUILD_INFO.target,
        BUILD_INFO.profile,
        BUILD_INFO.rustc,
    ] {
        assert!(!value.contains("/Users/"));
        assert!(!value.contains("\\Users\\"));
    }
}
