/**
 * Understand 阶段：把输入分类到一个确定性路由。
 * 简单问答直接回答，不进入计划或工具循环；复杂任务才升级。
 * 显式工具调用永远优先于直接回答短路径（由执行器保证）。
 */

export type TaskRoute =
  | 'direct_answer'
  | 'project_question'
  | 'exploration'
  | 'code_change'
  | 'web_research'
  | 'browser_fix'
  | 'review'
  | 'ci_repair'
  | 'delivery';

export interface TaskClassification {
  route: TaskRoute;
  isSimple: boolean;
  /** fast 模型处理分类/短答；capable 处理多轮工具与修复 */
  tier: 'fast' | 'capable';
}

const WEB_INTENT = /(?:联网|上网|搜索|查一下|查询|最新|现在的|今天|实时|官方文档|documentation|docs|search the web|look up|latest)/i;
const EXTERNAL_REALTIME = /(?:天气|股价|新闻|汇率|比分|票房|release|版本发布|breaking change)/i;
const PROJECT_QUESTION = /(?:这个项目|当前项目|本仓库|当前仓库|工作区|构建入口|怎么构建|怎么运行|用什么框架|什么状态管理|技术栈|目录结构)/i;
const EXPLORATION = /(?:探索|梳理|了解|熟悉|读懂|分析.*(?:结构|架构|代码)|walk\s*through|explore)/i;
const CODE_CHANGE = /(?:修复|修改|改一下|重构|实现|新增|添加|删除|优化|fix|refactor|implement|add|remove|update|rewrite)/i;
const BROWSER_FIX = /(?:页面|浏览器|白屏|样式|点击|控制台报错|console\s*error|network|dom)/i;
const REVIEW = /(?:review|代码审查|检查一下.*(?:问题|风险)|看看有没有|安全性|走查)/i;
const CI_REPAIR = /(?:ci\s*失败|构建失败|流水线|actions.*失败|github actions|测试挂了|test.*fail)/i;
const DELIVERY = /(?:提交|commit|推送|push|创建\s*pr|发\s*pr|pull request|merge|交付|部署)/i;

/** 短且无动作词的输入视为简单问答 */
function looksSimple(text: string): boolean {
  const trimmed = text.trim();
  if (trimmed.length > 60) return false;
  return !CODE_CHANGE.test(trimmed) && !EXPLORATION.test(trimmed) && !DELIVERY.test(trimmed);
}

export function classifyTask(input: string): TaskClassification {
  const text = input.trim();
  if (!text) return { route: 'direct_answer', isSimple: true, tier: 'fast' };

  // 显式“探索/梳理”动词优先，避免被“当前仓库/构建入口”等项目词抢占
  if (EXPLORATION.test(text)) return { route: 'exploration', isSimple: false, tier: 'capable' };
  // 明确的本地项目语义优先，避免误触发联网
  if (PROJECT_QUESTION.test(text)) return { route: 'project_question', isSimple: false, tier: 'capable' };
  if (CI_REPAIR.test(text)) return { route: 'ci_repair', isSimple: false, tier: 'capable' };
  if (REVIEW.test(text) && !CODE_CHANGE.test(text)) return { route: 'review', isSimple: false, tier: 'capable' };
  if (BROWSER_FIX.test(text) && CODE_CHANGE.test(text)) return { route: 'browser_fix', isSimple: false, tier: 'capable' };
  if (DELIVERY.test(text)) return { route: 'delivery', isSimple: false, tier: 'capable' };
  // 联网：显式联网意图，或时效词 + 外部实时领域
  if (WEB_INTENT.test(text) && EXTERNAL_REALTIME.test(text)) return { route: 'web_research', isSimple: false, tier: 'capable' };
  if (WEB_INTENT.test(text) && !PROJECT_QUESTION.test(text)) return { route: 'web_research', isSimple: false, tier: 'capable' };
  if (CODE_CHANGE.test(text)) return { route: 'code_change', isSimple: false, tier: 'capable' };

  if (looksSimple(text)) return { route: 'direct_answer', isSimple: true, tier: 'fast' };
  return { route: 'project_question', isSimple: false, tier: 'capable' };
}

export function isSimpleDirectAnswer(input: string): boolean {
  const result = classifyTask(input);
  return result.route === 'direct_answer' && result.isSimple;
}
