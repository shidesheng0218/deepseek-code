export function resolveEnv(model: { env?: Record<string, string> } | null | undefined): { env: Record<string, string>; missing: string[] }
