/** 简易邮箱校验。 */
export function isEmail(text) {
  return /^([a-zA-Z0-9]+)+@[a-zA-Z0-9]+\.[a-zA-Z]{2,}$/.test(text);
}
