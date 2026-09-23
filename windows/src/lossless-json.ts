import { limits, jsonNumberPattern, type Value, NIL, boolean, integer, string, INT_MAX, INT_MIN } from './model';
export class JSONNumber { constructor(readonly raw: string) { if (!jsonNumberPattern.test(raw) || raw.length > 200) throw Error('Invalid or oversized JSON number.'); } }
export type JSONValue = null | boolean | string | number | JSONNumber | JSONValue[] | { [key: string]: JSONValue };
export function parseLossless(text: string): JSONValue {
  if (new TextEncoder().encode(text).length > limits.inputBytes) throw Error('JSON exceeds 32 MiB.'); let pos = 0, nodes = 0;
  function error(message: string): never { throw Error(`${message} at character ${pos + 1}.`); }
  function whitespace() { while (/[\x20\t\r\n]/.test(text[pos] ?? '\0')) pos++; }
  function str(): string { const start = pos++; let closed = false; while (pos < text.length) { const c = text[pos++]; if (c === '\\') { pos++; continue; } if (c === '"') { closed = true; break; } if (c.charCodeAt(0) < 32) error('Unescaped control character'); } if (!closed) error('Unclosed JSON string'); const s = JSON.parse(text.slice(start, pos)) as string; if (s.length > limits.cellChars) error('JSON string exceeds cell limit'); return s; }
  function value(depth: number): JSONValue {
    if (++nodes > 1_000_000 || depth > 64) error('JSON complexity limit exceeded'); whitespace(); const c = text[pos];
    if (c === '"') return str();
    if (c === '[' || c === '{') {
      pos++; whitespace(); const array = c === '[', end = array ? ']' : '}', result: JSONValue[] | Record<string, JSONValue> = array ? [] : Object.create(null);
      if (text[pos] === end) { pos++; return result; }
      while (true) {
        whitespace(); if (array) (result as JSONValue[]).push(value(depth + 1));
        else { if (text[pos] !== '"') error('Expected object key'); const key = str(); whitespace(); if (text[pos++] !== ':') error('Expected colon'); if (Object.hasOwn(result, key)) error(`Duplicate JSON key ${JSON.stringify(key)}`); (result as Record<string, JSONValue>)[key] = value(depth + 1); }
        whitespace(); if (text[pos] === end) { pos++; break; } if (text[pos++] !== ',') error('Expected comma');
      }
      return result;
    }
    for (const [literal, parsed] of [['null', null], ['true', true], ['false', false]] as const) if (text.startsWith(literal, pos)) { pos += literal.length; return parsed; }
    const match = text.slice(pos).match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/); if (!match) error('Expected JSON value'); pos += match[0].length; return new JSONNumber(match[0]);
  }
  const out = value(0); whitespace(); if (pos !== text.length) error('Trailing JSON data'); return out;
}
export function stringifyLossless(value: JSONValue, depth = 0): string { if (depth > 64) throw Error('JSON depth limit.'); if (value instanceof JSONNumber) return value.raw; if (value === null || typeof value !== 'object') { if (typeof value === 'number' && !Number.isFinite(value)) throw Error('Non-finite JSON value.'); return JSON.stringify(value); } if (Array.isArray(value)) return '[' + value.map(v => stringifyLossless(v, depth + 1)).join(',') + ']'; return '{' + Object.keys(value).map(k => JSON.stringify(k) + ':' + stringifyLossless(value[k], depth + 1)).join(',') + '}'; }
export function jsonCell(v: JSONValue): Value { if (v === null) return NIL; if (typeof v === 'boolean') return boolean(v); if (typeof v === 'string') return string(v); if (v instanceof JSONNumber) { if (/^-?\d+$/.test(v.raw) && v.raw !== '-0') { const n = BigInt(v.raw); if (n >= INT_MIN && n <= INT_MAX) return integer(n); } return { t: 'decimal', v: v.raw }; } if (typeof v === 'number') throw Error('JSON numbers must be parsed losslessly.'); return string(stringifyLossless(v)); }
export function cellJSON(v: Value): JSONValue { if (v.t === 'null') return null; if (v.t === 'int' || v.t === 'decimal') return new JSONNumber(v.v); if (v.t === 'blob') return { $binary: v.v, encoding: 'base64' }; return v.v; }
