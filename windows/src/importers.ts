import { type Dataset, type Value, type ImportResult, type Rejection, NIL, limits, fresh, string, integer, display } from './model';
import { type JSONValue, JSONNumber, parseLossless, jsonCell, cellJSON, stringifyLossless } from './lossless-json';
import { decodeBytes, stripTags, decodeEntities } from './normalize';
import { parseDouble } from './types';
export type ImportOptions = { format?: 'auto' | 'csv' | 'tsv' | 'json' | 'jsonl' | 'text' | 'markdown' | 'html'; delimiter?: string; header?: 'auto' | 'yes' | 'no'; textMode?: 'wholeFile' | 'paragraphs' | 'lines' | 'markdownSections'; jsonPath?: string[] };
function boundedText(s: string): void { if (new TextEncoder().encode(s).length > limits.inputBytes) throw Error('Input exceeds 32 MiB.'); }
export function parseCSV(text: string, delimiter: string, stopAfter?: number): string[][] {
  if (![',', '\t', ';', '|'].includes(delimiter)) throw Error('Unsupported delimiter.');
  const rows: string[][] = []; let row: string[] = [], cell = '', quoted = false, closed = false, start = true;
  function pushCell() { if (cell.length > limits.cellChars) throw Error('CSV cell exceeds 1,000,000 characters.'); row.push(cell); if (row.length > limits.columns) throw Error('CSV exceeds 200 columns.'); cell = ''; closed = false; start = true; }
  function pushRow() { pushCell(); rows.push(row); row = []; if (rows.length > limits.rows + 1) throw Error('CSV exceeds 50,000 data rows.'); }
  for (let i = text.charCodeAt(0) === 0xfeff ? 1 : 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) { if (c === '"') { if (text[i + 1] === '"') { cell += '"'; i++; } else { quoted = false; closed = true; } } else cell += c; }
    else if (c === delimiter) pushCell();
    else if (c === '\r' || c === '\n') { if (c === '\r' && text[i + 1] === '\n') i++; pushRow(); if (stopAfter && rows.length >= stopAfter) return rows; }
    else if (closed) throw Error(`Unexpected text after CSV closing quote at character ${i + 1}.`);
    else if (c === '"') { if (!start) throw Error(`Quote inside unquoted CSV field at character ${i + 1}.`); quoted = true; start = false; }
    else { cell += c; start = false; }
    if (cell.length > limits.cellChars) throw Error('CSV cell exceeds 1,000,000 characters.');
  }
  if (quoted) throw Error('Unclosed CSV quoted field.'); if (cell || row.length || closed || !start) pushRow();
  return rows;
}
function sniffDelimiter(text: string): string { let best = ',', bestScore = -1; for (const d of [',', '\t', ';', '|']) { try { const rows = parseCSV(text, d, 30).filter(r => r.some(Boolean)); if (!rows.length) continue; const widths = rows.map(r => r.length), mean = widths.reduce((a, b) => a + b, 0) / widths.length, variance = widths.reduce((a, w) => a + (w - mean) ** 2, 0) / widths.length, score = (mean - 1) * widths.filter(w => w > 1).length / widths.length / (1 + variance); if (widths.filter(w => w > 1).length / widths.length >= .6 && score > bestScore) { bestScore = score; best = d; } } catch { /* Another delimiter may be correct; final selected parse remains strict. */ } } return best; }
function headerGuess(rows: string[][]): boolean { const first = rows[0]; if (!first?.length || first.some(v => !v.trim())) return false; if (rows.length === 1) return true; const numericFraction = (xs: string[]) => xs.filter(v => parseDouble(v) !== null).length / Math.max(1, xs.length); const a = numericFraction(first), b = numericFraction(rows.slice(1, 6).flat()); return a === 0 && b > 0 || a < b - .3 || a === 0 && first.every(v => v.length < 64 && !/[\r\n]/.test(v)) && new Set(first).size === first.length; }
function columnNames(header: string[], width: number): string[] { const requested = Array.from({ length: width }, (_, i) => header[i]?.trim() || `column_${i + 1}`); if (requested.some(c => c.length > 300)) throw Error('A column name exceeds 300 characters.'); const reserved = new Set(requested.map(s => s.toLowerCase())), used = new Set<string>(); return requested.map(base => { let name = base, n = 2; if (used.has(name.toLowerCase())) do { name = `${base}_${n++}`; } while (used.has(name.toLowerCase()) || reserved.has(name.toLowerCase())); used.add(name.toLowerCase()); return name; }); }
export function importCSV(text: string, source: string, o: ImportOptions = {}): ImportResult {
  boundedText(text); const delimiter = o.delimiter ?? (o.format === 'tsv' ? '\t' : sniffDelimiter(text)); const rows = parseCSV(text, delimiter); if (!rows.length) throw Error('CSV contains no records.');
  const hasHeader = o.header === 'yes' || o.header !== 'no' && headerGuess(rows), header = hasHeader ? rows[0] : [], values = hasHeader ? rows.slice(1) : rows; const width = Math.max(header.length, ...values.map(r => r.length), 0); if (!width) throw Error('CSV has no columns.');
  const ragged = values.filter(r => r.length !== width).length, columns = columnNames(header, width), warnings: string[] = [];
  if (ragged) warnings.push(`${ragged} uneven rows were padded with null cells; no fields were removed.`);
  if ((o.header ?? 'auto') === 'auto') warnings.push(`Header ${hasHeader ? 'detected' : 'not detected'} heuristically. Set Header explicitly if the preview is wrong.`);
  if (hasHeader && columns.some((n, i) => n !== header[i])) warnings.push('Empty, duplicate or padded column names were made unique; inspect the preview.');
  return { dataset: fresh(columns, values.map(row => columns.map((_, i) => row[i] === undefined || row[i] === '' ? NIL : string(row[i])))), format: delimiter === '\t' ? 'tsv' : 'csv', source, details: { delimiter: delimiter === '\t' ? 'tab' : delimiter, header: String(hasHeader), raggedRows: String(ragged) }, warnings, rejected: [] };
}
function isObject(x: JSONValue): x is Record<string, JSONValue> { return x !== null && typeof x === 'object' && !Array.isArray(x) && !(x instanceof JSONNumber); }
function flatten(value: JSONValue): Record<string, Value> {
  const out: Record<string, Value> = Object.create(null);
  function put(k: string, v: JSONValue) { if (Object.hasOwn(out, k)) throw Error(`Flattened JSON column collision: ${k}`); if (k.length > 300) throw Error('Flattened JSON key exceeds 300 characters.'); out[k] = jsonCell(v); if (Object.keys(out).length > limits.columns) throw Error('JSON row exceeds 200 columns.'); }
  function visit(v: JSONValue, prefix: string, depth: number) { if (depth > 32) throw Error('Flattened JSON depth exceeds 32.'); if (isObject(v) && Object.keys(v).length) for (const key of Object.keys(v).sort()) visit(v[key], prefix ? prefix + '.' + key : key, depth + 1); else put(prefix || 'value', v); }
  visit(value, '', 0); return out;
}
function datasetFromObjects(objects: JSONValue[]): Dataset { if (objects.length > limits.rows) throw Error('JSON exceeds 50,000 rows.'); const mapped = objects.map(flatten), columns: string[] = [], seen = new Set<string>(); for (const row of mapped) for (const k of Object.keys(row)) if (!seen.has(k)) { columns.push(k); seen.add(k); if (columns.length > limits.columns) throw Error('JSON exceeds 200 columns.'); } return fresh(columns, mapped.map(row => columns.map(c => row[c] ?? NIL))); }
export function importJSON(text: string, source: string, o: ImportOptions = {}): ImportResult {
  boundedText(text); const warnings: string[] = [], rejected: Rejection[] = []; let rows: JSONValue[] = [], path = '(root)';
  if (o.format === 'jsonl') {
    const lines = text.split(/\r?\n/); if (lines.length > limits.rows + 1) throw Error('JSONL exceeds 50,000 source rows.'); const mapped: JSONValue[] = [];
    for (let i = 0; i < lines.length; i++) { if (!lines[i].trim()) continue; try { const row = parseLossless(lines[i]); flatten(row); mapped.push(row); } catch (e) { rejected.push({ row: i + 1, reason: String(e instanceof Error ? e.message : e), original: lines[i] }); } }
    if (!mapped.length) throw Error('JSONL contains no valid records.'); rows = mapped; if (rejected.length) warnings.push(`${rejected.length} invalid JSONL rows quarantined with complete source text and reasons.`);
  } else {
    let root = parseLossless(text);
    if (o.jsonPath) { for (const key of o.jsonPath) { if (!isObject(root) || !Object.hasOwn(root, key)) throw Error('JSON dataset path not found.'); root = root[key]; } path = o.jsonPath.join('.'); }
    else if (isObject(root)) {
      const choices: { path: string[]; values: JSONValue[] }[] = [];
      function find(x: JSONValue, parts: string[], depth: number) { if (depth > 16) return; if (Array.isArray(x)) { if (x.some(isObject)) choices.push({ path: parts, values: x }); return; } if (isObject(x)) for (const k of Object.keys(x)) find(x[k], [...parts, k], depth + 1); }
      find(root, [], 0); choices.sort((a, b) => b.values.length - a.values.length || a.path.join('.').localeCompare(b.path.join('.'), 'en'));
      if (choices.length) { if (choices.length > 1 && choices[0].values.length === choices[1].values.length) throw Error('Multiple equally sized dataset arrays; choose an explicit JSON path.'); root = choices[0].values; path = choices[0].path.join('.'); warnings.push(`Imported the largest nested object array at ${path}; other wrapper fields are not rows.`); }
    }
    rows = Array.isArray(root) ? root : [root];
  }
  const dataset = datasetFromObjects(rows), decimals = dataset.records.reduce((n, r) => n + r.values.filter(v => v.t === 'decimal').length, 0);
  if (decimals) warnings.push(`${decimals} fractional, scientific, negative-zero or oversized integer values are preserved as exact decimal text; raw JSON export retains their numeric literals. Arithmetic needs explicit double conversion.`);
  return { dataset, format: o.format === 'jsonl' ? 'jsonl' : 'json', source, warnings, rejected, details: { path, exactDecimalCells: String(decimals), arrays: 'Nested arrays preserved as complete JSON text.' } };
}
export type MarkdownSection = { heading: string; level: number; body: string };
export function markdownSections(text: string): MarkdownSection[] { const out: MarkdownSection[] = []; let heading = '', level = 0, lines: string[] = [], fence = '', fenceLength = 0;
  const flush = () => { const body = lines.join('\n').trim(); if (body || heading) out.push({ heading, level, body }); lines = []; };
  for (const line of text.replace(/\r\n?/g, '\n').split('\n')) { const f = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/); if (f) { if (!fence) { fence = f[1][0]; fenceLength = f[1].length; } else if (f[1][0] === fence && f[1].length >= fenceLength && !f[2].trim()) fence = ''; lines.push(line); continue; } const h = !fence ? line.match(/^ {0,3}(#{1,6})[ \t]+(.+?)\s*#*\s*$/) : null; if (h) { flush(); heading = h[2]; level = h[1].length; } else lines.push(line); } flush(); return out;
}
export function importText(text: string, source: string, o: ImportOptions = {}): ImportResult { boundedText(text); const format = o.format === 'auto' || !o.format ? 'text' : o.format, mode = o.textMode ?? (format === 'markdown' ? 'markdownSections' : format === 'html' ? 'paragraphs' : 'wholeFile'); if (format === 'html') text = decodeEntities(stripTags(text)); let dataset: Dataset;
  if (mode === 'markdownSections') dataset = fresh(['text', 'heading', 'level', 'source', 'position'], markdownSections(text).map((s, i) => [string(s.body), s.heading ? string(s.heading) : NIL, integer(s.level), string(source), integer(i)]));
  else { const pieces = mode === 'lines' ? text.split(/\r?\n/).map(s => s.trim()).filter(Boolean) : mode === 'paragraphs' ? text.replace(/\r\n?/g, '\n').split(/\n[ \t]*\n+/).map(s => s.trim()).filter(Boolean) : [text]; dataset = fresh(['text', 'source', 'position'], pieces.map((s, i) => [string(s), string(source), integer(i)])); }
  return { dataset, format, source, details: { splitMode: mode }, warnings: format === 'html' ? ['Static HTML text extraction; scripts, styling and rendered browser content are not imported.'] : [], rejected: [] };
}
export function importBytes(bytes: Uint8Array, source: string, options: ImportOptions = {}): ImportResult { if (bytes.length > limits.inputBytes) throw Error('File exceeds 32 MiB.'); const decoded = decodeBytes(bytes); const result = importContent(decoded.text, source, options); result.details.encoding = decoded.encoding; if (decoded.warning) result.warnings.unshift(decoded.warning); return result; }
export function importContent(text: string, source: string, options: ImportOptions = {}): ImportResult { boundedText(text); const ext = source.split('.').pop()?.toLowerCase(), o = { ...options }; if (!o.format || o.format === 'auto') o.format = ext === 'csv' ? 'csv' : ext === 'tsv' ? 'tsv' : ['jsonl', 'ndjson'].includes(ext ?? '') ? 'jsonl' : ext === 'json' ? 'json' : ['md', 'markdown'].includes(ext ?? '') ? 'markdown' : ['htm', 'html', 'xhtml'].includes(ext ?? '') ? 'html' : 'text'; if (['sqlite', 'sqlite3', 'db'].includes(ext ?? '') && (!options.format || options.format === 'auto')) throw Error('SQLite files must be opened with the native table chooser.'); return o.format === 'csv' || o.format === 'tsv' ? importCSV(text, source, o) : o.format === 'json' || o.format === 'jsonl' ? importJSON(text, source, o) : importText(text, source, o); }
export function rawJSONL(ds: Dataset): string { return ds.records.map(r => { const o: Record<string, JSONValue> = Object.create(null); ds.columns.forEach((c, i) => o[c] = cellJSON(r.values[i])); return stringifyLossless(o); }).join('\n') + (ds.records.length ? '\n' : ''); }
export function rawCSV(ds: Dataset, spreadsheetSafe = true): { text: string; escapedCells: number } { let escapedCells = 0; const field = (s: string) => { if (spreadsheetSafe && /^[\s\u0000-\u001f]*[=+@-]/u.test(s)) { s = "'" + s; escapedCells++; } return /[,"\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; }; const rows = [ds.columns, ...ds.records.map(r => r.values.map(display))]; return { text: rows.map(r => r.map(field).join(',')).join('\r\n') + '\r\n', escapedCells }; }
