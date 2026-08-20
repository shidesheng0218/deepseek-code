# bench:versus —— 同模型对照基准台（证据机）

> 文档地位：[../FULL_SPECTRUM_DOMINANCE.md](../../FULL_SPECTRUM_DOMINANCE.md) 战线 A1。
> 没有这台证据机，任何"碾压/领先"都只是自述。

把同一批真实任务同时交给 DeepSeek Code 与竞品 harness（Claude Code / Codex / OpenCode），
在**同题、同机、同模型**约束下度量：成功率 / 审批次数 / Token / 成本 / 耗时。
成功判定不看 harness 自述——每个运行结束后在隔离工作区执行任务的 `verify` 命令。

## 运行

```bash
# 离线自检（不需要任何 API Key）：先跑这两个确认管线健康
node benchmarks/versus/run.mjs --check-corpus   # 语料完整性（bug 类任务原始状态必须验证失败）
node benchmarks/versus/run.mjs --self-test      # echo 替身验证编排/验证/报告管线

# 真实对照（需要各家 CLI 与凭据）
node benchmarks/versus/run.mjs                                # 全部已安装 harness
node benchmarks/versus/run.mjs --harness=deepseek,claude-code # 指定子集
node benchmarks/versus/run.mjs --task=vs-001-cart-total --runs=3
npm run bench:versus
```

产出：`benchmarks/results/versus/<timestamp>/` 下 `report.md`（对照表）、
`report.json`、`results.jsonl` 与 `transcripts/`（各 harness 原始记录）。
`--sign` 用 minisign 给 report.md 签名（密钥默认 `~/.tauri/deepseek-code.key`，
与发布签名同一纪律）。

## 同模型纪律

harness 差异的唯一诚实度量是控制模型不变。`versus.config.json`：

- `harnesses.deepseek`：我们的 sidecar 走 BYOK，`protocol/baseURL/model/apiKeyEnv`
  指向任一 OpenAI-compatible 或 Anthropic 端点；**API Key 只从环境变量读取**。
- 其余 harness 用各自 CLI 的模型参数。**改完配置必须同步更新 `modelLabel`**——
  报告顶部如实展示本次运行的模型口径。
- Codex 仅支持 OpenAI 系模型：与 Anthropic 系对照时它天然跨模型，
  报告中按登记的 model 标注，不纳入"同模型"结论。

### 用 Kimi 跑对照（推荐的首跑配置）

仓库默认配置就是 Kimi K2 同模型对照：

1. `export MOONSHOT_API_KEY=sk-...`（[platform.moonshot.cn](https://platform.moonshot.cn) 控制台申请）。
2. `harnesses.deepseek` 走 OpenAI-compatible：`https://api.moonshot.cn/v1`（国际站 `https://api.moonshot.ai/v1`）。
3. `harnesses.claude-code` 通过 `env` 映射把 Claude Code CLI 指到 Moonshot 的
   Anthropic 兼容端点：`ANTHROPIC_BASE_URL` 为字面量，`ANTHROPIC_AUTH_TOKEN` 用
   `$MOONSHOT_API_KEY` 从环境变量引用——**密钥永不写入配置文件**。
   任何 harness 引用了未设置的环境变量，该 harness 会被跳过并注明原因。
4. 模型名以 Moonshot 控制台为准（`kimi-k2-0905-preview` / turbo / 更新版本），
   改模型名时两边 harness 同步改。
5. 成本列需要先按控制台价格填 `pricePerMToken`；不填则如实显示 `—`。

先单题冒烟再全量：`node benchmarks/versus/run.mjs --harness=deepseek --task=vs-001-cart-total`

已验证可用（2026-08-20）：`kimi-k2.7-code` + `https://api.moonshot.cn/anthropic` 端点，
`claude` CLI 2.1.237。注意 claude-code 上报的 `total_cost_usd` 按其内部 Anthropic
价目表计算，对 Kimi 失真——配置里 `trustReportedCost: false` 会将其置空，
跨 harness 成本比较一律用 token 口径。

## 语料任务格式

```jsonc
{
  "id": "vs-001-cart-total",
  "category": "bug_fix",                    // bug_fix / feature_add / refactor / ...
  "project": "projects/cart-total",         // corpus/ 下的夹具项目（自包含，node --test 可跑）
  "prompt": "……交给 harness 的任务描述……",
  "verify": { "command": "npm test", "expectExitCode": 0 },
  "expect": { "pristineFails": true },      // bug 类任务：原始项目必须验证失败（--check-corpus 断言）
  "timeoutMs": 300000
}
```

起步语料 16 题（bug_fix 12 / feature_add 2 / refactor 2），全部零外部依赖，
且每题都经过双向校验：**原始项目验证必失败（bug 真实存在）、参考修复必通过**。
真实 issue 语料（≥60 题）按作战方案 Q1 节奏扩充；新增任务先过 `--check-corpus`。

## 指标口径

| 指标 | 口径 |
| --- | --- |
| 成功率 | verify 命令退出码 0 的运行 / 总运行（跳过不计入） |
| 审批次数 | deepseek：`approval_required` 事件；claude-code：`permission_denials` 长度；其余不可得即 null |
| Token | deepseek：`usage_recorded` 求和；claude-code：`usage` 字段；codex：JSONL usage 事件（防御解析） |
| 成本 | driver 上报优先（claude `total_cost_usd`）；否则按 `pricePerMToken` 换算 |
| 均摊成本/成功 | 总成本 / 成功数（cost-per-solved-task，战线 C 的 headline 指标） |
| 度量覆盖 | tokens/cost/approvals 有数据的运行占比——报告必展示，缺口不允许隐形 |

## 已知测量边界（诚实清单）

- 各家 headless 模式的自主档位语义不同（我们 `auto` vs Claude `acceptEdits` vs Codex `--full-auto`），
  审批口径只能近似对齐，报告页脚会注明。
- 单次运行存在模型抖动：正式对照用 `--runs=3` 以上取中位，季度发布前跑全量。
- versus 是度量不是门禁：对照运行退出码恒为 0，结论由人（和发布评审）读报告下。
