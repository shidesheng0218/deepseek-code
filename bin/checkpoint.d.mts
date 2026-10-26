export interface CheckpointEntryInfo { hash: string | null; existed: boolean; content?: string }
export interface Checkpoint {
  id: string;
  label: string;
  createdAt: string;
  sessionID: string | null;
  projectPath: string;
  head: string;
  entries: Record<string, CheckpointEntryInfo>;
}
export function createCheckpoint(options: { checkpointRoot: string; projectPath: string; sessionID: string; label: string; extraPaths?: string[] }): Promise<string>;
export function listCheckpoints(checkpointRoot: string): Promise<Array<{ id: string; label: string; createdAt: string; projectPath: string; fileCount: number }>>;
export function diffAgainstCheckpoint(checkpoint: Checkpoint): Promise<string[]>;
export function undoCheckpoint(options: { checkpoint: Checkpoint; agentAfter: Record<string, string | null> }): Promise<{ restored: string[]; conflicts: string[] }>;
