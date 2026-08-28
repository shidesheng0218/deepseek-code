# 功能打通状态检查报告

## ✅ 已完全打通的功能

### Phase 0：交付回执
- ✅ 哈希链构建
- ✅ 离线验证
- ✅ 集成到 main.ts

### Phase 1：确定性回放 + 对抗验证
- ✅ RecordingProvider（录制模型流）
- ✅ session.replay IPC 方法
- ✅ Verifier Worker
- ✅ Gate v2（要求 verifier_verdict）
- ✅ 集成到 delivery-gate.ts

### Phase 2：锦标赛 + 代码图谱
- ✅ TournamentOrchestrator
- ✅ session.arena IPC 方法
- ✅ CodeGraphService
- ✅ 4 个图谱工具（symbol_card / who_calls / change_impact / module_map）
- ✅ 集成到 main.ts

### Phase 3：污点追踪
- ✅ TaintTracker
- ✅ 自动检测参数来源（detectSource）
- ✅ 污点升级规则
- ✅ 集成到 runPersistentCommand()

### Phase 5：沙箱
- ✅ SandboxService（macOS）
- ✅ run_sandboxed_command 工具
- ✅ 违规追踪
- ✅ 集成到 main.ts

---

## ⚠️ 部分打通的功能（需要补齐）

### Phase 4：Shadow Eval
**已实现**：
- ✅ ShadowEvaluator 框架
- ✅ session.shadowEval IPC 方法
- ✅ 4 种预定义变体

**未打通**：
- ❌ 实际重跑 AgentExecutor with RecordingProvider
- ❌ 指标对比（当前只统计录制内容，未实际重跑）
- ❌ 策略变体应用（当前只记录，未实际修改）

**位置**：`src/core/shadow-eval.ts:75`
```typescript
// TODO Phase 4 v2：实际重跑 AgentExecutor with RecordingProvider
```

---

## 🔧 需要完善的功能

### 1. 代码图谱调用图
**已实现**：符号索引、模块地图
**未实现**：跨文件调用关系分析

**位置**：`src/core/code-graph.ts`
```typescript
// TODO: 构建 CallGraphEdge（需要跨文件解析）
```

### 2. Arena Judge 规划模型
**已实现**：基础裁决逻辑
**未实现**：调用专门的规划模型（DeepSeek R1 / Claude Opus）

**位置**：`src/core/arena.ts`
```typescript
// TODO: 调用规划模型（DeepSeek R1 / Claude Opus）
```

### 3. 沙箱 Linux 支持
**已实现**：macOS sandbox-exec
**未实现**：Linux bubblewrap

**位置**：`src/core/sandbox.ts`
```typescript
// TODO: bubblewrap 实现
```

### 4. 内存监控清理逻辑
**已实现**：内存监控框架
**未实现**：具体的数据结构清理

**位置**：`src/core/memory-monitor.ts`
```typescript
// TODO: 清理具体的数据结构
```

---

## 📊 功能完整度统计

| Phase | 核心功能打通率 | 说明 |
|---|---|---|
| Phase 0 | 100% | 完全打通 |
| Phase 1 | 100% | 完全打通 |
| Phase 2 | 90% | 缺跨文件调用图 |
| Phase 3 | 100% | 完全打通 |
| Phase 4 | 60% | 缺实际重跑 AgentExecutor |
| Phase 5 | 80% | 缺 Linux 支持 |

**总体完整度**：88%

---

## 🎯 优先级建议

### P0（高优先级）
1. **Phase 4 实际重跑**：打通 Shadow Eval 的核心价值
   - 修改 `src/core/shadow-eval.ts:75`
   - 实际调用 AgentExecutor with RecordingProvider
   - 对比真实的指标差异

### P1（中优先级）
2. **代码图谱跨文件调用图**：提升 token 节省效果
   - 使用 tree-sitter 解析 import/require
   - 构建完整的调用图

3. **Arena Judge 规划模型**：提升锦标赛质量
   - 集成 DeepSeek R1 或 Claude Opus
   - 实现多步推理裁决

### P2（低优先级）
4. **沙箱 Linux 支持**：跨平台兼容性
5. **内存监控清理逻辑**：性能优化细节

---

## 🚀 建议行动

**立即行动**：
- 补齐 Phase 4 实际重跑（1-2 小时）
- 完善代码图谱调用图（2-3 小时）

**短期行动**：
- Arena Judge 规划模型集成（半天）

**长期优化**：
- Linux 沙箱、内存清理细节
