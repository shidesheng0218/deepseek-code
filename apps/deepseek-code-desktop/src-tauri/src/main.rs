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

fn build_stamp_value() -> String { format!("{}-{}", env!("CARGO_PKG_VERSION"), option_env!("DEEPSEEK_GIT_SHA").unwrap_or("unknown")) }

#[derive(Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct RuntimeSettings {
    base_url: String,
    model: String,
    #[serde(default)]
    fast_model: String,
    project_path: String,
    protocol: String,
    #[serde(skip_serializing)]
    api_key: String,
}

#[derive(Clone, Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct RestoredMessage { role: String, text: String }

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionSummary { session_id: String, title: String, updated_at: u64 }

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentRequest {
    session_id: String,
    project_path: String,
    prompt: String,
    base_url: String,
    api_key: String,
    model: String,
    #[serde(default)]
    fast_model: String,
    protocol: String,
    mode: String,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct ApprovalRequest {
    session_id: String,
    project_path: String,
    base_url: String,
    api_key: String,
    model: String,
    protocol: String,
    mode: String,
    approval_id: String,
    decision: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CancelRequest { session_id: String }

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct ResumeRequest {
    session_id: String,
    project_path: String,
    base_url: String,
    api_key: String,
    model: String,
    protocol: String,
    mode: String,
}

struct RuntimeProcess(Arc<Mutex<Option<CommandChild>>>);

fn settings_path() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    home.join("Library/Application Support/DeepSeekCode/settings.json")
}

fn sessions_path() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    home.join("Library/Application Support/DeepSeekCode/sessions")
}

fn is_safe_session_id(session_id: &str) -> bool {
    !session_id.is_empty() && session_id.chars().all(|value| value.is_ascii_alphanumeric() || matches!(value, '-' | '_' | '.'))
}

fn parse_session_history(events: &str) -> Vec<RestoredMessage> {
    let mut messages = Vec::new();
    let mut assistant = String::new();
    for line in events.lines().filter(|line| !line.trim().is_empty()) {
        let Ok(event) = serde_json::from_str::<serde_json::Value>(line) else { continue; };
        let event_type = event.get("type").and_then(serde_json::Value::as_str).unwrap_or_default();
        let payload = event.get("payload").and_then(serde_json::Value::as_object);
        if event_type == "turn_started" {
            if let Some(prompt) = payload.and_then(|value| value.get("prompt")).and_then(serde_json::Value::as_str) {
                messages.push(RestoredMessage { role: "user".into(), text: prompt.into() });
            }
        }
        if event_type == "assistant_text" {
            if let Some(text) = payload.and_then(|value| value.get("text")).and_then(serde_json::Value::as_str) { assistant.push_str(text); }
        }
        if event_type == "turn_ended" && !assistant.is_empty() {
            messages.push(RestoredMessage { role: "assistant".into(), text: std::mem::take(&mut assistant) });
        }
    }
    messages
}

fn read_session_events(session_id: &str) -> Result<String, String> {
    if !is_safe_session_id(session_id) { return Err("会话 ID 无效".into()); }
    fs::read_to_string(sessions_path().join(format!("{session_id}.jsonl"))).map_err(|error| error.to_string())
}

fn session_title(events: &str, fallback: &str) -> String {
    for line in events.lines() {
        let Ok(event) = serde_json::from_str::<serde_json::Value>(line) else { continue; };
        if event.get("type").and_then(serde_json::Value::as_str) != Some("turn_started") { continue; }
        if let Some(prompt) = event.get("payload").and_then(|value| value.get("prompt")).and_then(serde_json::Value::as_str) {
            let title: String = prompt.chars().take(56).collect();
            return if prompt.chars().count() > 56 { format!("{title}…") } else { title };
        }
    }
    fallback.into()
}

fn list_session_summaries() -> Vec<SessionSummary> {
    let Ok(entries) = fs::read_dir(sessions_path()) else { return Vec::new(); };
    let mut sessions = entries.filter_map(Result::ok).filter_map(|entry| {
        let path = entry.path();
        let session_id = path.file_stem()?.to_str()?.to_string();
        if path.extension().and_then(|value| value.to_str()) != Some("jsonl") || !is_safe_session_id(&session_id) { return None; }
        let events = fs::read_to_string(&path).ok()?;
        let updated_at = entry.metadata().ok()?.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs();
        Some(SessionSummary { title: session_title(&events, &session_id), session_id, updated_at })
    }).collect::<Vec<_>>();
    sessions.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
    sessions
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
fn build_stamp() -> String { build_stamp_value() }

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
fn list_sessions() -> Vec<SessionSummary> { list_session_summaries() }

#[tauri::command]
fn load_session_history(session_id: String) -> Result<Vec<RestoredMessage>, String> {
    Ok(parse_session_history(&read_session_events(&session_id)?))
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
    let payload = serde_json::json!({ "id": format!("{}-{}", request.session_id, uuid_like()), "method": "session.run", "params": request });
    send_runtime_request(&app, &state, payload)
}

#[tauri::command]
fn resolve_approval(app: AppHandle, state: State<'_, RuntimeProcess>, request: ApprovalRequest) -> Result<(), String> {
    if request.session_id.trim().is_empty() || request.approval_id.trim().is_empty() || !matches!(request.decision.as_str(), "allow" | "deny") { return Err("审批参数无效".into()); }
    if request.project_path.trim().is_empty() || request.base_url.trim().is_empty() || request.api_key.trim().is_empty() || request.model.trim().is_empty() { return Err("请先配置 Base URL、API Key、模型和项目目录".into()); }
    let payload = serde_json::json!({ "id": format!("{}-{}", request.session_id, uuid_like()), "method": "session.resolveApproval", "params": request });
    send_runtime_request(&app, &state, payload)
}

#[tauri::command]
fn cancel_session(state: State<'_, RuntimeProcess>, request: CancelRequest) -> Result<(), String> {
    if request.session_id.trim().is_empty() { return Err("sessionId 不能为空".into()); }
    let payload = serde_json::json!({ "id": format!("{}-{}", request.session_id, uuid_like()), "method": "session.cancel", "params": { "sessionID": request.session_id } });
    let mut process = state.0.lock().map_err(|_| "runtime lock poisoned".to_string())?;
    process.as_mut().ok_or_else(|| "runtime 未启动".to_string())?.write(format!("{}\n", payload).as_bytes()).map_err(|error| error.to_string())
}

#[tauri::command]
fn resume_session(app: AppHandle, state: State<'_, RuntimeProcess>, request: ResumeRequest) -> Result<(), String> {
    if request.session_id.trim().is_empty() { return Err("sessionId 不能为空".into()); }
    if request.project_path.trim().is_empty() || request.base_url.trim().is_empty() || request.api_key.trim().is_empty() || request.model.trim().is_empty() { return Err("请先配置 Base URL、API Key、模型和项目目录".into()); }
    let payload = serde_json::json!({ "id": format!("{}-{}", request.session_id, uuid_like()), "method": "session.recover", "params": request });
    send_runtime_request(&app, &state, payload)
}

fn send_runtime_request(app: &AppHandle, state: &RuntimeProcess, payload: serde_json::Value) -> Result<(), String> {
    ensure_runtime(app, state)?;
    let mut process = state.0.lock().map_err(|_| "runtime lock poisoned".to_string())?;
    process.as_mut().ok_or_else(|| "runtime 未启动".to_string())?.write(format!("{}\n", payload).as_bytes()).map_err(|error| error.to_string())
}

fn uuid_like() -> String { format!("{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos()) }

fn main() {
    tauri::Builder::default()
        .manage(RuntimeProcess(Arc::new(Mutex::new(None))))
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![runtime_status, build_stamp, load_settings, save_settings, list_sessions, load_session_history, run_agent, resolve_approval, cancel_session, resume_session])
        .run(tauri::generate_context!())
        .expect("failed to run DeepSeek Code desktop application");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restores_committed_user_and_assistant_messages_from_session_events() {
        let events = concat!(
            "{\"type\":\"turn_started\",\"payload\":{\"prompt\":\"修复登录问题\"}}\n",
            "{\"type\":\"assistant_text\",\"payload\":{\"text\":\"已定位\"}}\n",
            "{\"type\":\"assistant_text\",\"payload\":{\"text\":\"并修复。\"}}\n",
            "{\"type\":\"turn_ended\",\"payload\":{\"status\":\"completed\"}}\n"
        );

        assert_eq!(parse_session_history(events), vec![
            RestoredMessage { role: "user".into(), text: "修复登录问题".into() },
            RestoredMessage { role: "assistant".into(), text: "已定位并修复。".into() }
        ]);
    }

    #[test]
    fn exposes_a_non_empty_build_stamp() {
        assert!(build_stamp_value().contains('-'));
    }
}
