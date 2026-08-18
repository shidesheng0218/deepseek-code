use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use std::process::Command as StdCommand;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, State};
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeStatus { ready: bool, version: String, detail: Option<String> }

#[derive(Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct RuntimeSettings {
    base_url: String,
    model: String,
    project_path: String,
    #[serde(skip_serializing)]
    api_key: String,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentRequest {
    session_id: String,
    project_path: String,
    prompt: String,
    base_url: String,
    api_key: String,
    model: String,
    mode: String,
}

struct RuntimeProcess(Arc<Mutex<Option<CommandChild>>>);

fn settings_path() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    home.join("Library/Application Support/DeepSeekCode/settings.json")
}

fn keychain_service() -> &'static str { "com.deepseekcode.desktop.api-key" }

fn read_keychain() -> String {
    StdCommand::new("security")
        .args(["find-generic-password", "-a", "DeepSeek Code", "-s", keychain_service(), "-w"])
        .output().ok().filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string()).unwrap_or_default()
}

fn write_keychain(api_key: &str) -> Result<(), String> {
    if api_key.trim().is_empty() { return Ok(()); }
    let output = StdCommand::new("security")
        .args(["add-generic-password", "-U", "-a", "DeepSeek Code", "-s", keychain_service(), "-w", api_key])
        .output().map_err(|error| error.to_string())?;
    if output.status.success() { Ok(()) } else { Err(String::from_utf8_lossy(&output.stderr).trim().to_string()) }
}

#[tauri::command]
async fn runtime_status(app: AppHandle) -> RuntimeStatus {
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

#[tauri::command]
fn load_settings() -> Result<RuntimeSettings, String> {
    let path = settings_path();
    let mut settings = if path.exists() {
        serde_json::from_slice::<RuntimeSettings>(&fs::read(&path).map_err(|error| error.to_string())?).unwrap_or_default()
    } else { RuntimeSettings::default() };
    settings.api_key = read_keychain();
    Ok(settings)
}

#[tauri::command]
fn save_settings(mut settings: RuntimeSettings) -> Result<(), String> {
    let path = settings_path();
    if let Some(parent) = path.parent() { fs::create_dir_all(parent).map_err(|error| error.to_string())?; }
    write_keychain(&settings.api_key)?;
    settings.api_key.clear();
    fs::write(path, serde_json::to_vec_pretty(&settings).map_err(|error| error.to_string())?).map_err(|error| error.to_string())
}

fn ensure_runtime(app: &AppHandle, state: &RuntimeProcess) -> Result<(), String> {
    let mut process = state.0.lock().map_err(|_| "runtime lock poisoned".to_string())?;
    if process.is_some() { return Ok(()); }
    let (mut events, child) = app.shell().sidecar("deepseek-agent-runtime")
        .map_err(|error| error.to_string())?.arg("--stdio").spawn().map_err(|error| error.to_string())?;
    let handle = app.clone();
    let runtime_state = state.0.clone();
    tauri::async_runtime::spawn(async move {
        while let Some(event) = events.recv().await {
            match event {
                CommandEvent::Stdout(bytes) => {
                    for line in String::from_utf8_lossy(&bytes).lines().filter(|line| !line.trim().is_empty()) {
                        if let Ok(value) = serde_json::from_str::<serde_json::Value>(line) { let _ = handle.emit("runtime-event", value); }
                    }
                }
                CommandEvent::Stderr(bytes) => { let _ = handle.emit("runtime-error", String::from_utf8_lossy(&bytes).to_string()); }
                CommandEvent::Error(error) => { let _ = handle.emit("runtime-error", error); }
                CommandEvent::Terminated(payload) => {
                    let _ = handle.emit("runtime-terminated", payload);
                    if let Ok(mut guard) = runtime_state.lock() { *guard = None; }
                    break;
                }
                _ => {}
            }
        }
    });
    *process = Some(child);
    Ok(())
}

#[tauri::command]
fn run_agent(app: AppHandle, state: State<'_, RuntimeProcess>, request: AgentRequest) -> Result<(), String> {
    if request.session_id.trim().is_empty() || request.project_path.trim().is_empty() || request.prompt.trim().is_empty() { return Err("sessionId、projectPath 和 prompt 不能为空".into()); }
    if request.base_url.trim().is_empty() || request.api_key.trim().is_empty() || request.model.trim().is_empty() { return Err("请先配置 Base URL、API Key 和模型".into()); }
    ensure_runtime(&app, &state)?;
    let payload = serde_json::json!({ "id": format!("{}-{}", request.session_id, uuid_like()), "method": "session.run", "params": request });
    let mut process = state.0.lock().map_err(|_| "runtime lock poisoned".to_string())?;
    process.as_mut().ok_or_else(|| "runtime 未启动".to_string())?.write(format!("{}\n", payload).as_bytes()).map_err(|error| error.to_string())
}

fn uuid_like() -> String { format!("{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos()) }

fn main() {
    tauri::Builder::default()
        .manage(RuntimeProcess(Arc::new(Mutex::new(None))))
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![runtime_status, load_settings, save_settings, run_agent])
        .run(tauri::generate_context!())
        .expect("failed to run DeepSeek Code desktop application");
}
