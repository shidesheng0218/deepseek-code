# DeepSeek Agent Runtime — IPC 协议规范

版本：**2.0**（`deepseek-agent-runtime/0.2.0`）

---

## 概述

运行时（sidecar）与 CLI（或其他客户端）之间通过 **stdio JSONL** 通信：每条消息一行，UTF-8 编码，无嵌套换行。客户端向 sidecar 的 stdin 写入请求，sidecar 向 stdout 写入响应和事件帧。

```
cli stdin  →  [ Request\n ]
cli stdout ←  [ Response\n | EventFrame\n | ... ]
```

---

## 帧格式

### 请求（客户端 → 运行时）

```ts
{
  id:     string        // 客户端生成的唯一 ID，用于匹配响应
  method: string        // 见下方方法表
  params: object        // 方法特定参数（可选字段依方法而定）
}
```

### 响应（运行时 → 客户端）

```ts
{
  id:        string     // 对应请求的 id
  type:      "response"
  ok:        boolean
  result?:   unknown    // 成功时的载荷（结构依方法而定）
  error?:    string     // ok=false 时的错误描述
  sessionID?: string    // 会话相关方法附带
}
```

### 事件帧（运行时 → 客户端，仅 session.run / session.recover 期间）

```ts
{
  id:        string     // 对应 session.run 请求的 id
  type:      "event"
  ok:        true
  sessionID: string
  event:     RuntimeEvent
}
```

---

## 方法一览

| 方法 | 描述 | 自版本 |
|---|---|---|
| `health` | 获取运行时版本与能力列表 | 1 |
| `session.run` | 启动新会话并流式输出事件 | 1 |
| `session.enqueue` | 向已有会话追加输入 | 1 |
| `session.recover` | 恢复中断的会话 | 1 |
| `session.resolveApproval` | 批准或拒绝工具调用 | 1 |
| `session.cancel` | 取消活跃会话 | 1 |
| `session.fork` | 从指定序列号分叉出子会话 | 2 |
| `session.branches` | 列出会话的所有分叉 | 2 |
| `session.replay` | 回放会话并校验门禁状态 | 2 |

---

## `health`

**用途：** 版本握手。客户端应在建立连接后优先调用此方法，根据 `methods` 列表判断哪些功能可用，从而决定是否降级。

请求参数：无。

响应 `result`：

```ts
{
  version:         string      // "deepseek-agent-runtime/0.2.0"
  protocolVersion: number      // 整数，当前为 2
  methods:         string[]    // 本运行时支持的完整方法名列表
  features:        string[]    // 功能标签，见下表
}
```

功能标签：

| 标签 | 含义 |
|---|---|
| `fork` | 支持 session.fork |
| `branches` | 支持 session.branches |
| `replay` | 支持 session.replay |
| `delivery-receipt` | 支持交付回执（hash-chained 日志） |
| `session-projection` | 支持会话投影 / 上下文压缩 |

### 旧 CLI 降级规范

旧版 CLI（`protocolVersion < 2`）调用 `session.fork`、`session.branches` 或 `session.replay` 时，运行时会返回：

```json
{
  "ok": false,
  "error": "Unsupported method: session.fork (call \"health\" for the capability list)"
}
```

建议客户端在调用任何版本 2 方法前先检查 `health` 的 `methods` 列表：

```js
const { result } = await sidecar.request("health", {});
if (!result.methods.includes("session.fork")) {
  console.error("当前 sidecar 不支持 fork，请升级运行时");
  process.exit(1);
}
```

---

## `session.run`

启动一次新的 agent 会话。在会话期间，运行时会向客户端推送若干 `event` 帧，最后以一个 `response` 帧结束。

关键参数（`params`）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `sessionID` | string | 客户端指定的会话 ID（`[A-Za-z0-9._-]+`） |
| `prompt` | string | 用户输入 |
| `projectPath` | string | 工作区根目录绝对路径 |
| `baseURL` | string | LLM API 基址 |
| `apiKey` | string | API 密钥（运行时内部使用，不记录日志） |
| `model` | string | 模型名称 |
| `protocol` | string | `"openai-compatible"` 或 `"anthropic-messages"` |
| `mode` | string | `"auto"` \| `"careful"` \| `"yolo"` |

---

## `session.fork`

从父会话的指定序列号创建子会话，子会话继承截至该点的消息历史。

参数：

| 字段 | 类型 | 说明 |
|---|---|---|
| `sessionID` | string | 父会话 ID |
| `baseSequence` | number? | 分叉点（省略则取最新） |
| `reason` | string? | 分叉原因（记录在子会话元数据） |

响应 `result`：

```ts
{
  sessionID:         string  // 新子会话 ID
  sourceSessionID:   string
  baseSequence:      number
  inheritedMessages: number
}
```

---

## `session.replay`

以只读模式重跑会话，重算门禁状态并与原始记录对比。

参数：

| 字段 | 类型 | 说明 |
|---|---|---|
| `sessionID` | string | 要回放的会话 ID |
| `untilSequence` | number? | 只回放到指定序列号 |

响应 `result`：

```ts
{
  matched:       boolean | null  // null 表示无原始门禁记录可对比
  gateState:     string
  recordedState: string?
  eventCount:    number
  turns:         number
}
```

---

## 未知方法

运行时在 `handle()` 末端对所有未被明确分支处理的方法统一返回：

```json
{ "ok": false, "error": "Unsupported method: <method> (call \"health\" for the capability list)" }
```

客户端不应依赖沉默（无响应）来检测不支持的方法。

---

## 会话 ID 约束

所有 `sessionID` 必须匹配正则 `^[A-Za-z0-9._-]+$`。运行时对不合法 ID 返回 `ok: false`，CLI 应在发送前校验。

---

## 变更历史

| 版本 | 变更 |
|---|---|
| 1 | 初始 stdio JSONL 协议，基本 session.run / enqueue / cancel |
| 2 | 新增 session.fork / branches / replay；health 暴露 capabilities；未知方法显式报错 |
