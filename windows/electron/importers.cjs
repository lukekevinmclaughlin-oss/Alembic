"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.parseCSV = parseCSV;
exports.importCSV = importCSV;
exports.importJSON = importJSON;
exports.markdownSections = markdownSections;
exports.importText = importText;
exports.importBytes = importBytes;
exports.importContent = importContent;
exports.rawJSONL = rawJSONL;
exports.rawCSV = rawCSV;
const model_1 = require("./model.cjs");
const lossless_json_1 = require("./lossless-json.cjs");
const normalize_1 = require("./normalize.cjs");
const types_1 = require("./types.cjs");
function boundedText(s) { if (new TextEncoder().encode(s).length > model_1.limits.inputBytes)
    throw Error('Input exceeds 32 MiB.'); }
function parseCSV(text, delimiter, stopAfter) {
    if (![',', '\t', ';', '|'].includes(delimiter))
        throw Error('Unsupported delimiter.');
    const rows = [];
    let row = [], cell = '', quoted = false, closed = false, start = true;
    function pushCell() { if (cell.length > model_1.limits.cellChars)
        throw Error('CSV cell exceeds 1,000,000 characters.'); row.push(cell); if (row.length > model_1.limits.columns)
        throw Error('CSV exceeds 200 columns.'); cell = ''; closed = false; start = true; }
    function pushRow() { pushCell(); rows.push(row); row = []; if (rows.length > model_1.limits.rows + 1)
        throw Error('CSV exceeds 50,000 data rows.'); }
    for (let i = text.charCodeAt(0) === 0xfeff ? 1 : 0; i < text.length; i++) {
        const c = text[i];
        if (quoted) {
            if (c === '"') {
                if (text[i + 1] === '"') {
                    cell += '"';
                    i++;
                }
                else {
                    quoted = false;
                    closed = true;
                }
            }
            else
                cell += c;
        }
        else if (c === delimiter)
            pushCell();
        else if (c === '\r' || c === '\n') {
            if (c === '\r' && text[i + 1] === '\n')
                i++;
            pushRow();
            if (stopAfter && rows.length >= stopAfter)
                return rows;
        }
        else if (closed)
            throw Error(`Unexpected text after CSV closing quote at character ${i + 1}.`);
        else if (c === '"') {
            if (!start)
                throw Error(`Quote inside unquoted CSV field at character ${i + 1}.`);
            quoted = true;
            start = false;
        }
        else {
            cell += c;
            start = false;
        }
        if (cell.length > model_1.limits.cellChars)
            throw Error('CSV cell exceeds 1,000,000 characters.');
    }
    if (quoted)
        throw Error('Unclosed CSV quoted field.');
    if (cell || row.length || closed || !start)
        pushRow();
    return rows;
}
function sniffDelimiter(text) { let best = ',', bestScore = -1; for (const d of [',', '\t', ';', '|']) {
    try {
        const rows = parseCSV(text, d, 30).filter(r => r.some(Boolean));
        if (!rows.length)
            continue;
        const widths = rows.map(r => r.length), mean = widths.reduce((a, b) => a + b, 0) / widths.length, variance = widths.reduce((a, w) => a + (w - mean) ** 2, 0) / widths.length, score = (mean - 1) * widths.filter(w => w > 1).length / widths.length / (1 + variance);
        if (widths.filter(w => w > 1).length / widths.length >= .6 && score > bestScore) {
            bestScore = score;
            best = d;
        }
    }
    catch { /* Another delimiter may be correct; final selected parse remains strict. */ }
} return best; }
function headerGuess(rows) { const first = rows[0]; if (!first?.length || first.some(v => !v.trim()))
    return false; if (rows.length === 1)
    return true; const numericFraction = (xs) => xs.filter(v => (0, types_1.parseDouble)(v) !== null).length / Math.max(1, xs.length); const a = numericFraction(first), b = numericFraction(rows.slice(1, 6).flat()); return a === 0 && b > 0 || a < b - .3 || a === 0 && first.every(v => v.length < 64 && !/[\r\n]/.test(v)) && new Set(first).size === first.length; }
function columnNames(header, width) { const requested = Array.from({ length: width }, (_, i) => header[i]?.trim() || `column_${i + 1}`); if (requested.some(c => c.length > 300))
    throw Error('A column name exceeds 300 characters.'); const reserved = new Set(requested.map(s => s.toLowerCase())), used = new Set(); return requested.map(base => { let name = base, n = 2; if (used.has(name.toLowerCase()))
    do {
        name = `${base}_${n++}`;
    } while (used.has(name.toLowerCase()) || reserved.has(name.toLowerCase())); used.add(name.toLowerCase()); return name; }); }
function importCSV(text, source, o = {}) {
    boundedText(text);
    const delimiter = o.delimiter ?? (o.format === 'tsv' ? '\t' : sniffDelimiter(text));
    const rows = parseCSV(text, delimiter);
    if (!rows.length)
        throw Error('CSV contains no records.');
    const hasHeader = o.header === 'yes' || o.header !== 'no' && headerGuess(rows), header = hasHeader ? rows[0] : [], values = hasHeader ? rows.slice(1) : rows;
    const width = Math.max(header.length, ...values.map(r => r.length), 0);
    if (!width)
        throw Error('CSV has no columns.');
    const ragged = values.filter(r => r.length !== width).length, columns = columnNames(header, width), warnings = [];
    if (ragged)
        warnings.push(`${ragged} uneven rows were padded with null cells; no fields were removed.`);
    if ((o.header ?? 'auto') === 'auto')
        warnings.push(`Header ${hasHeader ? 'detected' : 'not detected'} heuristically. Set Header explicitly if the preview is wrong.`);
    if (hasHeader && columns.some((n, i) => n !== header[i]))
        warnings.push('Empty, duplicate or padded column names were made unique; inspect the preview.');
    return { dataset: (0, model_1.fresh)(columns, values.map(row => columns.map((_, i) => row[i] === undefined || row[i] === '' ? model_1.NIL : (0, model_1.string)(row[i])))), format: delimiter === '\t' ? 'tsv' : 'csv', source, details: { delimiter: delimiter === '\t' ? 'tab' : delimiter, header: String(hasHeader), raggedRows: String(ragged) }, warnings, rejected: [] };
}
function isObject(x) { return x !== null && typeof x === 'object' && !Array.isArray(x) && !(x instanceof lossless_json_1.JSONNumber); }
function flatten(value) {
    const out = Object.create(null);
    function put(k, v) { if (Object.hasOwn(out, k))
        throw Error(`Flattened JSON column collision: ${k}`); if (k.length > 300)
        throw Error('Flattened JSON key exceeds 300 characters.'); out[k] = (0, lossless_json_1.jsonCell)(v); if (Object.keys(out).length > model_1.limits.columns)
        throw Error('JSON row exceeds 200 columns.'); }
    function visit(v, prefix, depth) { if (depth > 32)
        throw Error('Flattened JSON depth exceeds 32.'); if (isObject(v) && Object.keys(v).length)
        for (const key of Object.keys(v).sort())
            visit(v[key], prefix ? prefix + '.' + key : key, depth + 1);
    else
        put(prefix || 'value', v); }
    visit(value, '', 0);
    return out;
}
function datasetFromObjects(objects) { if (objects.length > model_1.limits.rows)
    throw Error('JSON exceeds 50,000 rows.'); const mapped = objects.map(flatten), columns = [], seen = new Set(); for (const row of mapped)
    for (const k of Object.keys(row))
        if (!seen.has(k)) {
            columns.push(k);
            seen.add(k);
            if (columns.length > model_1.limits.columns)
                throw Error('JSON exceeds 200 columns.');
        } return (0, model_1.fresh)(columns, mapped.map(row => columns.map(c => row[c] ?? model_1.NIL))); }
function importJSON(text, source, o = {}) {
    boundedText(text);
    const warnings = [], rejected = [];
    let rows = [], path = '(root)';
    if (o.format === 'jsonl') {
        const lines = text.split(/\r?\n/);
        if (lines.length > model_1.limits.rows + 1)
            throw Error('JSONL exceeds 50,000 source rows.');
        const mapped = [];
        for (let i = 0; i < lines.length; i++) {
            if (!lines[i].trim())
                continue;
            try {
                const row = (0, lossless_json_1.parseLossless)(lines[i]);
                flatten(row);
                mapped.push(row);
            }
            catch (e) {
                rejected.push({ row: i + 1, reason: String(e instanceof Error ? e.message : e), original: lines[i] });
            }
        }
        if (!mapped.length)
            throw Error('JSONL contains no valid records.');
        rows = mapped;
        if (rejected.length)
            warnings.push(`${rejected.length} invalid JSONL rows quarantined with complete source text and reasons.`);
    }
    else {
        let root = (0, lossless_json_1.parseLossless)(text);
        if (o.jsonPath) {
            for (const key of o.jsonPath) {
                if (!isObject(root) || !Object.hasOwn(root, key))
                    throw Error('JSON dataset path not found.');
                root = root[key];
            }
            path = o.jsonPath.join('.');
        }
        else if (isObject(root)) {
            const choices = [];
            function find(x, parts, depth) { if (depth > 16)
                return; if (Array.isArray(x)) {
                if (x.some(isObject))
                    choices.push({ path: parts, values: x });
                return;
            } if (isObject(x))
                for (const k of Object.keys(x))
                    find(x[k], [...parts, k], depth + 1); }
            find(root, [], 0);
            choices.sort((a, b) => b.values.length - a.values.length || a.path.join('.').localeCompare(b.path.join('.'), 'en'));
            if (choices.length) {
                if (choices.length > 1 && choices[0].values.length === choices[1].values.length)
                    throw Error('Multiple equally sized dataset arrays; choose an explicit JSON path.');
                root = choices[0].values;
                path = choices[0].path.join('.');
                warnings.push(`Imported the largest nested object array at ${path}; other wrapper fields are not rows.`);
            }
        }
        rows = Array.isArray(root) ? root : [root];
    }
    const dataset = datasetFromObjects(rows), decimals = dataset.records.reduce((n, r) => n + r.values.filter(v => v.t === 'decimal').length, 0);
    if (decimals)
        warnings.push(`${decimals} fractional, scientific, negative-zero or oversized integer values are preserved as exact decimal text; raw JSON export retains their numeric literals. Arithmetic needs explicit double conversion.`);
    return { dataset, format: o.format === 'jsonl' ? 'jsonl' : 'json', source, warnings, rejected, details: { path, exactDecimalCells: String(decimals), arrays: 'Nested arrays preserved as complete JSON text.' } };
}
function markdownSections(text) {
    const out = [];
    let heading = '', level = 0, lines = [], fence = '', fenceLength = 0;
    const flush = () => { const body = lines.join('\n').trim(); if (body || heading)
        out.push({ heading, level, body }); lines = []; };
    for (const line of text.replace(/\r\n?/g, '\n').split('\n')) {
        const f = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
        if (f) {
            if (!fence) {
                fence = f[1][0];
                fenceLength = f[1].length;
            }
            else if (f[1][0] === fence && f[1].length >= fenceLength && !f[2].trim())
                fence = '';
            lines.push(line);
            continue;
        }
        const h = !fence ? line.match(/^ {0,3}(#{1,6})[ \t]+(.+?)\s*#*\s*$/) : null;
        if (h) {
            flush();
            heading = h[2];
            level = h[1].length;
        }
        else
            lines.push(line);
    }
    flush();
    return out;
}
function importText(text, source, o = {}) {
    boundedText(text);
    const format = o.format === 'auto' || !o.format ? 'text' : o.format, mode = o.textMode ?? (format === 'markdown' ? 'markdownSections' : format === 'html' ? 'paragraphs' : 'wholeFile');
    if (format === 'html')
        text = (0, normalize_1.decodeEntities)((0, normalize_1.stripTags)(text));
    let dataset;
    if (mode === 'markdownSections')
        dataset = (0, model_1.fresh)(['text', 'heading', 'level', 'source', 'position'], markdownSections(text).map((s, i) => [(0, model_1.string)(s.body), s.heading ? (0, model_1.string)(s.heading) : model_1.NIL, (0, model_1.integer)(s.level), (0, model_1.string)(source), (0, model_1.integer)(i)]));
    else {
        const pieces = mode === 'lines' ? text.split(/\r?\n/).map(s => s.trim()).filter(Boolean) : mode === 'paragraphs' ? text.replace(/\r\n?/g, '\n').split(/\n[ \t]*\n+/).map(s => s.trim()).filter(Boolean) : [text];
        dataset = (0, model_1.fresh)(['text', 'source', 'position'], pieces.map((s, i) => [(0, model_1.string)(s), (0, model_1.string)(source), (0, model_1.integer)(i)]));
    }
    return { dataset, format, source, details: { splitMode: mode }, warnings: format === 'html' ? ['Static HTML text extraction; scripts, styling and rendered browser content are not imported.'] : [], rejected: [] };
}
function importBytes(bytes, source, options = {}) { if (bytes.length > model_1.limits.inputBytes)
    throw Error('File exceeds 32 MiB.'); const decoded = (0, normalize_1.decodeBytes)(bytes); const result = importContent(decoded.text, source, options); result.details.encoding = decoded.encoding; if (decoded.warning)
    result.warnings.unshift(decoded.warning); return result; }
function importContent(text, source, options = {}) { boundedText(text); const ext = source.split('.').pop()?.toLowerCase(), o = { ...options }; if (!o.format || o.format === 'auto')
    o.format = ext === 'csv' ? 'csv' : ext === 'tsv' ? 'tsv' : ['jsonl', 'ndjson'].includes(ext ?? '') ? 'jsonl' : ext === 'json' ? 'json' : ['md', 'markdown'].includes(ext ?? '') ? 'markdown' : ['htm', 'html', 'xhtml'].includes(ext ?? '') ? 'html' : 'text'; if (['sqlite', 'sqlite3', 'db'].includes(ext ?? '') && (!options.format || options.format === 'auto'))
    throw Error('SQLite files must be opened with the native table chooser.'); return o.format === 'csv' || o.format === 'tsv' ? importCSV(text, source, o) : o.format === 'json' || o.format === 'jsonl' ? importJSON(text, source, o) : importText(text, source, o); }
function rawJSONL(ds) { return ds.records.map(r => { const o = Object.create(null); ds.columns.forEach((c, i) => o[c] = (0, lossless_json_1.cellJSON)(r.values[i])); return (0, lossless_json_1.stringifyLossless)(o); }).join('\n') + (ds.records.length ? '\n' : ''); }
function rawCSV(ds, spreadsheetSafe = true) { let escapedCells = 0; const field = (s) => { if (spreadsheetSafe && /^[\s\u0000-\u001f]*[=+@-]/u.test(s)) {
    s = "'" + s;
    escapedCells++;
} return /[,"\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; }; const rows = [ds.columns, ...ds.records.map(r => r.values.map(model_1.display))]; return { text: rows.map(r => r.map(field).join(',')).join('\r\n') + '\r\n', escapedCells }; }
