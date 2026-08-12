import type { DeepSeekCodeBridge } from '../preload';

declare global {
  interface Window {
    deepseekCode: DeepSeekCodeBridge;
  }
}

export {};
