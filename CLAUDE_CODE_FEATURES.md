# 将 Claude Code 功能移植到 DeepSeek Code 的实施计划

## 现状分析

### ✅ 已有功能
1. **四种模式**：Plan / Manual / Accept Edits / Auto
2. **权限系统**：基于风险等级 (L0-L4) 的权限控制
3. **工具调用**：完整的工具注册和执行框架
4. **会话管理**：Session、事件存储、状态恢复
5. **网络搜索**：web.search 和 web.fetch 工具
6. **基础 UI**：SwiftUI 实现的对话界面

### ❌ 缺失或不完善的功能

#### 1. Plan 模式功能不完整
**Claude Code 的 Plan 模式**：
- 只读探索代码库
- 生成结构化计划（任务列表）
- 用户审批计划后进入执行阶段
- 执行时可回溯到计划中的步骤

**当前问题**：
- Plan 模式只是权限限制（只读 L0），没有计划生成和审批流程
- 没有 Task 系统来分解和跟踪计划步骤
- 没有计划到执行的工作流转换

#### 2. Agent 协作能力弱
**Claude Code 的 Agent 系统**：
- Subagent 生成：主 Agent 可以启动子 Agent 处理子任务
- Agent 通信：Agent 之间可以传递消息和结果
- 并行执行：多个 Agent 可以并行工作
- 上下文隔离：每个 Agent 有独立的上下文

**当前问题**：
- 虽然有 AgentWorkerKind（main/explore/research），但没有动态创建子 Agent 的能力
- 没有 Agent 间通信机制
- 没有并行 Agent 执行框架

#### 3. 缺少 Thinking 能力
**Claude Code 的 Thinking**：
- 使用 Claude 的 extended thinking 功能
- Agent 在复杂任务前先"思考"
- 提高决策质量和准确性

**当前问题**：
- 代码中有 `thinking: Bool` 参数，但未充分利用
- DeepSeek API 可能不支持 extended thinking（需要确认）

#### 4. 质量控制系统不完善
**Claude Code 的质量系统**：
- TaskQualityPlan：定义任务的质量要求
- 验证步骤：编译、测试、lint 检查
- 失败重试：自动修复错误并重试

**当前问题**：
- 有 QualityRuntime 框架，但没有完整实现
- 缺少自动化的编译-修复循环
- 缺少测试执行和结果验证

#### 5. 工具执行可靠性问题
**当前问题**：
- 审批流程卡住（已修复部分）
- 流式输出不稳定（已简化）
- 工具名称规范化问题（已修复）
- **搜索结果解析失败**（Bing HTML 变化）

---

## 实施路线图

### Phase 1: 修复核心稳定性（1-2 周）⭐ **当前优先级**

#### 1.1 修复搜索功能
- [ ] 替换 Bing scraping 为 Brave Search API 或 SerpAPI
- [ ] 添加 DuckDuckGo 作为备选搜索引擎
- [ ] 实现搜索结果缓存

#### 1.2 修复审批和流式输出
- [x] 工具名称规范化（canonicalTool）
- [x] 移除有问题的防抖逻辑
- [ ] 测试并验证所有模式下的工具执行
- [ ] 添加完整的错误恢复机制

#### 1.3 改进 UI 渲染
- [ ] 实现正确的 Markdown 渲染（使用 AttributedString 或第三方库）
- [ ] 优化流式输出性能（使用 SwiftUI 的 `.id()` 避免重建）
- [ ] 添加代码高亮显示

### Phase 2: 实现完整的 Plan 模式（2-3 周）

#### 2.1 Task 系统
```swift
// 需要实现的核心类型
struct Task: Identifiable {
    let id: String
    var title: String
    var description: String
    var status: TaskStatus // pending/inProgress/completed/failed
    var dependencies: [String] // 依赖的其他任务 ID
    var assignedTo: String? // Agent ID
}

enum TaskStatus {
    case pending
    case inProgress
    case completed
    case failed
}
```

#### 2.2 Plan 生成流程
1. 用户选择 Plan 模式并输入请求
2. Agent 只读探索代码库（grep、read、git log 等）
3. Agent 生成结构化计划（使用工具调用返回 JSON）
4. 系统解析计划并创建 Task 列表
5. 显示 Plan Card 给用户审批

#### 2.3 Plan 执行流程
1. 用户批准计划
2. 系统切换到 Auto/AcceptEdits 模式
3. 按照依赖顺序执行任务
4. 每个任务完成后更新状态
5. 失败时暂停并等待用户决策

#### 2.4 需要添加的工具
```swift
ToolSchema(name: "create_plan", description: "生成结构化任务计划", ...)
ToolSchema(name: "update_task_status", description: "更新任务状态", ...)
```

### Phase 3: Agent 协作系统（3-4 周）

#### 3.1 Subagent 框架
```swift
protocol AgentSpawner {
    func spawnSubagent(
        prompt: String,
        mode: AgentMode,
        parentContext: AgentContext
    ) async throws -> Agent
}

class Agent {
    let id: String
    let parentID: String?
    var children: [Agent]
    
    func sendMessage(to: Agent, message: String) async
    func receiveMessage() -> AsyncStream<AgentMessage>
}
```

#### 3.2 并行执行引擎
- 使用 Swift Concurrency 的 TaskGroup
- 实现 Agent 池管理
- 上下文隔离和资源限制

#### 3.3 通信协议
```swift
struct AgentMessage {
    let from: String
    let to: String
    let content: String
    let metadata: [String: Any]
}
```

### Phase 4: 质量控制增强（2-3 周）

#### 4.1 编译-修复循环
1. Agent 进行代码更改
2. 自动运行编译（swift build）
3. 如果失败，解析错误信息
4. Agent 自动修复并重试
5. 最多重试 3 次

#### 4.2 测试执行
1. 自动发现测试（swift test --list-tests）
2. 运行相关测试
3. 解析测试结果
4. 失败时提供修复建议

#### 4.3 Lint 和格式检查
- 集成 SwiftLint
- 自动格式化代码
- 检查代码风格

### Phase 5: 高级功能（4+ 周）

#### 5.1 上下文管理
- 智能上下文窗口管理
- 自动摘要和压缩
- 相关代码自动加载

#### 5.2 学习和记忆
- Session 间的记忆共享
- 项目级别的知识库
- 常见模式和最佳实践记录

#### 5.3 多模态能力
- 图片上传和分析
- 屏幕截图理解
- Diagram 生成

---

## 技术债务和改进

### 立即处理
1. **搜索引擎**：HTML scraping 太脆弱，必须换成 API
2. **日志系统**：添加结构化日志（OSLog）替代 print
3. **错误处理**：统一错误类型和恢复策略
4. **测试覆盖**：添加单元测试和集成测试

### 短期改进
1. **性能优化**：减少主线程阻塞
2. **内存管理**：大文件读取的流式处理
3. **UI 响应性**：所有网络操作异步化
4. **错误提示**：用户友好的错误信息

### 长期重构
1. **架构分层**：明确的 Core / UI / Network 分层
2. **依赖注入**：减少全局状态和硬编码依赖
3. **插件系统**：支持第三方工具和扩展
4. **跨平台**：考虑 iOS / Web 版本

---

## 与 Claude Code 的差距估算

| 功能模块 | 完成度 | 工作量 |
|---------|--------|--------|
| 基础对话 | 70% | 1-2 周 |
| 工具执行 | 60% | 1-2 周 |
| Plan 模式 | 30% | 2-3 周 |
| Agent 协作 | 10% | 3-4 周 |
| 质量控制 | 40% | 2-3 周 |
| UI/UX | 50% | 2-3 周 |
| **总计** | **~45%** | **~12-17 周** |

---

## 建议的开发顺序

### 优先级 P0（必须）
1. ✅ 修复审批流程卡住
2. ⚠️ 修复搜索功能（换成 API）
3. ⚠️ 实现 Markdown 渲染
4. 实现完整的 Plan 模式（Task 系统）

### 优先级 P1（重要）
5. Agent 协作基础框架
6. 编译-修复循环
7. 测试执行集成
8. 改进错误处理

### 优先级 P2（可选）
9. Subagent 并行执行
10. 高级上下文管理
11. 学习和记忆功能
12. 多模态能力

---

## 当前建议

基于你的情况，我建议：

1. **先解决当前问题**（P0）：
   - 修复搜索（用 Brave Search API）
   - 实现正确的 Markdown 渲染
   - 确保所有模式下工具执行稳定

2. **然后实现 Plan 模式**（P0-P1）：
   - 这是 Claude Code 的核心差异化功能
   - 用户价值最大
   - 技术复杂度适中

3. **逐步添加高级功能**（P1-P2）：
   - 根据用户反馈优先级调整
   - 保持代码质量和稳定性

要我现在开始实施哪个部分？我建议从**修复搜索功能**开始，因为这是当前最影响用户体验的问题。
