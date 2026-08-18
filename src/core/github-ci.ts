export interface GitHubWorkflowRun {
  id: number;
  name: string;
  status: string;
  conclusion: string | null;
  url: string;
}

interface GitHubRunPayload {
  databaseId?: number;
  displayTitle?: string;
  status?: string;
  conclusion?: string | null;
  headSha?: string;
  url?: string;
}

export async function getGitHubCIStatus(_projectPath: string, commitSHA: string, execute: (args: string[]) => Promise<string>): Promise<{ currentCommit: GitHubWorkflowRun[]; staleCount: number }> {
  const output = await execute(['run', 'list', '--limit', '30', '--json', 'databaseId,displayTitle,status,conclusion,headSha,url']);
  const runs = JSON.parse(output) as GitHubRunPayload[];
  const currentCommit = runs.filter((run) => run.headSha === commitSHA).flatMap((run) => {
    if (typeof run.databaseId !== 'number' || typeof run.displayTitle !== 'string' || typeof run.status !== 'string' || typeof run.url !== 'string') return [];
    return [{ id: run.databaseId, name: run.displayTitle, status: run.status, conclusion: run.conclusion ?? null, url: run.url }];
  });
  return { currentCommit, staleCount: runs.filter((run) => run.headSha !== commitSHA).length };
}
