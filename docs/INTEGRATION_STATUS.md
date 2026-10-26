> 历史设计/状态快照：本文保留作参考，不代表当前 CLI 产品能力或交付承诺。当前入口和安装说明以 README.md 为准。

# 功能打通状态检查报告（更新于本次修复后）

上一版报告列出的四项"部分打通/需要完善"的功能，本次逐一处理完毕。
处理方式统一遵循：真做的部分诚实标注为真做，做不到的部分诚实标注为
做不到（而不是编数字冒充测过）。

## ✅ 本次处理的四项

### 1. Shadow Eval 实际重跑
**位置**：`src/core/shadow-eval.ts`

**真实边界**（必须先理解这个才知道"完成"具体指什么）：
RecordingProvider 只回放已录制的模型输出，纯回放下换指令模板/工具顺序/
模型档位不会产生任何真实差异——模型从未被重新调用过。之前的实现忽略了
这个限制，编了几乎相同的数字冒充"测过了"。

**现在的做法**：
- `contextWindowSize` 类变体是纯回放下唯一能产生真实差异的维度——用不同
  的 `ContextBudget` 重跑真实的 `buildContext()` 裁剪逻辑，作用于该会话
  真实的对话历史（`eventStore.loadConversation()`），测出真实字符数差异。
- `instructionTemplate`/`toolOrder`/`modelTier` 三类变体标 `evaluable: false`
  并给出 `inapplicableReason`，不假装测过。
- 已用真实 fixture 烟雾测试验证：baseline 60190 字符 vs smaller-context
  6019 字符，真实差异化数字。

### 2. Arena Judge 规划模型
**位置**：`src/core/arena.ts` + `apps/deepseek-agent-runtime/src/main.ts`

**发现并修复了一个更严重的问题**：`generateHypotheses` 换成真调用模型
（`feature: "plan"`）后，追查发现即使拿到了不同的假设文本，`executeTournament`
的并行执行循环里每个分支传给 `executeRun` 的 `prompt` 全都是同一个原始
`prompt`，假设文本从未真正影响执行——两个"互斥假设"分支实际在跑完全
相同的任务。已修复为 `${prompt}\n\n请按以下方向解决：${h.approach}`。

- `generateHypotheses` 现在是 `async`，接受调用方注入的 `callModel` 函数
  （main.ts 传真实 Provider.stream），无凭据/调用失败/输出格式不符时降级
  为固定模板，并标 `degraded: true` + 发出 `tournament_hypotheses_degraded`
  事件，不静默假装是模型的真实判断。
- 已用 4 个场景验证：无 callModel、callModel 抛错、真实格式化输出（正确
  解析出 2 条假设）、模型输出格式不符（正确降级）。

### 3. 沙箱 Linux 支持
**位置**：`src/core/sandbox.ts`

- 新增 `executeLinux()`：用 bubblewrap（bwrap）建 mount namespace 隔离。
  未装 bwrap 时降级为无沙箱执行（`sandboxed: false`），不静默假装隔离生效。
- **诚实边界**：本模块在 macOS 上开发，Linux 路径没有真实 Linux 环境跑过；
  bwrap 参数按其文档语义编写，未执行验证。且 bwrap 的 mount namespace
  隔离不产生类似 sandbox-exec 的结构化拒绝日志，Linux 路径的 `violations`
  恒为空数组——这是隔离机制本身的限制，不是没做。

**验证 Linux 支持的过程中，发现并修复了两个真实的、预先存在的 macOS bug**
（这两个 bug 与"要不要做 Linux"无关，是本来就存在、这次顺带测出来的）：

- **Bug A（沙箱配置文件过严，命令静默失败）**：`generateMacOSSandboxProfile`
  生成的 profile 缺少 `file-read-metadata` 和根目录 `file-read-data` 权限，
  导致 `sh` 启动时的 `getcwd`/Homebrew 环境探测被拒绝——命令要么 exit 0
  但没有任何输出，要么直接崩溃。这意味着 macOS 沙箱执行此前从未真正跑通
  过一次。已用 `/usr/bin/log stream` 实测定位到具体缺失的规则并修复，
  修复后 `echo hello` 真实打印输出、exit 0。
- **Bug B（违规检测从未生效）**：`parseViolations(stderr)` 在读一个从来
  不会包含违规信息的流——macOS sandbox-exec 的拒绝记录写进内核统一日志
  （只能用 `log show` 查），不会出现在被拒绝进程自己的 stderr 里。这个方法
  从写下的第一天起就没有真正捕获过一次真实违规。改为
  `queryViolations()`：按执行时间窗口查 `log show`，过滤掉 `/dev/dtracehelper`
  等无害噪音，正确提取真实拒绝记录。已用真实文件访问（读一个存在但不在
  白名单里的文件）验证：违规被正确检测并返回。

### 4. 内存监控清理逻辑
**位置**：`src/core/memory-monitor.ts` + `apps/deepseek-agent-runtime/src/main.ts`

**发现该模块此前完全没有被任何地方 import**——是彻底的死代码，`cleanup()`
里量的是清理前后 V8 堆大小差（几乎总是噪音），从未真正释放任何东西。

**现在的做法**：`SessionDataCleaner` 改为登记表模式——main.ts 把
`terminals`/`sshTerminals`/`mcpClients`/`lspClients` 四个真实持有子进程/
连接的 Map 注册进来，复用已有的 `activeSessions`/`queues` 空闲判定逻辑
（和 `session.cancel` 分支用的同一条判断），定期关闭空闲会话持有的资源。
已用假 registry 验证：空闲会话的资源被正确 `close()` + 从 map 移除，
忙碌会话完全不受影响。

---

## 📊 验证方式说明

以上四项均通过以下方式验证，而非仅凭 `tsc --noEmit` 报告"通过"：
（本次修复过程中发现 `apps/deepseek-agent-runtime` 目录下没有真正覆盖
`main.ts` 的 tsconfig，之前会话里报告的"编译通过"部分是在检查空文件集——
已改用显式 flag 的 `tsc` 调用 + 5 个真实 sidecar 集成测试脚本
（runtime/approval/worker/terminal/cancel）交叉验证。）

- 每项都写了独立、可复现的烟雾测试脚本，观察真实输出而非假设成功
- 重新编译 sidecar 二进制并重跑 5 个集成测试脚本，全部通过
- 涉及系统级行为（macOS sandbox-exec）的部分用系统日志（`log show`）
  交叉验证，不是只看代码逻辑"看起来对"

## 🔧 仍然诚实存在的限制（不是本次任务范围，但如实记录）

- Shadow Eval 的 `instructionTemplate`/`toolOrder`/`modelTier` 三类变体
  永远无法在纯回放下验证，需要接真实模型调用才能评估——这是架构性限制，
  不是待办事项。
- Linux 沙箱路径未在真实 Linux 环境验证过。
- Linux 沙箱的违规检测能力天生弱于 macOS（无结构化拒绝日志）。
