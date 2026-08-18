export interface SubmitState {
  runtimeReady: boolean;
  busy: boolean;
  text: string;
  apiKey: string;
  projectPath: string;
}

export function canSubmitTask(state: SubmitState): boolean {
  return state.runtimeReady && Boolean(state.text.trim()) && Boolean(state.apiKey.trim()) && Boolean(state.projectPath.trim());
}

export function submitActionLabel(busy: boolean): string { return busy ? '追加消息' : '开始任务'; }
