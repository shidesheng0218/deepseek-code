const API_BASE = 'https://api.internal.example';

export function userEndpoint(id) {
  return `${API_BASE}/users/${id}`;
}
