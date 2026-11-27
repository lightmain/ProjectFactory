//! Thin GDExtension boundary; no game rules belong here.
use factory_core::{
    build_info::BUILD_INFO,
    protocol::{Backend, Capabilities, Error},
};
use godot::{builtin::VarDictionary, classes::RefCounted, prelude::*};

// gdext's registration ABI is the sole unsafe boundary in this crate.
#[allow(unsafe_code)]
mod registration {
    use godot::prelude::*;
    struct FactoryLibrary;
    #[gdextension]
    unsafe impl ExtensionLibrary for FactoryLibrary {}
}

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct FactoryBackend {
    base: Base<RefCounted>,
    backend: Backend,
    factory: Option<factory_core::factory::Factory>,
    route: Option<factory_core::belt_placement::Builder>,
    persistence: Option<factory_core::persistence::jobs::Service>,
    candidate: Option<(
        u64,
        factory_core::factory::Factory,
        factory_core::persistence::Session,
    )>,
    runtime: Option<factory_core::runtime::Runtime>,
}

#[godot_api]
impl IRefCounted for FactoryBackend {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            backend: Backend::default(),
            factory: None,
            route: None,
            persistence: None,
            candidate: None,
            runtime: None,
        }
    }
}

fn capabilities_dictionary(capabilities: Capabilities) -> VarDictionary {
    let features =
        PackedStringArray::from_iter(capabilities.features.into_iter().map(GString::from));
    let rulesets =
        PackedStringArray::from_iter(capabilities.rulesets.into_iter().map(GString::from));
    vdict! {
        "api_version" => i64::from(capabilities.api_version),
        "features" => &features, "rulesets" => &rulesets,
        "background" => capabilities.background,
        "persistence" => capabilities.persistence,
    }
}

fn build_dictionary() -> VarDictionary {
    vdict! {
        "package_version" => BUILD_INFO.package_version,
        "inputs_sha256" => BUILD_INFO.inputs_sha256,
        "lock_sha256" => BUILD_INFO.lock_sha256,
        "commit" => BUILD_INFO.commit, "dirty" => BUILD_INFO.dirty,
        "target" => BUILD_INFO.target, "profile" => BUILD_INFO.profile,
        "rustc" => BUILD_INFO.rustc,
        "cargo" => BUILD_INFO.cargo, "opt_level" => BUILD_INFO.opt_level,
        "debug_info" => BUILD_INFO.debug_info,
        "debug_assertions" => BUILD_INFO.debug_assertions,
        "target_features" => BUILD_INFO.target_features,
        "rustflags_sha256" => BUILD_INFO.rustflags_sha256,
        "rustflags_utf8_hex" => BUILD_INFO.rustflags_utf8_hex,
    }
}

include!("synchronous.rs");
include!("persistence.rs");
include!("background.rs");
include!("presentation.rs");
