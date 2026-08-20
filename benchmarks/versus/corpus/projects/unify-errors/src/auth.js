export function requireToken(token) {
  if (!token) throw 'token is required';
  if (String(token).length < 8) throw 'token is too short';
  return token;
}
