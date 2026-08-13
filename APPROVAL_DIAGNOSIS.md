# 工具审批流程诊断报告

## 问题现象
应用在执行 `web_fetch` 工具时卡在"需要审批"状态，无法继续执行。

## 代码审查结果

### ✅ 审批触发逻辑（已实现）
**位置**: `AgentHost.swift:486-495`
```swift
case .approvalRequired(risk):
    let approvalID = repository.createApproval(...)
    runState.requestApproval(approvalID: approvalID, ...)
    runState.messages = messages
    repository.saveRunState(runState)
    continuation.yield(.approvalRequired(tool: call.name, risk: risk))
    continuation.finish()  // ⚠️ 这里结束了 Agent 流
    return
```

### ✅ 审批状态保存（已实现）
**位置**: `AgentRunState.swift:52-55`
```swift
public mutating func requestApproval(approvalID: String, toolCallID: String, tool: String, argumentsJSON: String) {
    pendingApproval = PendingToolApproval(...)
    status = .waitingApproval
}
```

### ✅ UI 事件处理（已实现）
**位置**: `WorkspaceStore.swift:3140-3151`
```swift
case let .approvalRequired(tool, risk):
    pendingApproval = repository.runState(sessionID: selectedSessionID)?.pendingApproval
    conversationTimeline.append(ConversationEntry(
        kind: .approval,
        title: ConversationProjector.approvalTitle(for: tool),
        text: ConversationProjector.approvalText(tool: tool, risk: "L\(risk.rawValue)"),
        state: .waiting
    ))
```

### ✅ UI 审批按钮（已实现）
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

### ✅ 审批恢复逻辑（已实现）
**位置**: `WorkspaceStore.swift:1768-1821`
```swift
public func resolvePendingApproval(_ decision: ApprovalDecision) {
    guard let pending = pendingApproval, let sessionSupervisor else { return }
    Task {
        pendingApproval = nil
        try await sessionSupervisor.resolveApproval(
            sessionID: selectedSessionID,
            approvalID: pending.id,
            decision: decision
        )
    }
}
```

### ✅ SessionSupervisor 审批解析（已实现）
**位置**: `SessionSupervisor.swift:103-124`
```swift
public func resolveApproval(sessionID: String, approvalID: String, decision: ApprovalDecision) async throws {
    if let executionDriver = driver(for: sessionID) {
        try await executionDriver.resolveApproval(sessionID: sessionID, approvalID: approvalID, decision: decision)
    }
    try repository.resolveApproval(id: approvalID, decision: decision)
}
```

### ✅ Agent 恢复执行（已实现）
**位置**: `AgentHost.swift:151-208`
```swift
public func resume(sessionID: String, approvalID: String, decision: ApprovalDecision) -> AsyncThrowingStream<AgentEvent, Error> {
    // 1. 读取保存的状态
    guard let state = storedState, let pending = state.pendingApproval, pending.id == approvalID else {
        return failedStream(AgentHostError.approvalUnavailable)
    }
    
    // 2. 执行工具调用（如果批准）
    let call = IncrementalToolCall(...)
    let output = try await toolExecution(for: call, mode: resumedState.mode, sessionID: sessionID, approvedByUser: true)
    
    // 3. 继续 Agent 流
    resumedState.messages.append(ChatMessage(role: "tool", content: output, toolCallID: pending.toolCallID))
    resumedState.resolveApproval(decision: decision)
    resumedState.turn += 1
    
    // 4. 重新启动 Agent 流
    for try await event in runStream(...) {
        continuation.yield(event)
    }
}
```

## 🔴 发现的关键问题

### 问题 1: SessionSupervisor 的 ExecutionDriver 可能未设置

在 `WorkspaceStore.resolvePendingApproval` 中调用：
```swift
try await sessionSupervisor.resolveApproval(...)
```

但 `SessionSupervisor.resolveApproval` 依赖 `executionDriver`:
```swift
if let executionDriver = driver(for: sessionID) {
    try await executionDriver.resolveApproval(...)
}
```

**如果 `executionDriver` 为 nil，审批会被标记为已解决，但 Agent 不会恢复执行！**

### 问题 2: ExecutionDriver 协议实现可能不完整

需要检查实际的 ExecutionDriver 实现（`ClosureSessionExecutionDriver` 或其他）是否正确实现了 `resolveApproval` 方法。

### 问题 3: 前端可能没有订阅恢复后的事件流

`AgentHost.resume()` 返回一个新的 `AsyncThrowingStream<AgentEvent, Error>`，但前端可能没有正确订阅这个流来接收后续的 Agent 事件。

## 🔍 需要检查的文件

1. **SessionExecutionDriver 协议及实现**
   - `ClosureSessionExecutionDriver.swift`
   - 其他 ExecutionDriver 实现

2. **WorkspaceStore 如何初始化 SessionSupervisor**
   - 是否正确设置了 `executionDriver`

3. **前端事件流订阅**
   - `resolveApproval` 调用后，是否有代码订阅新的事件流

## 💡 推荐修复方案

### 方案 A: 确保 ExecutionDriver 正确设置
检查 `WorkspaceStore` 初始化时是否正确安装了 ExecutionDriver：
```swift
sessionSupervisor.installExecutionDriver(driver, sessionID: sessionID)
```

### 方案 B: 在 WorkspaceStore 中直接调用 AgentHost.resume
而不是通过 SessionSupervisor 中转：
```swift
public func resolvePendingApproval(_ decision: ApprovalDecision) {
    guard let pending = pendingApproval else { return }
    pendingApproval = nil
    
    // 直接调用 AgentHost.resume 并订阅事件流
    let stream = agentHost.resume(sessionID: selectedSessionID, approvalID: pending.id, decision: decision)
    subscribeToAgentStream(stream)
}
```

### 方案 C: 添加调试日志
在关键路径添加日志，确认执行流程：
1. `resolvePendingApproval` 入口
2. `SessionSupervisor.resolveApproval` 是否被调用
3. `executionDriver` 是否存在
4. `AgentHost.resume` 是否被调用
5. 新的事件流是否被订阅

## 下一步行动

1. 检查 `ClosureSessionExecutionDriver` 的实现
2. 检查 `WorkspaceStore` 初始化逻辑
3. 添加调试日志验证执行路径
4. 测试简化的直接调用方案
