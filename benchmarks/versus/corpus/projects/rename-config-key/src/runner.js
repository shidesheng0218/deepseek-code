import { loadConfig } from './config.js';

export async function runJob(job, options = {}) {
  const config = loadConfig(options);
  let lastError;
  for (let attempt = 0; attempt < config.retryCount; attempt += 1) {
    try {
      return await job();
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError;
}
