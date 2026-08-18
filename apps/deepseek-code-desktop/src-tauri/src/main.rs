use serde::Serialize;
use tauri_plugin_shell::ShellExt;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeStatus { ready: bool, version: String, detail: Option<String> }

#[tauri::command]
async fn runtime_status(app: tauri::AppHandle) -> RuntimeStatus {
    let command = match app.shell().sidecar("deepseek-agent-runtime") {
        Ok(command) => command.arg("health"),
        Err(error) => return RuntimeStatus { ready: false, version: "unavailable".into(), detail: Some(error.to_string()) },
    };
    match command.output().await {
        Ok(output) if output.status.success() => RuntimeStatus { ready: true, version: String::from_utf8_lossy(&output.stdout).trim().to_string(), detail: None },
        Ok(output) => RuntimeStatus { ready: false, version: "unavailable".into(), detail: Some(String::from_utf8_lossy(&output.stderr).trim().to_string()) },
        Err(error) => RuntimeStatus { ready: false, version: "unavailable".into(), detail: Some(error.to_string()) },
    }
}

fn main() { tauri::Builder::default().plugin(tauri_plugin_shell::init()).invoke_handler(tauri::generate_handler![runtime_status]).run(tauri::generate_context!()).expect("failed to run DeepSeek Code desktop application") }
