use std::{env, path::Path, process::Command};

fn main() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap();
    // Also refresh Git's dirty/commit identity after changes outside Rust.
    println!("cargo:rerun-if-changed={}", root.display());
    let conveyor = root
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("RustConveyor");
    println!("cargo:rerun-if-changed={}", conveyor.join("src").display());
    println!(
        "cargo:rerun-if-changed={}",
        conveyor.join("Cargo.toml").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        conveyor.join("Cargo.lock").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        conveyor.join("LICENSE").display()
    );
    println!("cargo:rerun-if-env-changed=RUSTC");
    let identity = Command::new("python3")
        .arg(root.join("rust/build.py"))
        .arg("--identity-env")
        .output()
        .expect("Python 3 is required to fingerprint build inputs");
    assert!(
        identity.status.success(),
        "Build identity failed: {}",
        String::from_utf8_lossy(&identity.stderr)
    );
    for field in String::from_utf8(identity.stdout).unwrap().lines() {
        println!("cargo:rustc-env={field}");
    }
    for key in [
        "TARGET",
        "PROFILE",
        "OPT_LEVEL",
        "DEBUG",
        "CARGO_CFG_TARGET_FEATURE",
    ] {
        println!("cargo:rustc-env={key}_IDENTITY={}", env::var(key).unwrap());
    }
    let rustc = Command::new(env::var_os("RUSTC").unwrap())
        .arg("-vV")
        .output()
        .expect("Cannot identify rustc");
    assert!(rustc.status.success(), "Cannot identify rustc");
    println!(
        "cargo:rustc-env=RUSTC_IDENTITY={}",
        String::from_utf8(rustc.stdout)
            .unwrap()
            .trim()
            .replace('\n', " | ")
    );
    let cargo = Command::new(env::var_os("CARGO").unwrap())
        .arg("--version")
        .output()
        .expect("Cannot identify Cargo");
    assert!(cargo.status.success(), "Cannot identify Cargo");
    println!(
        "cargo:rustc-env=CARGO_IDENTITY={}",
        String::from_utf8(cargo.stdout).unwrap().trim()
    );
}
