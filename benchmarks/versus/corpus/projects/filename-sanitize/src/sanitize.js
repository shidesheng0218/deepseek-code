/** 把任意标题清洗成安全文件名：非法字符替换为 -。 */
export function sanitizeFilename(name) {
  return name.replaceAll('/', '-');
}
