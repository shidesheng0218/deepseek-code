use serde::{Deserialize, Serialize};
use chrono::Timelike;
use std::collections::HashMap;
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
struct SessionSummary { session_id: String, title: String, updated_at: u64, project_path: String }

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct UsageStats {
    sessions: u64,
    messages: u64,
    total_tokens: u64,
    input_tokens: u64,
    output_tokens: u64,
    cached_tokens: u64,
    active_days: u64,
    current_streak: u64,
    longest_streak: u64,
    peak_hour: Option<u32>,
    favorite_model: Option<String>,
    daily_activity: Vec<u64>,
    daily_start: Option<String>,
    model_tokens: Vec<ModelTokens>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ModelTokens { model: String, tokens: u64 }

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

fn session_project(events: &str) -> String {
    for line in events.lines() {
        let Ok(event) = serde_json::from_str::<serde_json::Value>(line) else { continue; };
        if event.get("type").and_then(serde_json::Value::as_str) != Some("turn_started") { continue; }
        if let Some(project) = event.get("payload").and_then(|value| value.get("projectPath")).and_then(serde_json::Value::as_str) {
            return project.into();
        }
    }
    String::new()
}

fn list_session_summaries() -> Vec<SessionSummary> {
    let Ok(entries) = fs::read_dir(sessions_path()) else { return Vec::new(); };
    let mut sessions = entries.filter_map(Result::ok).filter_map(|entry| {
        let path = entry.path();
        let session_id = path.file_stem()?.to_str()?.to_string();
        if path.extension().and_then(|value| value.to_str()) != Some("jsonl") || !is_safe_session_id(&session_id) { return None; }
        let events = fs::read_to_string(&path).ok()?;
        let updated_at = entry.metadata().ok()?.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs();
        Some(SessionSummary { title: session_title(&events, &session_id), project_path: session_project(&events), session_id, updated_at })
    }).collect::<Vec<_>>();
    sessions.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
    sessions
}

fn compute_usage_stats(days: Option<u32>) -> UsageStats {
    let now = chrono::Local::now();
    let today = now.date_naive();
    let cutoff = days.map(|value| today - chrono::Duration::days(i64::from(value)));
    let mut stats = UsageStats {
        sessions: 0, messages: 0, total_tokens: 0, input_tokens: 0, output_tokens: 0, cached_tokens: 0,
        active_days: 0, current_streak: 0, longest_streak: 0, peak_hour: None, favorite_model: None,
        daily_activity: Vec::new(), daily_start: None, model_tokens: Vec::new(),
    };
    let mut day_set = std::collections::BTreeSet::new();
    let mut daily: HashMap<chrono::NaiveDate, u64> = HashMap::new();
    let mut hours = [0u64; 24];
    let mut models: HashMap<String, u64> = HashMap::new();
    let Ok(entries) = fs::read_dir(sessions_path()) else { return stats; };
    for entry in entries.filter_map(Result::ok) {
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("jsonl") { continue; }
        let Some(session_id) = path.file_stem().and_then(|value| value.to_str()) else { continue; };
        if !is_safe_session_id(session_id) { continue; }
        let Ok(events) = fs::read_to_string(&path) else { continue; };
        let mut counted_in_window = false;
        for line in events.lines() {
            let Ok(event) = serde_json::from_str::<serde_json::Value>(line) else { continue; };
            let Some(created) = event.get("createdAt").and_then(serde_json::Value::as_str)
                .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok()) else { continue; };
            let local = created.with_timezone(&chrono::Local);
            let day = local.date_naive();
            if cutoff.is_some_and(|limit| day < limit) { continue; }
            counted_in_window = true;
            *daily.entry(day).or_default() += 1;
            day_set.insert(day);
            let payload = event.get("payload");
            match event.get("type").and_then(serde_json::Value::as_str) {
                Some("turn_started") => {
                    stats.messages += 1;
                    hours[local.hour() as usize] += 1;
                }
                Some("turn_ended") => { stats.messages += 1; }
                Some("usage_recorded") => {
                    let number = |key: &str| payload.and_then(|value| value.get(key)).and_then(serde_json::Value::as_u64).unwrap_or(0);
                    let input = number("inputTokens");
                    let output = number("outputTokens");
                    stats.input_tokens += input;
                    stats.output_tokens += output;
                    stats.cached_tokens += number("cachedInputTokens");
                    stats.total_tokens += input + output;
                    if let Some(model) = payload.and_then(|value| value.get("model")).and_then(serde_json::Value::as_str).filter(|value| !value.is_empty()) {
                        *models.entry(model.to_string()).or_default() += input + output;
                    }
                }
                _ => {}
            }
        }
        if counted_in_window { stats.sessions += 1; }
    }
    stats.active_days = day_set.len() as u64;
    let heatmap_start = today - chrono::Duration::days(139);
    stats.daily_start = Some(heatmap_start.to_string());
    stats.daily_activity = (0..140).map(|offset| daily.get(&(heatmap_start + chrono::Duration::days(offset))).copied().unwrap_or(0)).collect();
    let streak_from = |anchor: chrono::NaiveDate| -> u64 {
        let mut streak = 0;
        let mut day = anchor;
        while day_set.contains(&day) { streak += 1; day -= chrono::Duration::days(1); }
        streak
    };
    stats.current_streak = if day_set.contains(&today) { streak_from(today) } else { streak_from(today - chrono::Duration::days(1)) };
    let mut longest = 0u64;
    let mut run = 0u64;
    let mut previous: Option<chrono::NaiveDate> = None;
    for day in &day_set {
        run = if previous.is_some_and(|value| *day == value + chrono::Duration::days(1)) { run + 1 } else { 1 };
        longest = longest.max(run);
        previous = Some(*day);
    }
    stats.longest_streak = longest;
    stats.peak_hour = hours.iter().enumerate().max_by_key(|(_, count)| *count).and_then(|(hour, count)| (*count > 0).then_some(hour as u32));
    stats.favorite_model = models.iter().max_by_key(|(_, tokens)| *tokens).map(|(model, _)| model.clone());
    stats.model_tokens = {
        let mut rows = models.into_iter().map(|(model, tokens)| ModelTokens { model, tokens }).collect::<Vec<_>>();
        rows.sort_by(|left, right| right.tokens.cmp(&left.tokens));
        rows
    };
    stats
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
fn usage_stats(days: Option<u32>) -> UsageStats { compute_usage_stats(days) }

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

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct UpdateStatus { available: bool, version: Option<String>, detail: String }

#[tauri::command]
async fn check_for_update(app: AppHandle) -> Result<UpdateStatus, String> {
    use tauri_plugin_updater::UpdaterExt;
    let updater = app.updater().map_err(|error| error.to_string())?;
    match updater.check().await {
        Ok(Some(update)) => {
            let version = update.version.clone();
            match update.download_and_install(|_, _| {}, || {}).await {
                Ok(()) => Ok(UpdateStatus { available: true, version: Some(version), detail: "已下载并安装，重启后生效".into() }),
                Err(error) => Ok(UpdateStatus { available: true, version: Some(version), detail: format!("下载失败：{error}") })
            }
        }
        Ok(None) => Ok(UpdateStatus { available: false, version: None, detail: "已是最新版本".into() }),
        Err(error) => Ok(UpdateStatus { available: false, version: None, detail: format!("检查失败：{error}") })
    }
}

fn main() {
    tauri::Builder::default()
        .manage(RuntimeProcess(Arc::new(Mutex::new(None))))
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .invoke_handler(tauri::generate_handler![runtime_status, build_stamp, load_settings, save_settings, list_sessions, usage_stats, load_session_history, run_agent, resolve_approval, cancel_session, resume_session, check_for_update])
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

    #[test]
    fn aggregates_usage_stats_from_session_event_logs() {
        let temp = std::env::temp_dir().join(format!("deepseek-stats-test-{}", std::process::id()));
        let sessions = temp.join("Library/Application Support/DeepSeekCode/sessions");
        fs::create_dir_all(&sessions).expect("create temp sessions dir");
        let previous_home = std::env::var_os("HOME");
        std::env::set_var("HOME", &temp);
        let now = chrono::Local::now();
        let old = now - chrono::Duration::days(40);
        let event = |created: chrono::DateTime<chrono::Local>, kind: &str, payload: &str| {
            format!("{{\"type\":\"{kind}\",\"payload\":{payload},\"createdAt\":\"{}\"}}", created.to_rfc3339())
        };
        let lines = [
            event(now, "turn_started", "{\"prompt\":\"修复登录问题\",\"projectPath\":\"/tmp/demo\"}"),
            event(now, "usage_recorded", "{\"inputTokens\":100,\"outputTokens\":50,\"cachedInputTokens\":10,\"model\":\"deepseek-chat\"}"),
            event(now, "turn_ended", "{\"status\":\"completed\"}"),
            event(now, "turn_started", "{\"prompt\":\"第二个问题\"}"),
            event(old, "turn_started", "{\"prompt\":\"旧问题\"}"),
        ];
        fs::write(sessions.join("session-stats-fixture.jsonl"), lines.join("\n")).expect("write fixture events");

        let all = compute_usage_stats(None);
        assert_eq!(all.sessions, 1);
        assert_eq!(all.messages, 4);
        assert_eq!(all.total_tokens, 150);
        assert_eq!(all.cached_tokens, 10);
        assert_eq!(all.active_days, 2);
        assert_eq!(all.favorite_model.as_deref(), Some("deepseek-chat"));
        assert_eq!(all.model_tokens.first().map(|row| row.model.as_str()), Some("deepseek-chat"));
        assert_eq!(all.daily_activity.len(), 140);
        assert_eq!(all.daily_activity.iter().sum::<u64>(), 5);
        assert!(all.current_streak >= 1);
        assert!(all.longest_streak >= 1);
        assert_eq!(all.peak_hour, Some(now.hour()));

        let recent = compute_usage_stats(Some(30));
        assert_eq!(recent.messages, 3);
        assert_eq!(recent.active_days, 1);

        if let Some(value) = previous_home { std::env::set_var("HOME", value); }
        let _ = fs::remove_dir_all(&temp);
    }
}
