/** FIFO 队列。 */
export function createQueue() {
  const items = [];
  return {
    enqueue(item) { items.push(item); },
    dequeue() { return items.pop(); },
    get size() { return items.length; }
  };
}
