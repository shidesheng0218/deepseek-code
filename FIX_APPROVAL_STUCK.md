# 工具审批卡住问题 - 完整诊断与修复方案

## 问题症状
应用在执行 `web_fetch` 等工具时，界面显示"需要审批"的黄色状态，但无法继续执行，即使有审批按钮也点击无效。

## 根本原因分析

### 代码流程回顾

#### 1. 审批触发 ✅ (正常)
**位置**: `AgentHost.swift:486-495`
```swift
case .approvalRequired(risk):
    let approvalID = repository.createApproval(...)
    runState.requestApproval(approvalID: approvalID, toolCallID: call.id, tool: call.name, argumentsJSON: call.argumentsJSON)
    runState.messages = messages
    repository.saveRunState(runState)
    continuation.yield(.approvalRequired(tool: call.name, risk: risk))
    await eventWriter.flush()
    continuation.finish()  // ⚠️ Agent 流在这里结束
    return
```

#### 2. UI 更新 ✅ (正常)
**位置**: `WorkspaceStore.swift:3140-3151`
```swift
case let .approvalRequired(tool, risk):
    pendingApproval = ((try? repository?.runState(sessionID: selectedSessionID)) ?? nil)?.pendingApproval
    refreshNetworkState()
    updateSelectedSessionStatus(.awaitingToolApproval)
    conversationTimeline.append(ConversationEntry(
        kind: .approval,
        title: ConversationProjector.approvalTitle(for: tool),
        text: ConversationProjector.approvalText(tool: tool, risk: "L\(risk.rawValue)"),
        state: .waiting
    ))
```

#### 3. 审批按钮 ✅ (已实现)
**位置**: `ContentView.swift:916-925`
```swift
if approval != nil {
    HStack(spacing: 7) {
        Button("拒绝") { store.resolvePendingApproval(.deny) }
        Button("本 Session 允许") { store.resolvePendingApproval(.allowSession) }
        Button("允许一次") { store.resolvePendingApproval(.allowOnce) }
    }
}
```

#### 4. 审批处理 ⚠️ (有条件分支)
**位置**: `WorkspaceStore.swift:1768-1821`
```swift
public func resolvePendingApproval(_ decision: ApprovalDecision) {
    guard let pending = pendingApproval, let sessionSupervisor else { return }
    Task {
        pendingApproval = nil
        if isDaemonOwnedSession(selectedSessionID) {
            // 路径 A: Daemon IPC
            _ = try await sendDaemon(.approvalResolve, payload: payload, client: client)
        } else {
            // 路径 B: SessionSupervisor
            try await sessionSupervisor.resolveApproval(
                sessionID: selectedSessionID,
                approvalID: pending.id,
                decision: decision
            )
        }
    }
}
```

#### 5. ExecutionDriver 回调 ⚠️ (关键环节)
**位置**: `SessionSupervisor.swift:107-108`
```swift
public func resolveApproval(...) async throws {
    if let executionDriver = driver(for: sessionID) {
        try await executionDriver.resolveApproval(sessionID: sessionID, approvalID: approvalID, decision: decision)
    }
    try repository.resolveApproval(id: approvalID, decision: decision)
}
```

**如果 `executionDriver` 为 nil，只会更新数据库，不会恢复 Agent！**

#### 6. Agent 恢复执行 ✅ (正常)
**位置**: `WorkspaceStore.swift:1306-1347`
```swift
private func resumeAgentApprovalForSupervisor(sessionID: String, approvalID: String, decision: ApprovalDecision) async {
    let host = NativeAgentHost(...)
    let orchestrator = NativeSessionOrchestrator(host: host)
    pendingApproval = nil
    for try await event in orchestrator.resume(sessionID: sessionID, approvalID: approvalID, decision: decision) {
        apply(event: event, profile: profile)
        if let workerID { updateAgentWorker(for: workerID, event: event) }
    }
}
```

## 🔴 发现的问题

### 问题 1: ExecutionDriver 生命周期管理
`ExecutionDriver` 在 `startAgentRun` 中安装（第 1258 行）：
```swift
await supervisor.installExecutionDriver(executionDriver, sessionID: runSessionID)
try await supervisor.start(sessionID: runSessionID)
```

但如果：
- Agent 在等待审批期间，`agentRunTasks[runSessionID]` 任务已经结束
- ExecutionDriver 可能已经从 Supervisor 中移除
- 后续 `resolveApproval` 找不到 driver，只更新数据库，不会恢复执行

### 问题 2: UI 条件判断可能失效
**位置**: `ContentView.swift:891-895`
```swift
private var approval: PendingToolApproval? {
    guard entry.state == .waiting,
          let pending = store.pendingApproval else { return nil }
    return pending
}
```

如果 `entry.state` 不是 `.waiting`，或者 `store.pendingApproval` 为 nil，审批按钮不会显示。

### 问题 3: 错误处理可能静默失败
在 `resolvePendingApproval` 中，如果 `sessionSupervisor` 为 nil，直接 return，没有任何提示：
```swift
guard let pending = pendingApproval, let sessionSupervisor else { return }
```

## 🔧 修复方案

### 方案 A: 增强错误提示和日志（推荐）

修改 `WorkspaceStore.swift` 中的 `resolvePendingApproval`：

```swift
public func resolvePendingApproval(_ decision: ApprovalDecision) {
    guard let pending = pendingApproval else {
        statusMessage = "错误：没有待处理的审批"
        print("❌ resolvePendingApproval: pendingApproval is nil")
        return
    }
    guard let sessionSupervisor else {
        statusMessage = "错误：SessionSupervisor 未初始化"
        print("❌ resolvePendingApproval: sessionSupervisor is nil")
        return
    }
    
    print("✅ 开始处理审批: tool=\(pending.tool), approvalID=\(pending.id), decision=\(decision)")
    
    Task {
        do {
            // ... 现有的网络审批逻辑 ...
            
            pendingApproval = nil
            if isDaemonOwnedSession(selectedSessionID),
               let client = try? await daemonClient() {
                print("→ 使用 Daemon 路径")
                let payload = DeepSeekDaemonApprovalPayload(...)
                _ = try await sendDaemon(.approvalResolve, payload: payload, client: client)
            } else {
                print("→ 使用 Supervisor 路径")
                try await sessionSupervisor.resolveApproval(
                    sessionID: selectedSessionID,
                    approvalID: pending.id,
                    decision: decision
                )
            }
            print("✅ 审批处理完成")
            statusMessage = "审批已处理，继续执行"
        } catch {
            print("❌ 审批处理失败: \(error)")
            statusMessage = "恢复任务失败：\(error.localizedDescription)"
        }
    }
}
```

同时在 `SessionSupervisor.resolveApproval` 中添加日志：

```swift
public func resolveApproval(sessionID: String, approvalID: String, decision: ApprovalDecision) async throws {
    guard let approval = try repository.approval(id: approvalID) else { 
        print("❌ SessionSupervisor.resolveApproval: approval not found")
        throw HarnessSupervisorError.approvalNotFound 
    }
    
    print("→ SessionSupervisor.resolveApproval: sessionID=\(sessionID), approvalID=\(approvalID)")
    
    if let executionDriver = driver(for: sessionID) {
        print("→ 找到 ExecutionDriver，调用 resolveApproval")
        try await executionDriver.resolveApproval(sessionID: sessionID, approvalID: approvalID, decision: decision)
    } else {
        print("⚠️ ExecutionDriver 为 nil，只更新数据库")
    }
    
    if let refreshed = try repository.approval(id: approvalID), refreshed.decision == .pending {
        try repository.resolveApproval(id: approvalID, decision: decision)
        _ = try repository.appendDurable(...)
    }
    print("✅ SessionSupervisor.resolveApproval 完成")
}
```

在 `resumeAgentApprovalForSupervisor` 中添加日志：

```swift
private func resumeAgentApprovalForSupervisor(sessionID: String, approvalID: String, decision: ApprovalDecision) async {
    print("→ resumeAgentApprovalForSupervisor: sessionID=\(sessionID), approvalID=\(approvalID)")
    
    guard let eventStore, let apiKey = loadAPIKey() else {
        print("❌ eventStore 或 apiKey 缺失")
        return
    }
    
    do {
        // ... 创建 host 和 orchestrator ...
        
        print("→ 开始恢复 Agent 流...")
        pendingApproval = nil
        var eventCount = 0
        for try await event in orchestrator.resume(sessionID: sessionID, approvalID: approvalID, decision: decision) {
            eventCount += 1
            print("→ 收到恢复事件 #\(eventCount): \(event)")
            apply(event: event, profile: profile)
            if let workerID { updateAgentWorker(for: workerID, event: event) }
        }
        print("✅ Agent 流恢复完成，共 \(eventCount) 个事件")
        refreshGitStatus()
        finalizeTaskContract(sessionID: sessionID)
    } catch {
        print("❌ 审批恢复异常: \(error)")
        statusMessage = "审批恢复失败：\(error.localizedDescription)"
    }
}
```

### 方案 B: 保证 ExecutionDriver 持久化

修改 `startAgentRun`，确保 ExecutionDriver 在审批期间不会被移除：

```swift
// 在 startAgentRun 的 Task 中，不要在 supervisor.start() 之后立即清理
let task = Task<Void, Never> { [weak self] in
    guard let self else { return }
    if let supervisor = self.sessionSupervisor {
        do {
            await supervisor.installExecutionDriver(executionDriver, sessionID: runSessionID)
            try await supervisor.start(sessionID: runSessionID)
            
            // ⚠️ 不要在这里移除 driver，让它保持直到 session 完成
            // 旧代码可能在这里调用了 supervisor.installExecutionDriver(nil, sessionID: runSessionID)
            
        } catch {
            // 错误处理...
        }
    }
}
```

### 方案 C: 简化审批路径（最激进）

直接在 `resolvePendingApproval` 中调用 `resumeAgentApprovalForSupervisor`，绕过 SessionSupervisor：

```swift
public func resolvePendingApproval(_ decision: ApprovalDecision) {
    guard let pending = pendingApproval else { return }
    
    Task {
        do {
            // 网络审批逻辑...
            
            pendingApproval = nil
            
            if isDaemonOwnedSession(selectedSessionID),
               let client = try? await daemonClient() {
                // Daemon 路径...
            } else {
                // 直接调用恢复逻辑，不经过 Supervisor
                await resumeAgentApprovalForSupervisor(
                    sessionID: selectedSessionID,
                    approvalID: pending.id,
                    decision: decision
                )
                
                // 同步更新数据库
                if let sessionSupervisor {
                    try? await sessionSupervisor.resolveApproval(
                        sessionID: selectedSessionID,
                        approvalID: pending.id,
                        decision: decision
                    )
                }
            }
        } catch {
            statusMessage = "恢复任务失败：\(error.localizedDescription)"
        }
    }
}
```

## 🧪 调试步骤

1. **添加日志**：先实施方案 A，在关键路径添加 print 语句
2. **重现问题**：启动应用，发送需要审批的请求（如"明天北京的天气如何"）
3. **查看控制台输出**：
   - 是否输出了 "✅ 开始处理审批"
   - 使用了哪条路径（Daemon 还是 Supervisor）
   - ExecutionDriver 是否为 nil
   - `resumeAgentApprovalForSupervisor` 是否被调用
   - 恢复的事件流中有多少个事件

4. **根据日志定位**：
   - 如果 `sessionSupervisor` 为 nil → 初始化问题
   - 如果 ExecutionDriver 为 nil → 生命周期管理问题，实施方案 B
   - 如果 `resumeAgentApprovalForSupervisor` 没被调用 → 路由问题，实施方案 C
   - 如果事件流中断 → 查看 orchestrator.resume 的异常

## 📝 快速验证

最简单的验证方法：在 Xcode 中运行应用，在控制台观察是否有：
```
✅ 开始处理审批: tool=web_fetch, approvalID=..., decision=allowOnce
→ 使用 Supervisor 路径
→ SessionSupervisor.resolveApproval: sessionID=..., approvalID=...
⚠️ ExecutionDriver 为 nil，只更新数据库  // ← 如果看到这行，就是问题所在
```

如果确实看到 "ExecutionDriver 为 nil"，说明需要修复 ExecutionDriver 的生命周期管理。
