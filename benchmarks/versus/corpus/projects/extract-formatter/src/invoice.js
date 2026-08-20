function pad2(value) {
  return String(value).padStart(2, '0');
}

export function invoiceCode(year, month, seq) {
  return `INV-${year}${pad2(month)}-${pad2(seq)}`;
}
