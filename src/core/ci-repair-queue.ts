import type { CIRepairSession } from './ci-repair-session';

export class CIRepairQueue<Value> {
  private readonly entries = new Map<string, { repair: CIRepairSession; value: Value }>();

  schedule(repair: CIRepairSession, value: Value): boolean {
    if (this.entries.has(repair.sessionID)) return false;
    this.entries.set(repair.sessionID, { repair, value });
    return true;
  }

  take(parentSessionID: string): Array<{ repair: CIRepairSession; value: Value }> {
    const matches = [...this.entries.values()].filter((entry) => entry.repair.parentSessionID === parentSessionID);
    for (const entry of matches) this.entries.delete(entry.repair.sessionID);
    return matches;
  }
}
