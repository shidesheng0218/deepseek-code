# DeepSeek Code 基准评测

对真实任务量化「成功率 / 审批次数 / Token 成本 / 交付门禁」，
用于与 Claude Code、Codex 等同题对照。不是单元测试的替代品，
而是发布门槛：**宣称"超过"前必须在这里拿到证据**。

## 结构

```
benchmarks/
  fixtures/            任务定义（JSON），按类别编号
  runner.mjs           驱动 sidecar 执行任务并采集事件
  score.mjs            汇总事件日志，计算通过率与成本
  results/             运行输出（gitignored）
```

## Fixture 格式

```json
{
  "id": "qa-001",
  "category": "direct_answer",
  "prompt": "TypeScript 里 unknown 和 any 有什么区别？",
  "expect": {
    "route": "direct_answer",
    "noToolCalls": true,
    "maxApprovals": 0,
    "delivery": "delivered"
  }
}
```

`expect` 支持的断言：

- `route`：`decision_made` 事件的路由值
- `noToolCalls`：全程不得出现 `tool_started`
- `maxApprovals`：`approval_required` 事件数量上限
- `delivery`：最终 `delivery_evaluated` 状态
- `mustMention`：最终回答必须包含的关键词
- `maxOutputTokens`：输出 token 上限（需要真实 Provider）

## 运行

```bash
# 使用内置 mock Provider（确定性，验证评测框架本身）
node benchmarks/runner.mjs

# 使用真实 BYOK Provider（验证真实质量）
DEEPSEEK_API_KEY=... node benchmarks/runner.mjs --real

# 汇总最近一次的运行结果
node benchmarks/score.mjs
```

## 发布门槛（与方案锁定）

- 完整任务成功率点估计 ≥ 对手 +3pp（60 题语料齐备后生效）
- 低风险任务审批次数 ≤ Claude Code 的 60%
- 崩溃恢复率 100%，未知副作用自动重放为 0
- 研究任务 Citation 覆盖率 ≥ 95%

当前语料为起步集（8 题），覆盖直接问答、项目理解、
代码修改、联网研究四类路由断言；Browser/SSH/CI 类 fixture
在对应 harness 可脚本化后加入。
