/** 从 Markdown 文本提取 [文本](URL) 链接。 */
export function extractLinks(markdown) {
  const links = [];
  const pattern = /\[([^\]]+)\]\(([^)]+)\)/g;
  let match;
  while ((match = pattern.exec(markdown)) !== null) {
    links.push({ text: match[1], url: match[2] });
  }
  return links;
}
