//! Build-time identity shared by the CLI and native bridge.
pub struct BuildInfo {
    pub package_version: &'static str,
    pub inputs_sha256: &'static str,
    pub lock_sha256: &'static str,
    pub commit: &'static str,
    pub dirty: bool,
    pub target: &'static str,
    pub profile: &'static str,
    pub rustc: &'static str,
    pub cargo: &'static str,
    pub opt_level: &'static str,
    pub debug_info: &'static str,
    pub debug_assertions: bool,
    pub target_features: &'static str,
    pub rustflags_sha256: &'static str,
    pub rustflags_utf8_hex: &'static str,
}

pub const BUILD_INFO: BuildInfo = BuildInfo {
    package_version: env!("CARGO_PKG_VERSION"),
    inputs_sha256: env!("FACTORY_INPUTS_SHA256"),
    lock_sha256: env!("FACTORY_LOCK_SHA256"),
    commit: env!("FACTORY_COMMIT"),
    dirty: matches!(env!("FACTORY_DIRTY").as_bytes(), b"true"),
    target: env!("TARGET_IDENTITY"),
    profile: env!("PROFILE_IDENTITY"),
    rustc: env!("RUSTC_IDENTITY"),
    cargo: env!("CARGO_IDENTITY"),
    opt_level: env!("OPT_LEVEL_IDENTITY"),
    debug_info: env!("DEBUG_IDENTITY"),
    debug_assertions: cfg!(debug_assertions),
    target_features: env!("CARGO_CFG_TARGET_FEATURE_IDENTITY"),
    rustflags_sha256: env!("FACTORY_RUSTFLAGS_SHA256"),
    rustflags_utf8_hex: env!("FACTORY_RUSTFLAGS_UTF8_HEX"),
};

impl BuildInfo {
    pub fn to_json(&self) -> String {
        // These fields are hashes, Git IDs and compiler/platform identifiers.
        // Escape strings nevertheless so a custom toolchain remains valid JSON.
        fn quoted(value: &str) -> String {
            let mut text = String::from("\"");
            for character in value.chars() {
                match character {
                    '"' => text.push_str("\\\""),
                    '\\' => text.push_str("\\\\"),
                    '\n' => text.push_str("\\n"),
                    '\r' => text.push_str("\\r"),
                    '\t' => text.push_str("\\t"),
                    character if character.is_control() => {
                        use std::fmt::Write;
                        write!(text, "\\u{:04x}", character as u32).unwrap();
                    }
                    character => text.push(character),
                }
            }
            text.push('"');
            text
        }
        format!(
            "{{\"package_version\":{},\"inputs_sha256\":{},\"lock_sha256\":{},\"commit\":{},\"dirty\":{},\"target\":{},\"profile\":{},\"rustc\":{},\"cargo\":{},\"opt_level\":{},\"debug_info\":{},\"debug_assertions\":{},\"target_features\":{},\"rustflags_sha256\":{},\"rustflags_utf8_hex\":{}}}",
            quoted(self.package_version),
            quoted(self.inputs_sha256),
            quoted(self.lock_sha256),
            quoted(self.commit),
            self.dirty,
            quoted(self.target),
            quoted(self.profile),
            quoted(self.rustc),
            quoted(self.cargo),
            quoted(self.opt_level),
            quoted(self.debug_info),
            self.debug_assertions,
            quoted(self.target_features),
            quoted(self.rustflags_sha256),
            quoted(self.rustflags_utf8_hex),
        )
    }
}
