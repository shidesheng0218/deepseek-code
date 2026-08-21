# OpenAI Codex 竞品分析（2026-08-21）

> Codex 于今日开源：https://github.com/openai/codex （Apache-2.0，110k stars）

---

## 1. 架构概览

### 1.1 技术栈

**Codex：**
- **运行时**：Rust（codex-rs，100+ crates 的微模块架构）
- **CLI**：Node.js（codex-cli）
- **SDK**：Python、TypeScript、Python-runtime
- **构建系统**：Bazel + pnpm workspace
- **持久化**：本地 rollout 文件（推测为 JSONL 或类似格式）+ 可选云端同步

**DeepSeek Code：**
- **运行时**：Node.js/TypeScript（单体 main.ts 1371 行 + 模块化 src/core）
- **编译**：Bun（`bun build --compile`，零依赖二进制）
- **持久化**：JSONL 事件日志 + SQLite 投影层（`bun:sqlite`）
- **构建系统**：npm + Tauri

---

## 2. 核心能力对比

### 2.1 会话持久化与恢复

| 维度 | Codex | DeepSeek Code | 胜负 |
|---|---|---|---|
| **格式** | Rollout 文件（专有格式，推测类 JSONL） | JSONL 事件溯源 + schemaVersion | 平手 |
| **恢复语义** | `ResumeThreadParams`：区分待审批/排队输入/indeterminate | `recoverInterruptedSessions()`：同样区分四种状态 | 平手 |
| **水位追踪** | `ordinal` 序号 + `TurnPage` 分页 | `sequence` 序号 + 投影层 `max(sequence)` 水位 | 平手 |
| **事件 schema 演进** | 不明确（代码中未见版本化策略） | `schemaVersion: 1 → 2` + 投影层按版本分流解析 | **我们赢** |

**判断**：两者都有完整恢复语义，我们的 schema 演进更明确。

---

### 2.2 分叉（Fork）与回放（Replay）

| 维度 | Codex | DeepSeek Code | 胜负 |
|---|---|---|---|
| **分叉边界** | `ForkBoundary`：`Latest / ThroughTurn / BeforeTurn` | `baseSequence`：整数序号（单一粒度） | Codex 赢 |
| **Copy-on-write** | `PreparedFork` + `_source_reservation`（阻止源删除） | `session_forked` 首行标记 + 懒加载源历史 | 平手（思路一致） |
| **确定性回放** | **缺失**：`ThreadStore` trait 无 replay 方法；`revert_thread` 只做物理删除 | `session.replay`：录制模型流 + 逐事件匹配 + 门禁重算 | **我们赢** |
| **回放用途** | 不可证伪（无 replay 能力） | Shadow eval（离线上下文策略对比）+ 崩溃一致性验证 | **我们赢** |

**判断**：Codex 的分叉粒度更细（可按 turn 名称定位），但**没有确定性回放**——这是我们的杀手锏。

---

### 2.3 交付验证与门禁

| 维度 | Codex | DeepSeek Code | 胜负 |
|---|---|---|---|
| **门禁逻辑** | 未见显式门禁评估（可能在云端或 protocol 内部） | `evaluateDeliveryGate`：规则引擎 + `delivered / needsRepair / needsAttention` | **我们赢**（显式） |
| **对抗验证** | **缺失**：无 Verifier Worker | **Phase 1 进行中**：独立 worktree + 反驳证据 | **我们赢** |
| **交付回执** | **缺失**：无哈希链、无离线验证 | `DeliveryReceipt`：logHash + evidenceHash + 可离线 `receipt verify` | **我们赢** |
| **证据链** | `verification_passed` 推测存在，但无哈希绑定 | 每条 evidence 带 `payloadHash`，可逐条重算 | **我们赢** |

**判断**：Codex **完全没有交付证明体系**——它的"完成"是模型自评 + 可能的云端检查，无第三方可验证性。这是我们的最大差异化。

---

### 2.4 并行与编排

| 维度 | Codex | DeepSeek Code | 胜负 |
|---|---|---|---|
| **子 Agent** | `ThreadRelationFilter::DescendantsOf`：spawn 图谱 + 父子关系 | `WorkerType`：explore/review/research/ci/**verify**（Phase 1） | 平手（都有） |
| **锦标赛** | **缺失**：无多假设并行 + 裁决机制 | **Phase 2 计划**：`arena.ts` 锦标赛 + Judge + negative evidence | **我们赢**（计划中） |
| **异步工单** | `QueueStore` + `MAX_QUEUE_ITEMS`：有排队机制 | `CIRepairQueue`：延迟到安全边界 + **Phase 2 泛化为工单系统** | 平手 |

**判断**：两者都有子 Agent，但我们的锦标赛（多假设竞争 + 败者证据）是独有设计。

---

### 2.5 安全与权限

| 维度 | Codex | DeepSeek Code | 胜负 |
|---|---|---|---|
| **审批机制** | `approval_pending / approval_resolved`：有 | `approval_pending / approval_resolved`：有 | 平手 |
| **Exec Policy** | `execpolicy` crate：声明式策略 + 前缀规则 + 网络规则 | `.deepseek/policy.json`：**Phase 5 计划**，声明式 + 污点追踪 | Codex 赢（已实现） |
| **沙箱** | `sandboxing/linux-sandbox/bwrap`：强隔离 | 无原生沙箱（依赖 macOS 权限 + 审批） | Codex 赢 |
| **污点追踪** | **缺失**：无不可信数据流标签 | **Phase 5 计划**：`TaintLabel` + 数据流策略引擎 | **我们赢**（计划中） |
| **Prompt Injection 防御** | 未见显式防御（可能在云端过滤） | **Phase 5 计划**：启发式扫描 + 污点升级 | **我们赢**（计划中） |

**判断**：Codex 的 exec policy 和沙箱已经很成熟，我们的污点追踪是更深的防线（Codex 没做）。

---

### 2.6 代码理解与上下文

| 维度 | Codex | DeepSeek Code | 胜负 |
|---|---|---|---|
| **代码图谱** | `file-search/file-system`：推测是文件级搜索，无符号图谱 | **Phase 2 计划**：`code-graph` + 符号卡 + 调用图 + 影响分析 | **我们赢**（计划中） |
| **上下文策略** | 不明确（可能在模型侧） | `context-builder.ts` + **Phase 2 升级为查询规划器** | 平手 |
| **缓存优化** | 未见显式缓存策略（依赖模型层） | 前缀稳定性纪律 + `cachedInputTokens` 度量 | **我们赢** |

**判断**：两者都没有公开的图谱能力，我们的计划（符号卡 + 影响分析）更细。

---

### 2.7 工具与能力

| 维度 | Codex | DeepSeek Code | 胜负 |
|---|---|---|---|
| **MCP 集成** | `mcp-server/rmcp-client`：原生支持 | `mcp-stdio/mcp-http/mcp-websocket`：三种传输 | 平手 |
| **LSP 集成** | `lsp-client.ts`：有 | `lsp-client.ts`：有（只暴露 diagnostics） | 平手 |
| **Git 工具** | `git-utils`：有 | `inspect_git` + worktree 支持 | 平手 |
| **浏览器验收** | 未见 | `browser_evidence`：Playwright + 截图 + console | **我们赢** |
| **CI 修复** | 未见 CI 特化能力 | `github_ci_status / github_ci_failure_log` + 自动修复会话 | **我们赢** |
| **SSH 远程** | `ssh-tool-host/ssh-persistent-terminal`：有 | `ssh-tool-host/ssh-persistent-terminal`：有（同名模块） | 平手 |

**判断**：工具集相似，我们的浏览器验收和 CI 修复是独有优势。

---

## 3. 架构哲学对比

### 3.1 Codex 的设计选择

**优势：**
1. **微模块化**：100+ Rust crates，每个职责单一、可单独测试。
2. **强类型 + 所有权**：Rust 的内存安全 + 并发安全免费获得。
3. **Exec Policy 成熟**：声明式策略 + 沙箱集成已生产就绪。
4. **多平台沙箱**：Linux bwrap + macOS sandbox-exec（推测）。
5. **云原生**：`backend-client / cloud-config / cloud-tasks`，云端能力可按需注入。

**劣势：**
1. **无交付证明**：没有哈希链、没有可验证回执——"完成"是黑盒。
2. **无确定性回放**：不能重放会话验证一致性，调试 Agent 行为靠日志肉眼。
3. **无对抗验证**：模型自评，无独立 Verifier 反驳。
4. **无污点追踪**：prompt injection 防御只能靠模型层（如果有的话）。
5. **Rust 门槛**：贡献者需要 Rust 熟练度，生态扩展成本高（对比 TS 的 npm 生态）。

---

### 3.2 DeepSeek Code 的设计选择

**优势：**
1. **事件溯源 + 投影**：JSONL 真源 + SQLite 物化视图，架构清晰可审计。
2. **确定性回放**：录制模型流 + 工具参数，可逐字节重放验证。
3. **交付回执**：哈希链 + 离线验证，第三方可独立复核——**竞品无人能做**。
4. **对抗验证（Phase 1）**：Verifier Worker 独立 worktree 反驳，结构性提高可靠性。
5. **TS/Bun 生态**：零依赖编译 + npm 工具生态 + 低贡献门槛。
6. **锦标赛设计（Phase 2）**：多假设并行 + 败者证据，难题成功率结构性更高。
7. **污点追踪（Phase 5）**：数据流安全，prompt injection 架构上骗不了。

**劣势：**
1. **单平台优先**：macOS 深耕，Windows/Linux 靠社区（Codex 三平台齐全）。
2. **沙箱弱**：无原生沙箱，依赖权限审批（Codex 有 bwrap）。
3. **Exec Policy 待做**：Phase 5 才接入，Codex 已生产就绪。
4. **模块化不如 Rust**：单体 main.ts（虽然可控，但 100+ crates 的测试隔离更好）。

---

## 4. 战略判断

### 4.1 Codex 想赢什么

从代码推测：

- **云本地优先**：`backend-client / cloud-tasks` 暴露了 OpenAI 的真实意图——本地 CLI 是前端，云端能力是后端，最终盈利在 API 用量。
- **企业安全**：exec policy + 沙箱 + 多平台 = 面向企业部署，安全合规是卖点。
- **生态锁定**：MCP + 多 SDK = 让第三方工具接入 Codex 生态，而非对抗。
- **开源营销**：Apache-2.0 + 110k stars = 品牌传播 + 社区贡献，实际控制权在 OpenAI（云端闭源）。

### 4.2 我们的差异化路径

**不跟 Codex 正面刚的地方：**

- **不做多平台沙箱**：成本高、收益低，macOS 深耕 + 审批机制已够。
- **不做微服务化**：单体架构配合事件溯源，调试与审计更简单。
- **不做云依赖**：本地优先是定位，Codex 的云能力是它的，也是它的包袱。

**只有我们能赢的地方（Codex 架构上做不到）：**

1. **交付回执 + 离线验证**：哈希链 + 可第三方复核 = 信任的密码学对象。企业采购、外包验收、开源 maintainer 审查 AI PR——全是真实付费场景，Codex 给不了。
   
2. **确定性回放 + Shadow Eval**：任意会话可重放 = prompt/上下文策略可离线迭代。Codex 调 prompt 只能线上 A/B，我们可以拿历史会话跑对照——**迭代速度数量级差异**。

3. **对抗验证（Verifier Worker）**：独立 worktree + 反驳证据 = 结构性降低漏检。Codex 的"完成"是模型自评，我们的"完成"是经过反驳者验证的证明——seeded-bug 语料上这是可量化的成功率差距。

4. **锦标赛 + 败者证据**：多假设并行 Codex 也能做（spawn 多个 thread），但它没有 Judge + negative evidence 机制——我们不仅知道哪条路对，还知道为什么别的路不通，这是上下文质量的结构性提升。

5. **污点追踪 + 数据流策略**：Codex 的 exec policy 只能管"能不能跑这条命令"，管不了"这条命令的参数是不是被 prompt injection 污染的"。我们的污点标签 + 策略引擎是**数据流级防御**，架构上更深。

---

## 5. 对 NEXT_GEN_ARCHITECTURE.md 的影响

### 5.1 Phase 优先级调整

**不变（继续推进）：**

- **Phase 1（Fork + Replay + Verifier）**：Codex 没有回放和对抗验证，这是我们最大差异化，必须做满。
- **Phase 2（锦标赛 + 代码图谱）**：Codex 没有多假设裁决，没有符号级图谱，继续做。
- **Phase 5（污点追踪）**：Codex 的 exec policy 不做数据流，这是我们独有防线。

**降低优先级（Codex 已有且成熟）：**

- **Exec Policy**：Codex 的 `execpolicy` crate 已经很成熟（前缀规则 + 网络规则 + 声明式 + 沙箱迁移），我们的 Phase 5 可以**参考它的 DSL 设计**，但不必重新发明轮子。建议：直接兼容 Codex 的 policy 格式（或子集），降低用户迁移成本。
  
- **沙箱**：Codex 有 bwrap（Linux）+ sandbox-exec（macOS 推测），我们短期内追不上。建议：Phase 5 的沙箱部分**降为可选**，主打污点追踪（Codex 没有）。

### 5.2 新增对标项

**README.md 与 FULL_SPECTRUM_DOMINANCE.md 补充：**

| 能力 | Codex | DeepSeek Code | 备注 |
|---|---|---|---|
| 确定性回放 | ❌ | ✅ Phase 1 | 我们独有 |
| 交付回执（离线验证） | ❌ | ✅ Phase 0 v0 → Phase 1 v1 | 我们独有 |
| 对抗验证（Verifier） | ❌ | ✅ Phase 1 | 我们独有 |
| 污点追踪 | ❌ | 🔄 Phase 5 | 我们独有 |
| Exec Policy | ✅ 成熟 | 🔄 Phase 5（参考 Codex DSL） | Codex 领先 |
| 沙箱（Linux/macOS） | ✅ bwrap + sandbox-exec | ❌ | Codex 领先 |
| 多假设锦标赛 | ❌ | 🔄 Phase 2 | 我们独有 |
| 代码符号图谱 | ❌ | 🔄 Phase 2 | 平手（都没做） |
| 浏览器验收 | ❌ | ✅ | 我们领先 |
| CI 修复会话 | ❌ | ✅ | 我们领先 |

---

## 6. 给 Phase 1 实施的启示

现在正在做 Verifier Worker + Gate v2。Codex 的代码告诉我们：

**可以借鉴的：**

1. **Worktree 隔离**：Codex 的 `sandboxing` 思路和我们的 `git/worktree.ts` 一致，继续用独立 worktree 跑 Verifier。
2. **Turn 边界**：Codex 的 `TurnPage` 分页 + `TurnStatus` 已经很清晰，我们的 `turn_ended` 事件可以对标。
3. **Reservation 模式**：Codex 的 `PreparedFork._source_reservation` 阻止源删除，我们的 `session_forked` 标记是懒加载等价，都合理。

**不要学的：**

1. **不做 Rust 重写**：Codex 的微模块化很美，但 TS + Bun 的迭代速度和生态是我们的优势，不要动摇。
2. **不做云依赖**：Codex 的 `backend-client` 是它的商业模式，我们的本地优先是差异化，守住。
3. **不做"等价但更复杂"的设计**：Codex 有些地方过度工程化（100+ crates 的依赖图对单人项目是负担），我们保持简洁。

---

## 7. 结论

### 7.1 Codex 开源的真实意图

- **品牌营销**：110k stars = 开发者心智占领。
- **生态锁定**：MCP + SDK = 让第三方工具接 Codex，而非接 Claude Code 或我们。
- **云服务导流**：本地 CLI 是钩子，真实盈利在 OpenAI API 用量 + 企业版订阅。
- **竞争封锁**：开源基础能力 = 让后来者（如我们）"看起来没差"，但核心差异化（交付证明、回放、对抗验证）它没做 = **故意留的空白**。

### 7.2 我们的应对

**短期（Phase 1-2，2 个月）：**

- **死磕 Verifier + 回放 + 回执**：这三件事 Codex 架构上做不到，做满了就是护城河。
- **seeded-bug 语料**：准备 20+ 个注入缺陷的修复任务，量化 Verifier 拦截率 vs Codex 自评漏检率 = 可传播的 benchmark。
- **离线验证 demo**：录一个视频：`receipt verify` 在没有 DeepSeek Code 的机器上独立复核一个交付回执 = 可演示的信任。

**中期（Phase 3-5，3-4 个月）：**

- **锦标赛 + 代码图谱**：Codex 没做，我们做了 = 难题成功率 +10pp 的 benchmark。
- **污点追踪**：参考 Codex 的 exec policy DSL（兼容它的格式子集），但加上数据流标签 = 架构更深的防线。
- **ACP 适配器**：让 Zed/Neovim 通过 ACP 用上我们的回执和门禁 = Codex 的 ACP 后端给不了的能力。

**长期（持续）：**

- **社区传播**：安全研究员 + 企业采购 + 开源 maintainer = 三个圈层，主打"可审计、可证伪、可离线验证"。
- **Benchmark 持续更新**：每次 Codex 发版，跑一遍 seeded-bug + versus 对比 = 保持量化领先可见。

---

**一句话总结**：Codex 开源了"做 Agent 的标准姿势"（沙箱、MCP、exec policy），但**故意没做**交付证明、确定性回放、对抗验证——这些是我们的杀手锏，继续死磕 Phase 1-2，用 benchmark 说话。
