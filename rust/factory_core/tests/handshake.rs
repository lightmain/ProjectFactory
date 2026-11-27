use factory_core::protocol::{API_VERSION, Backend, Error, implemented_capabilities};

#[test]
fn capabilities_advertise_synchronous_factory_with_async_persistence() {
    let capabilities = implemented_capabilities();
    assert_eq!(capabilities.api_version, API_VERSION);
    assert_eq!(
        capabilities.features,
        ["handshake", "synchronous_factory", "checkpoint_jobs"]
    );
    assert_eq!(
        capabilities.rulesets,
        ["legacy_discrete_v1", "conveyor_continuous_v1"]
    );
    assert!(!capabilities.background);
    assert!(capabilities.persistence);
}

#[test]
fn mismatched_protocol_leaves_backend_closed() {
    for version in [0, API_VERSION + 1, u32::MAX] {
        let mut backend = Backend::default();
        assert_eq!(backend.open(version), Err(Error::UnsupportedProtocol));
        assert!(!backend.is_open());
        assert!(backend.open(API_VERSION).is_ok());
    }
}

#[test]
fn duplicate_open_is_rejected_without_closing_the_live_instance() {
    let mut backend = Backend::default();
    backend.open(API_VERSION).unwrap();
    assert_eq!(backend.open(API_VERSION), Err(Error::AlreadyOpen));
    assert!(backend.is_open());
    backend.close();
    assert!(!backend.is_open());
}

#[test]
fn close_is_idempotent_and_allows_a_new_handshake() {
    let mut backend = Backend::default();
    backend.close();
    backend.open(API_VERSION).unwrap();
    backend.close();
    backend.close();
    assert!(!backend.is_open());
    assert_eq!(backend.open(API_VERSION), Ok(implemented_capabilities()));
}
