# DeepSeek Code CLI

[![CI](https://github.com/shidesheng0218/deepseek-code/actions/workflows/macos.yml/badge.svg)](https://github.com/shidesheng0218/deepseek-code/actions/workflows/macos.yml)
[![Release](https://img.shields.io/github/v/release/shidesheng0218/deepseek-code?display_name=tag)](https://github.com/shidesheng0218/deepseek-code/releases)

本项目是一个本地优先的终端编码 Agent。它通过 OpenAI-compatible Chat Completions 或 Anthropic Messages 调用你选择的模型，在项目目录内执行工具、维护可恢复 Session，并保留事件日志与交付证据。当前产品是 **CLI**，不再维护桌面应用。

> 这是非官方开源项目，与 DeepSeek 无隶属关系。API 凭据只通过环境变量提供，不要把密钥写入仓库、Session 或日志。

## 快速开始

需要 Node.js 22.18 或更高版本。Apple Silicon 本地 runtime 编译使用 Bun 的 macOS arm64 可选包。

```bash
npm ci
npm run build
npm link

deepseek doctor
deepseek chat
# 或者
deepseek ask "解释这个项目的认证流程" --project "$PWD"
```

凭据和连接设置使用环境变量：

```bash
export DEEPSEEK_API_KEY="..."
export DEEPSEEK_BASE_URL="https://api.deepseek.com/v1"
export DEEPSEEK_MODEL="deepseek-chat"
export DEEPSEEK_PROJECT="$PWD"
```

支持 `DEEPSEEK_PROTOCOL=openai-compatible` 或 `DEEPSEEK_PROTOCOL=anthropic-messages`。也可以在命令行使用 `--project`、`--model`、`--base-url`、`--protocol`、`--mode` 和 `--session` 覆盖默认值。例如 `cat task.txt | deepseek ask`。管道输入可直接传给 `deepseek ask` 或 `deepseek run`。

## 命令

```text
deepseek chat                         进入交互式会话（默认命令）
deepseek ask <prompt>                 执行一次任务（支持 --json）
deepseek run <prompt>                 ask 的脚本友好别名
deepseek init                         首次配置引导（交互式）
deepseek config list|get|set|unset    分层配置（用户级/项目级）
deepseek doctor [--json]              诊断 runtime、凭据与端点连通性
deepseek diff [--stat] [--json]       查看工作区变更
deepseek checkpoint [list|show|undo]  任务检查点管理
deepseek undo <checkpoint-id>         安全撤销 Agent 修改（用户后改过的文件不覆盖）
deepseek review [--json]              只读审查当前工作区 diff（plan 模式，不改文件）
deepseek task submit [--priority N]   提交后台任务到队列
deepseek task list [--json]           查看任务队列
deepseek task cancel <ticket-id>      取消任务
deepseek mcp list [--json]            项目 MCP 服务器（密钥脱敏）
deepseek skills list [--json]         可用 skills
deepseek detect                       检测项目 test/build/lint/typecheck 命令
deepseek session list [--json]        列出 Session（轮次/状态/标题）
deepseek session show <id>            Session 详情（待审批、项目、状态）
deepseek session search <keyword>     按标题或 ID 搜索
deepseek session rename <id> <title>  重命名
deepseek session archive <id>         归档
deepseek session attach <id>          查看 Session 对话回放
deepseek session resume <id>          恢复 Session（含待审批续跑）
deepseek session fork|branches|replay Session 分叉与回放
deepseek receipt verify <file>        离线校验交付回执
deepseek --help / --version           帮助与版本
```

配置优先级：命令行参数 > 环境变量 > 项目 `.deepseek/config.json` > 用户 `~/.config/deepseek/config.json` > 默认值。API Key 只通过环境变量提供，不写入配置文件。

`deepseek ask --json` 输出稳定结构（`sessionID`、`status`、`text`、`delivery`、`tools`、`error`），可供脚本与 `jq` 消费。

退出码：`0` 正常完成；`1` 执行失败或运行时崩溃；`2` 参数/配置错误；`3` 需要人工审批（非交互模式）；`4` 用户取消；`5` CLI 与 Runtime 协议不兼容；`6` 交付门禁未通过（needsRepair/needsAttention）。

`deepseek ask` 支持 `--repair-attempts N`（交付门禁未过时自动追加修复轮，超预算后停止并输出证据）与 `--verify`（任务完成后运行 `DEEPSEEK_VERIFY_COMMAND` 指定的项目检查命令作为交付证据）。`deepseek detect` 可自动识别 npm/pnpm/yarn/bun、Cargo、Go、Python 项目的检查命令。

每个 `session.run` 前自动创建工作区检查点（git 跟踪文件 + 会话涉及文件的哈希与内容快照），存储在项目 `.deepseek/checkpoints/`；`deepseek undo <id>` 只恢复 Agent 改过的文件，若用户在 Agent 修改后又改了同一文件则拒绝覆盖并列出冲突。

## 本地开发

```bash
npm ci
npm run build
npm test
npm run typecheck
npm run lint
npm run test:entrypoints
```

`npm run dev` 和 `npm start` 都直接启动 `bin/deepseek.mjs`。核心运行时位于 `apps/deepseek-agent-runtime`，编译产物为 `apps/deepseek-agent-runtime/dist/deepseek-agent-runtime`。Agent 的共享实现和离线回执校验位于 `src/core`。

## 发布

`e2e/` 保留独立 Browser Evidence 夹具，不依赖已移除的桌面 UI；运行前可执行 `npx playwright install chromium`，再用 `npm run test:e2e`。

本地发布脚本会生成包含 CLI、已编译 runtime、`src/core` 和离线校验所需源文件的 macOS arm64 tar.gz：

```bash
npm run release:package
npm run release:verify
```

产物位于 `dist/`，包括压缩包、`SHA256SUMS.txt` 和 `release-metadata.json`。Bun 编译目前只支持 Apple Silicon macOS；脚本会拒绝其他本地目标，不会把 arm64 二进制错误标记成其他架构。

## 目录

```text
bin/                         CLI 与 runtime terminal client
apps/deepseek-agent-runtime/ Bun runtime 入口
src/core/                    Agent、工具、Session、证据与 Provider 核心
tests/                       核心与 CLI 测试
scripts/                     构建、发布、校验与入口检查
benchmarks/                  确定性基准与对照语料
```

历史架构材料仍保留在仓库中，但不代表当前桌面产品入口。

## 许可

MIT License。
