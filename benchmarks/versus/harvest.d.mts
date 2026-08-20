export interface VersusTokens { input: number; output: number; cached: number }
export interface VersusResult {
  taskID: string
  harness: string
  runIndex: number
  startedAt: string
  wallMs: number
  status: 'completed' | 'error' | 'skipped'
  error: string | null
  verify: { command: string; exitCode: number | null; timedOut: boolean } | null
  success: boolean
  approvals: number | null
  tokens: VersusTokens | null
  costUSD: number | null
  transcriptFile: string | null
  totalTokens?: number | null
}
export interface VersusPrice { input?: number; output?: number; cachedInput?: number }
export interface HarnessStats {
  harness: string
  runs: number
  errors: number
  successes: number
  successRate: number
  avgApprovals: number | null
  avgInputTokens: number | null
  avgOutputTokens: number | null
  avgCachedTokens: number | null
  totalCostUSD: number | null
  costPerSolvedUSD: number | null
  tokensPerSolved: number | null
  medianWallMs: number | null
  coverage: { tokens: number; cost: number; approvals: number }
}
export function median(values: Array<number | null | undefined>): number | null
export function tokensTotal(tokens: VersusTokens | null | undefined): number | null
export function costForTokens(tokens: VersusTokens | null | undefined, price: VersusPrice | null | undefined): number | null
export function normalizeResult(result: VersusResult, priceEntry?: VersusPrice | null): VersusResult
export function aggregate(results: VersusResult[]): HarnessStats[]
