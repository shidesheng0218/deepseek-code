import { shout } from './b.js';

export function normalize(text) {
  return String(text).trim().toLowerCase();
}

export function normalizeAndShout(text) {
  return shout(normalize(text));
}
