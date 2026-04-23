use std::{env, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-changed=embedded-app");
    println!("cargo:rerun-if-env-changed=CARGO_FEATURE_SERVE");

    if env::var_os("CARGO_FEATURE_SERVE").is_none() {
        return;
    }

    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("missing manifest dir"));
    let assets_dir = manifest_dir.join("embedded-app");

    if !assets_dir.join("index.html").exists() {
        panic!(
            "Missing FlowScope web assets at {}.\n\
             Run `just sync-cli-serve-assets` (builds app/dist and copies it\
             into crates/flowscope-cli/embedded-app) before enabling the\
             `serve` feature.",
            assets_dir.display()
        );
    }
}
