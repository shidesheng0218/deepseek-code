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
deepseek ask <prompt>                 执行一次任务
deepseek run <prompt>                 ask 的脚本友好别名
deepseek session list                 列出 Session
deepseek session resume <id>          恢复 Session
deepseek session attach <id>          查看 Session 事件日志
deepseek session fork <id>            从 Session 创建分支
deepseek session branches <id>        列出 Session 分支
deepseek session replay <id>          回放 Session
deepseek doctor                       检查 runtime
deepseek receipt verify <file>        离线校验交付回执
deepseek --help                       查看完整选项
deepseek --version                    查看版本
```

Session 日志默认保存在 `DEEPSEEK_SESSION_ROOT` 指定的目录；未设置时使用用户数据目录。未知副作用不会自动重放。

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
