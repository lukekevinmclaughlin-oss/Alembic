import { type Value, NIL, display, integer, double, boolean, string, INT_MAX, INT_MIN } from './model';
export type ColumnType = 'string' | 'int' | 'double' | 'bool' | 'date';
export const nullSentinels = new Set(['', 'na', 'n/a', 'nan', 'null', 'none', 'nil', '-', '--', '?', 'missing', '#n/a', '#null!', '(null)', 'undefined']);
export const isNullString = (s: string) => nullSentinels.has(s.trim().toLowerCase());
export function parseInteger(s: string): bigint | null { s = s.trim(); if (/^[+-]?\d{1,3}(,\d{3})+$/.test(s)) s = s.replace(/,/g, ''); if (!/^[+-]?\d{1,20}$/.test(s)) return null; const n = BigInt(s); return n >= INT_MIN && n <= INT_MAX ? n : null; }
export function parseDouble(s: string): number | null {
  s = s.trim(); let pct = false; if (s.endsWith('%')) { pct = true; s = s.slice(0, -1).trim(); }
  const signed = '[+-]?';
  if (s.includes(',') && s.includes('.')) {
    if (s.lastIndexOf(',') > s.lastIndexOf('.')) { if (!new RegExp('^' + signed + '(?:\\d{1,3}(?:\\.\\d{3})+|\\d+),\\d+(?:[eE][+-]?\\d+)?$').test(s)) return null; s = s.replace(/\./g, '').replace(',', '.'); }
    else { if (!new RegExp('^' + signed + '\\d{1,3}(?:,\\d{3})+\\.\\d+(?:[eE][+-]?\\d+)?$').test(s)) return null; s = s.replace(/,/g, ''); }
  } else if (s.includes(',')) { if (/^[+-]?\d{1,3}(,\d{3})+$/.test(s)) s = s.replace(/,/g, ''); else if (/^[+-]?\d+,\d+$/.test(s) && s.split(',')[1].length !== 3) s = s.replace(',', '.'); else return null; }
  if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(s)) return null; const n = Number(s) / (pct ? 100 : 1); return Number.isFinite(n) ? n : null;
}
export function parseBool(s: string): boolean | null { s = s.trim().toLowerCase(); if (['true', 'yes', 'y', 't', '1️⃣'].includes(s)) return true; if (['false', 'no', 'n', 'f'].includes(s)) return false; return null; }
function ymd(y: number, m: number, d: number, hour = 0, minute = 0, second = 0, ms = 0): string | null { if (y < 1000 || y > 9999 || m < 1 || m > 12 || d < 1 || d > 31 || hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59 || ms < 0 || ms > 999) return null; const date = new Date(Date.UTC(y, m - 1, d, hour, minute, second, ms)); return date.getUTCFullYear() === y && date.getUTCMonth() === m - 1 && date.getUTCDate() === d ? date.toISOString() : null; }
const months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
export function parseDate(s: string): string | null {
  s = s.trim(); if (s.length < 6 || s.length > 40) return null;
  let m = s.match(/^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?(Z|[+-]\d{2}:\d{2})?$/i);
  if (m) { const base = ymd(+m[1], +m[2], +m[3], +m[4], +m[5], +m[6], +(m[7] ?? '').padEnd(3, '0')); if (!base) return null; if (!m[8] || m[8].toUpperCase() === 'Z') return base; const h = +m[8].slice(1, 3), min = +m[8].slice(4); if (h > 23 || min > 59) return null; const date = new Date(new Date(base).getTime() - (m[8][0] === '+' ? 1 : -1) * (h * 60 + min) * 60000); return date.getUTCFullYear() >= 1000 && date.getUTCFullYear() <= 9999 ? date.toISOString() : null; }
  if (/^\d{10}$/.test(s) && +s > 631152000) return new Date(+s * 1000).toISOString();
  if (/^\d{13}$/.test(s)) return new Date(+s).toISOString();
  if ((m = s.match(/^(\d{4})(\d{2})(\d{2})$/))) return +m[1] >= 1900 && +m[1] <= 2100 ? ymd(+m[1], +m[2], +m[3]) : null;
  if ((m = s.match(/^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$/))) return ymd(+m[1], +m[2], +m[3]);
  if ((m = s.match(/^(\d{1,2})([./-])(\d{1,2})\2(\d{2}|\d{4})$/))) { let y = +m[4]; if (y < 100) y += y < 50 ? 2000 : 1900; if (y < 1900 || y > 2100) return null; const a = +m[1], b = +m[3], dayFirst = a > 12 || (b <= 12 && m[2] === '.'); return ymd(y, dayFirst ? b : a, dayFirst ? a : b); }
  const cleaned = s.replace(/(\d)(st|nd|rd|th)\b/gi, '$1').replace(/,/g, '');
  if ((m = cleaned.match(/^([A-Za-z]+) (\d{1,2}) (\d{4})$/))) return months.includes(m[1].toLowerCase().slice(0, 3)) ? ymd(+m[3], months.indexOf(m[1].toLowerCase().slice(0, 3)) + 1, +m[2]) : null;
  if ((m = cleaned.match(/^(\d{1,2}) ([A-Za-z]+) (\d{4})$/))) return months.includes(m[2].toLowerCase().slice(0, 3)) ? ymd(+m[3], months.indexOf(m[2].toLowerCase().slice(0, 3)) + 1, +m[1]) : null;
  return null;
}
export function inferType(values: Value[]): ColumnType { const xs = values.filter(v => v.t === 'string' && !isNullString(v.v)).slice(0, 500).map(display); if (!xs.length) return 'string'; const counts = { bool: 0, int: 0, double: 0, date: 0 }; for (const s of xs) { if (parseBool(s) !== null) counts.bool++; if (parseInteger(s) !== null) counts.int++; if (parseDouble(s) !== null) counts.double++; else if (parseDate(s) !== null) counts.date++; } for (const t of ['bool', 'int', 'double', 'date'] as const) if (counts[t] / xs.length >= .95) return t; return 'string'; }
export function coerce(v: Value, type: ColumnType): Value { if (v.t === 'null') return NIL; if (type === 'string') return string(display(v)); if (v.t === type) return v; const s = display(v); if (isNullString(s)) return NIL;
  if (type === 'int') { if (v.t === 'bool') return integer(v.v ? 1 : 0); if (v.t === 'double') return Number.isSafeInteger(Math.trunc(v.v)) ? integer(Math.trunc(v.v)) : NIL; const n = parseInteger(s); return n === null ? NIL : integer(n); }
  if (type === 'double') { if (v.t === 'bool') return double(v.v ? 1 : 0); const n = parseDouble(s); return n === null ? NIL : double(n); }
  if (type === 'bool') { if (v.t === 'int') return boolean(BigInt(v.v) !== 0n); if (v.t === 'double') return boolean(v.v !== 0); const b = parseBool(s); return b === null ? NIL : boolean(b); }
  const date = parseDate(s); return date === null ? NIL : { t: 'date', v: date };
}
