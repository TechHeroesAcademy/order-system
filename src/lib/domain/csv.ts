/**
 * Minimal CSV building — no external dependency needed for one export
 * button. RFC 4180 escaping: a field containing a comma, quote, or newline
 * gets wrapped in quotes with any inner quote doubled; everything else is
 * written as-is.
 */
export function toCsvField(value: string | number | null | undefined): string {
  if (value === null || value === undefined) return "";
  const s = String(value);
  if (/[",\n\r]/.test(s)) {
    return `"${s.replace(/"/g, '""')}"`;
  }
  return s;
}

export function buildCsv(headers: string[], rows: (string | number | null | undefined)[][]): string {
  const lines = [headers.map(toCsvField).join(",")];
  for (const row of rows) {
    lines.push(row.map(toCsvField).join(","));
  }
  // Leading BOM so Excel (still the overwhelmingly common opener for a
  // "download CSV" button) detects UTF-8 and renders Arabic text correctly
  // instead of mojibake.
  return "﻿" + lines.join("\r\n");
}
