function pad2(value) {
  return String(value).padStart(2, '0');
}

export function reportName(year, month, day) {
  return `日报-${year}年${pad2(month)}月${pad2(day)}日`;
}
