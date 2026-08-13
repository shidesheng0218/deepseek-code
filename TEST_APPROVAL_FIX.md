# 工具审批修复 - 测试指南

## 🎉 修复完成

已完成以下修改：

### 1. 修复核心逻辑 (`WorkspaceStore.swift`)
- ✅ 改为**直接调用** `resumeAgentApprovalForSupervisor`，不依赖 ExecutionDriver
- ✅ 添加完整的错误提示和状态消息
- ✅ 添加详细的调试日志

### 2. 增强日志系统
在以下关键路径添加了日志：
- `WorkspaceStore.resolvePendingApproval` - 审批入口
- `WorkspaceStore.resumeAgentApprovalForSupervisor` - Agent 恢复
- `SessionSupervisor.resolveApproval` - Supervisor 协调
- `AgentHost.resume` - 底层 Agent 恢复

### 3. 关键修改点

**最重要的改动**在 `WorkspaceStore.swift:1810-1820`：

```swift
// 旧代码（可能失败）：
try await sessionSupervisor.resolveApproval(...)

// 新代码（直接恢复）：
await resumeAgentApprovalForSupervisor(
    sessionID: selectedSessionID,
    approvalID: pending.id,
    decision: decision
)
// 然后同步更新数据库
try? await sessionSupervisor.resolveApproval(...)
```

这确保了即使 ExecutionDriver 缺失，Agent 也能正确恢复执行。

## 🧪 测试步骤

### 第 1 步：启动应用并观察日志

```bash
cd "/Users/eastbuy/Documents/ChatGPT/DeepSeek桌面版/macos/DeepSeekCode"
swift run DeepSeekCode 2>&1 | grep "\[APPROVAL\]\|\[SUPERVISOR\]\|\[AGENTHOST\]"
```

这会过滤出所有审批相关的日志。

### 第 2 步：触发审批场景

在应用中发送一个需要网络访问的请求，例如：

```
明天北京的天气如何
```

或者：

```
帮我搜索最新的 Swift 6 新特性
```

### 第 3 步：观察日志输出

**正常流程应该看到：**

```
✅ [APPROVAL] Starting: tool=web_search, approvalID=..., decision=allowOnce
→ [APPROVAL] Using Supervisor path
→ [APPROVAL] resumeAgentApprovalForSupervisor called: sessionID=...
→ [APPROVAL] Starting Agent resume stream...
→ [AGENTHOST] resume called: sessionID=...
✅ [AGENTHOST] Found pending approval for tool: web_search
→ [AGENTHOST] Executing approved tool: web_search
→ [AGENTHOST] Tool execution completed: succeeded=true
→ [AGENTHOST] Continuing Agent stream with new turn...
→ [APPROVAL] Event #1: toolRequested(name: "web_search")
→ [APPROVAL] Event #2: toolCompleted(name: "web_search", succeeded: true)
→ [APPROVAL] Event #3: assistantDelta("...")
→ [APPROVAL] Event #4: completed
✅ [APPROVAL] Agent resume completed, received 4 events
✅ [APPROVAL] Completed successfully
```

### 第 4 步：点击审批按钮

当界面显示"需要审批"的黄色卡片时：

1. 观察是否有三个按钮：
   - "拒绝"
   - "本 Session 允许"
   - "允许一次"

2. 点击 **"允许一次"**

3. 观察：
   - 控制台日志是否输出了上述的正常流程
   - UI 是否继续显示 Agent 的回复
   - 工具执行结果是否正确显示

## 🔍 故障排查

### 问题 A：看到 "pendingApproval is nil"

**原因**：UI 状态未正确同步

**解决**：检查 `WorkspaceStore.swift:3141` 的赋值逻辑：
```swift
pendingApproval = ((try? repository?.runState(sessionID: selectedSessionID)) ?? nil)?.pendingApproval
```

### 问题 B：看到 "sessionSupervisor is nil"

**原因**：SessionSupervisor 未初始化

**解决**：检查 `WorkspaceStore` 的初始化，确保 `sessionSupervisor` 被正确创建。

### 问题 C：看到 "ExecutionDriver is nil" (应该不会影响)

这个警告是预期的，因为新代码不再依赖 ExecutionDriver。只要后续日志正常，就没问题。

### 问题 D：看到 "eventStore is nil" 或 "apiKey is nil"

**原因**：核心依赖缺失

**解决**：
- 检查 Provider 配置是否正确
- 检查 API Key 是否已保存到 Keychain

### 问题 E：Agent 流中断，只收到 0-1 个事件

**原因**：`orchestrator.resume` 抛出异常

**查看**：日志中的 "❌ [APPROVAL] Resume failed with error:" 后面的错误信息

## ✅ 成功标志

修复成功的标志：

1. **点击审批按钮后**，控制台输出完整的日志链
2. **UI 继续更新**，显示工具执行结果和 Agent 回复
3. **最终显示完整答案**，例如天气信息或搜索结果
4. **Session 状态**从 "等待审批" 变为 "运行中" 再到 "已完成"

## 📊 性能验证

修复后，测试以下场景确保都能流畅执行：

### 场景 1：Web 搜索
```
问题：Python 3.13 有哪些新特性？
预期：自动调用 web_search → 显示审批 → 批准 → 显示搜索结果
```

### 场景 2：Web 抓取
```
问题：帮我总结一下 https://docs.python.org/3.13/whatsnew/3.13.html 的内容
预期：调用 web_fetch → 显示审批 → 批准 → 抓取并总结内容
```

### 场景 3：连续工具调用
```
问题：搜索最新的 SwiftUI 教程，然后帮我抓取排名第一的文章
预期：web_search → 审批 → 批准 → web_fetch → 审批 → 批准 → 完整答案
```

### 场景 4：拒绝审批
```
问题：明天北京的天气如何
操作：点击"拒绝"按钮
预期：Agent 回复"用户拒绝了工具调用"，然后基于现有知识回答
```

## 🐛 已知限制

1. **日志会输出到控制台**
   - 这是调试版本，正式发布前可以移除或改为条件编译
   - 建议保留用于生产环境的故障诊断

2. **审批按钮可能需要滚动才能看到**
   - 如果对话历史很长，审批卡片可能在可视区域之外
   - 考虑添加自动滚动到审批卡片的功能

3. **多个工具连续审批**
   - 当前每个工具都需要单独审批
   - "本 Session 允许" 应该能覆盖同类型的后续工具调用

## 📝 后续优化建议

1. **添加审批预设**
   - 让用户可以设置"总是允许搜索"、"总是允许读取"等
   - 存储到用户偏好设置中

2. **改进审批 UI**
   - 显示工具的具体参数（如搜索关键词、要访问的 URL）
   - 添加"记住我的选择"复选框

3. **批量审批**
   - 如果有多个待审批工具，显示在一个列表中
   - 提供"全部允许"和"全部拒绝"按钮

4. **审批历史**
   - 记录用户的审批决策
   - 在设置中显示审批历史和撤销功能

## 🎯 验收标准

修复算成功的最终标准：

- ✅ 用户提问 "明天北京的天气如何"
- ✅ 界面显示需要审批的黄色卡片
- ✅ 点击 "允许一次" 按钮
- ✅ 工具成功执行（web_search）
- ✅ Agent 继续输出完整的天气信息回答
- ✅ 整个过程流畅，无卡顿或中断

## 🚀 下一步

测试通过后：

1. **移除或条件编译调试日志**
   ```swift
   #if DEBUG
   print("→ [APPROVAL] ...")
   #endif
   ```

2. **提交代码**
   ```bash
   git add -A
   git commit -m "Fix: Agent approval resume flow

   - Direct call to resumeAgentApprovalForSupervisor to bypass ExecutionDriver dependency
   - Add comprehensive logging for approval flow debugging
   - Improve error messages when approval fails
   - Ensure Agent continues execution after user approves tool call"
   ```

3. **更新文档**
   - 在 README 中说明审批流程
   - 添加故障排查指南

4. **性能测试**
   - 测试 30 个连续审批场景
   - 确保内存和响应时间稳定
