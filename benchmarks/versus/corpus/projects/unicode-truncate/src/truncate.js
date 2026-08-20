/** 把文本截断到 maxChars 个字符以内，超长时末尾追加省略号。 */
export function truncate(text, maxChars) {
  if (text.length <= maxChars) return text;
  return `${text.slice(0, maxChars)}…`;
}
