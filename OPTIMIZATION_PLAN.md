# 优化方案：让 DeepSeek Code 像 Claude Code 一样流畅

## 问题根源

你的应用卡在审批的根本原因已经通过之前的修复解决了。但为了达到 Claude Code 的流畅体验，还需要以下优化：

## 优化 1：自动授予研究类工具权限（推荐）

### 修改 `PermissionBroker.swift`

在 Auto 模式下，如果项目可信，自动允许 web 研究工具：

```swift
public static func decision(tool: ToolDescriptor, context: PermissionContext) -> PermissionDecision {
    if tool.risk == .l4 { return .block(tool.risk) }
    
    let isReadOnly = tool.effect == .readOnly || tool.effect == .browserRead || tool.effect == .computerRead
    
    // 新增：Auto 模式下，可信项目自动允许 web 研究工具
    if context.mode == .auto && context.projectTrusted {
        if tool.name == "web.search" || tool.name == "web.fetch" {
            return .allow
        }
    }
    
    // 原有逻辑...
    if context.mode == .plan {
        return isReadOnly && tool.risk == .l0 ? .allow : .block(tool.risk)
    }
    if isReadOnly && tool.risk == .l0 { return .allow }
    if context.mode == .manual { return .ask(tool.risk) }
    if context.mode == .acceptEdits {
        return tool.effect == .workspaceWrite && tool.risk == .l1 ? .allow : .ask(tool.risk)
    }
    if tool.risk >= .l3 { return .block(tool.risk) }
    if !context.projectTrusted || !context.sandboxAvailable {
        return tool.effect == .workspaceWrite && tool.risk == .l1 ? .allow : .ask(tool.risk)
    }
    if tool.risk <= .l1 { return .allow }
    return .ask(tool.risk)
}
```

### 实施方法

这个修改让 Auto 模式在项目可信时自动允许搜索和抓取，就像 Claude Code 一样。

## 优化 2：Session 级别的工具记忆（已部分实现）

你的代码已经有 `networkRuntime.rememberResearchApproval`，但可以加强：

### 在 Session 开始时预授权

修改 `WorkspaceStore.startAgentRun`，在 Agent 开始前就授予研究权限：

```swift
// 在创建 AgentHost 之前
if mode == .auto && isProjectTrusted {
    // 预授权本 Session 的 web 研究
    await networkRuntime.rememberResearchApproval(
        sessionID: sessionID,
        projectID: selectedProjectID,
        scope: .session
    )
    print("✅ [SESSION] Pre-authorized web research for this session")
}
```

## 优化 3：降低 web 工具的风险等级（激进方案）

如果你希望 web 搜索**永远不触发审批**，可以修改 `AgentHost.swift:1254`：

```swift
let risk: CommandRisk = switch name {
    case "apply_patch": .l1
    case "terminal.resize", "terminal.list", "terminal.ports", "terminal.attach": .l0
    case "terminal.exec", "terminal.open", "terminal.write", "terminal.signal", "terminal.close", "run_command", "git_action": .l2
    case "browser.open", "browser.click", "browser.type", "browser.assert": .l2
    case "web.search": .l1  // ← 从 L2 降到 L1
    case "web.fetch": .l1   // ← 从 L2 降到 L1
    case "ssh.execute": .l2
    case "computer.click", "computer.type", "computer.key": .l2
    default: .l0
}
```

然后在 `PermissionBroker` 中，L1 + Auto 模式会自动允许。

**权衡**：
- ✅ 最流畅，完全不需要审批
- ⚠️ 降低了安全性，恶意模型输出可能自动访问任意网站

## 优化 4：UI 改进 - 自动滚动到审批卡片

当审批卡片出现时，自动滚动到它：

```swift
// 在 ContentView.swift 的 conversationTimeline 更新后
.onChange(of: store.pendingApproval) { old, new in
    if new != nil {
        // 滚动到最后一个审批卡片
        withAnimation {
            scrollProxy.scrollTo("approval-\(new!.id)", anchor: .center)
        }
    }
}
```

## 推荐实施顺序

### 阶段 1：立即修复（已完成 ✅）
- 修复审批恢复流程
- 添加诊断日志

### 阶段 2：体验优化（现在做）
1. **实施优化 1**：Auto 模式 + 可信项目自动允许 web 工具
2. **测试**：确认搜索和抓取不再需要审批

### 阶段 3：进一步打磨（可选）
1. 实施优化 2：Session 预授权
2. 实施优化 4：UI 自动滚动
3. 添加"记住我的选择"选项

### 阶段 4：高级功能（后续）
1. 用户可配置的工具白名单
2. 域名级别的授权（只允许访问特定网站）
3. 审批历史和统计

## 快速测试

实施优化 1 后，测试流程：

1. 确保项目模式是 **Auto**（不是 Manual）
2. 确保项目是**可信的**（`isProjectTrusted = true`）
3. 发送："明天北京的天气如何"
4. 预期：直接显示搜索结果，**不弹出审批**

## 与 Claude Code 的对比

| 特性 | Claude Code | 你的应用（修复前） | 你的应用（优化后） |
|------|-------------|-------------------|-------------------|
| 审批流程恢复 | ✅ | ❌ | ✅ |
| Auto 模式自动允许搜索 | ✅ | ❌ | ✅（优化1） |
| Session 记忆授权 | ✅ | ⚠️ 部分 | ✅（优化2） |
| 流畅度 | 10/10 | 3/10 | 9/10 |

## 安全考虑

### 为什么 Claude Code 可以自动允许？

1. **Anthropic 控制模型**：他们知道 Claude 不会恶意调用工具
2. **沙箱环境**：Claude Code 有网络沙箱，限制了可访问的域名
3. **用户信任**：用户默认信任 Anthropic 的安全设计

### 你的应用的安全策略

1. **使用第三方模型**（DeepSeek）：需要更谨慎
2. **建议**：
   - 只在 Auto 模式 + 可信项目时自动允许
   - 添加域名白名单（例如只允许常见搜索引擎和天气网站）
   - 在设置中提供"严格模式"开关

## 代码实施

我现在帮你实施优化 1，这是最关键的改进。
