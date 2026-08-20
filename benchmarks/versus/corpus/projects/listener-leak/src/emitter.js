/** 极简事件发射器。 */
export function createEmitter() {
  const listeners = new Map();
  return {
    on(event, fn) {
      const list = listeners.get(event) ?? [];
      list.push((payload) => fn(payload));
      listeners.set(event, list);
    },
    off(event, fn) {
      const list = listeners.get(event) ?? [];
      listeners.set(event, list.filter((entry) => entry !== fn));
    },
    emit(event, payload) {
      for (const fn of [...(listeners.get(event) ?? [])]) fn(payload);
    }
  };
}
