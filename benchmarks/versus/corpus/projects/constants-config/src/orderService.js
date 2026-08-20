const API_BASE = 'https://api.internal.example';

export function orderEndpoint(id) {
  return `${API_BASE}/orders/${id}`;
}
