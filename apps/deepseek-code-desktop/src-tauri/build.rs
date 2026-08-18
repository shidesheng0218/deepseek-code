use std::process::Command;

fn main() {
    let git_sha = Command::new("git").args(["rev-parse", "--short=12", "HEAD"]).output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "unknown".into());
    println!("cargo:rustc-env=DEEPSEEK_GIT_SHA={git_sha}");
    println!("cargo:rerun-if-changed=../../.git/HEAD");
    tauri_build::build();
}
