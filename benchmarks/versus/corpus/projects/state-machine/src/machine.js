/** 工单状态机。 */
const STATES = ['pending', 'active', 'resolved', 'archived'];

export function createMachine(initial = 'pending') {
  let state = initial;
  return {
    get state() { return state; },
    transition(target) {
      if (!STATES.includes(target)) throw new Error(`unknown state: ${target}`);
      state = target;
      return state;
    }
  };
}
