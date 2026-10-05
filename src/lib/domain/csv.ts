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
  return "﻿" + lines.join("\r\n");
}
