import { normalize } from './a.js';

export function shout(text) {
  return `${text.toUpperCase()}!`;
}

export function normalizeQuiet(text) {
  return `[${normalize(text)}]`;
}
