# DeepSeek Code Desktop

一个面向个人开发者的、本地优先的 DeepSeek 编码代理桌面应用。它采用 Session 驱动的工作流，目标是将对话、计划、权限审批、文件修改、Git Worktree、Diff 审查、终端与浏览器验证整合到一个轻量桌面工作台中。

> 这是一个非官方开源项目，与 DeepSeek 无隶属关系。

## 下载使用

普通用户不需要安装 Node、Swift，也不需要运行终端命令：

1. 打开 [GitHub Releases](https://github.com/shidesheng0218/deepseek-code/releases/latest)。
2. 下载 `DeepSeek-Code-<version>-arm64.dmg`。
3. 打开 DMG，把 **DeepSeek Code.app** 拖到 **Applications**，然后双击启动。
4. 首次启动如果 macOS 提示无法验证开发者，右键 App 选择“打开”，确认一次即可；这只适用于未配置 Apple Developer ID 的社区构建。

启动后只需配置 **Base URL、API Key 和项目目录**。开发工具链和发布流程由项目维护者处理，用户不需要配置证书、公证或 GitHub Actions。

当前 Release 是 Apple Silicon（arm64）版本，要求 macOS 14 或更高版本。

## 当前产品真源

正式产品是 **SwiftUI + DeepSeekCodeCore 的原生 macOS App**，面向 Apple Silicon、macOS 14+。

- `macos/DeepSeekCode`：唯一正式运行时、构建入口与发布产物来源。
- `src/`：历史 Electron/React 实现，仅保留作迁移与兼容参考；不再作为正式应用功能入口。
- 每次发布均写入唯一 Build Stamp，并通过原子替换刷新 `/Applications/DeepSeek Code.app`。

## 当前实现

- 原生 SwiftUI 三栏工作区：Session、Conversation、Workspace 与 Inspector。
- 中文优先的 Session、计划、工具活动、Diff、Browser 和 Review 界面。
- Plan / Manual / Accept Edits / Auto 四种权限模式。
- 细粒度命令风险分类和审批决策。
- SQLite Session 事件存储，可用于事件回放和恢复。
- OpenAI-compatible / DeepSeek-compatible 流式 Chat Completions 客户端。
- 按功能分层的 Token、缓存 Token、延迟与费用账本。
- 工作区路径隔离、符号链接逃逸防护和行范围读取。
- Git Worktree 服务：创建受管理的 `deepseek/<task>` 分支与独立工作树。
- Provider 设置页：Base URL + API Key 开箱配置；模型、协议和能力测试位于高级设置。
- API Key 通过 Keychain/本地受保护 Secret Store 保存，SQLite 仅保留引用。
- Agent IPC 执行闭环：模型流 → 工具调用 → 风险/审批 → 文件、Git、命令工具 → 脱敏事件回传。
- 文件工具支持原子 Patch、乐观哈希、检查点恢复，以及目录/符号链接工作区隔离。
- 真实本地项目选择与 Composer 任务发送入口。
- `DeepSeekCodeCore` 提供 Durable Session、Provider、Keychain、事件流、权限、Workspace、Git、Review、Skills、MCP、Hooks、Browser、Terminal 与 SSH 运行时。
- Composer 已接入真实 DeepSeek/OpenAI-compatible SSE 与 Anthropic Messages，支持工具审批、Token/费用和延迟审计。

## 本地开发

```bash
cd macos/DeepSeekCode
swift run DeepSeekCode
```

生成可分发的 macOS `.app`：

```bash
./scripts/build-macos-app.sh
```

构建产物位于 `dist/DeepSeek Code.app`；设置 `APPLE_CODESIGN_IDENTITY` 后脚本会执行 Hardened Runtime 签名。

当前 SwiftUI 工程可使用 Command Line Tools 编译。用户下载版不走 App Store，而是通过 GitHub Releases 发布 `.dmg`：

```bash
RELEASE_VERSION=0.1.0 \
BUILD_NUMBER=1 \
APPLE_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE=1 \
./scripts/package-macos-release.sh
```

脚本会生成：

- `DeepSeek-Code-<version>-arm64.dmg`：拖入 Applications 的安装包；
- `SHA256SUMS.txt`：下载完整性校验；
- `release-metadata.json`：版本、构建号、签名/公证状态。

没有 Developer ID 时也可以发布 GitHub Release。该包会标记为 `github-adhoc`，用户首次打开可能需要右键“打开”，或在“系统设置 → 隐私与安全性”中确认。配置 Developer ID 后，包会标记为 `developer-id-signed-unnotarized`；同时配置公证凭据后，包会标记为 `developer-id-notarized`。

GitHub Actions 在推送 `v*.*.*` 标签时自动执行 Swift 检查、SSH 回环验证、DMG 打包和 GitHub Release 上传。Developer ID 签名和 Apple 公证是可选增强项：

`APPLE_CERTIFICATE_BASE64`、`APPLE_CERTIFICATE_PASSWORD`、`APPLE_SIGNING_IDENTITY`、`APPLE_TEAM_ID`、`APPLE_ID`、`APPLE_APP_SPECIFIC_PASSWORD`。

其中 `.p12` 证书只以 Base64 Secret 保存，不要提交到仓库。没有这些 Secrets 时，Actions 仍会发布 `github-adhoc` 下载包；只配置证书会发布已签名但未公证的包；配置证书和 Apple 公证凭据才会发布公证包。

本地发布工件可用以下命令验收：

```bash
npm run release:test
```

下载 GitHub Release 后，用户可校验：

```bash
shasum -a 256 -c SHA256SUMS.txt
```

历史 Electron 代码的 Node 命令仍可用于迁移检查，但不代表正式 App 行为。

## DeepSeek 接入

核心客户端使用 OpenAI-compatible Chat Completions 约定：

- Base URL：`https://api.deepseek.com/v1/` 或用户自定义兼容端点。
- API Key：仅通过 Swift 原生端 Keychain/受保护 Secret Store 保存；不要写入仓库、日志、SQLite 或 UI 事件。
- 主 Agent 使用高能力模型；Explore、摘要和轻量任务可路由至更快模型。
- 每个请求均应设置按功能区分的 `max_tokens`，并记录输入、缓存输入、输出 Token 与费用。

## 当前命令风险策略

| 风险 | 典型操作 | 默认行为 |
|---|---|---|
| L0 | 搜索、读取、Git 状态 | 自动允许 |
| L1 | 补丁、测试、Lint、构建 | Accept Edits / Auto 允许 |
| L2 | 安装依赖、联网、Commit、Push | 请求确认 |
| L3 | 删除、权限变更、工作区外写入 | 阻止或强确认 |
| L4 | `sudo`、磁盘擦除、强制推送、破坏性递归删除 | 直接阻止 |

## 发布硬化中的工作

- 真实 SSH Sandbox 的长期断线重连验收。
- 30 个端到端联网修复任务和 5 个 CI 修复任务基准。
- 完整 XCUITest、故障注入、签名、公证与自动更新回滚验证。
- Windows/Linux、产品云、团队账号、手机远控和无人监管系统自动化不在 1.0 范围内。

## 验证

当前测试覆盖权限策略、使用量计费、Session 事件回放、SQLite 存储、DeepSeek/OpenAI-compatible SSE、工作区隔离、Agent 审批状态机、Git Worktree 和关键 UI 交互。
