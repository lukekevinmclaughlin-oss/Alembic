"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.graphemes = exports.words = exports.boolean = exports.string = exports.jsonNumberPattern = exports.INT_MAX = exports.INT_MIN = exports.NIL = exports.limits = void 0;
exports.integer = integer;
exports.double = double;
exports.display = display;
exports.same = same;
exports.cellKey = cellKey;
exports.truthy = truthy;
exports.numeric = numeric;
exports.requireColumn = requireColumn;
exports.uniqueColumn = uniqueColumn;
exports.validateValue = validateValue;
exports.validateDataset = validateDataset;
exports.fresh = fresh;
exports.sample = sample;
exports.checkCancelled = checkCancelled;
exports.hash64 = hash64;
exports.splitMix = splitMix;
exports.limits = Object.freeze({ inputBytes: 32 * 1024 * 1024, rows: 50_000, columns: 200, cells: 5_000_000, cellChars: 1_000_000, datasetBytes: 128 * 1024 * 1024, steps: 100 });
exports.NIL = Object.freeze({ t: 'null' });
exports.INT_MIN = -(1n << 63n), exports.INT_MAX = (1n << 63n) - 1n;
exports.jsonNumberPattern = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/;
const string = (v) => { if (v.length > exports.limits.cellChars)
    throw Error('A cell exceeds 1,000,000 characters.'); return { t: 'string', v }; };
exports.string = string;
function integer(v) { if (typeof v === 'number' && !Number.isSafeInteger(v))
    throw Error('Unsafe integer conversion.'); const n = BigInt(v); if (n < exports.INT_MIN || n > exports.INT_MAX)
    throw Error('Integer exceeds signed 64-bit range.'); return { t: 'int', v: n.toString() }; }
function double(v) { if (!Number.isFinite(v))
    throw Error('Non-finite numeric result.'); return { t: 'double', v }; }
const boolean = (v) => ({ t: 'bool', v });
exports.boolean = boolean;
function display(v) { return v.t === 'null' ? '' : v.t === 'blob' ? 'base64:' + v.v : String(v.v); }
function same(a, b) { return a.t === b.t && (a.t === 'null' || (b.t !== 'null' && a.v === b.v)); }
function cellKey(v) { return JSON.stringify(v); }
function truthy(v) { if (v.t === 'null')
    return false; if (v.t === 'bool')
    return v.v; if (v.t === 'int')
    return BigInt(v.v) !== 0n; if (v.t === 'double')
    return v.v !== 0; return v.v.length > 0; }
function numeric(v) { if (v.t === 'double')
    return v.v; if (v.t === 'bool')
    return v.v ? 1 : 0; if (v.t === 'int') {
    const n = Number(v.v);
    if (!Number.isSafeInteger(n))
        throw Error('Explicitly coerce this large integer to double before mixed arithmetic.');
    return n;
} throw Error('Expected a numeric cell; explicitly coerce preserved decimal text first.'); }
function requireColumn(ds, name) { const i = ds.columns.indexOf(name); if (i < 0)
    throw Error(`Missing column: ${name}`); return i; }
function uniqueColumn(columns, desired) { let n = desired, i = 2; while (columns.includes(n))
    n = `${desired}_${i++}`; return n; }
function validateValue(input) {
    if (!input || typeof input !== 'object')
        throw Error('Invalid cell.');
    const x = input;
    if (x.t === 'null')
        return exports.NIL;
    if (x.t === 'bool' && typeof x.v === 'boolean')
        return (0, exports.boolean)(x.v);
    if (x.t === 'double' && typeof x.v === 'number')
        return double(x.v);
    if (typeof x.v !== 'string' || x.v.length > exports.limits.cellChars)
        throw Error('Invalid cell content.');
    if (x.t === 'string')
        return (0, exports.string)(x.v);
    if (x.t === 'blob' && btoa(atob(x.v)) === x.v)
        return { t: 'blob', v: x.v };
    if (x.t === 'int' && /^-?(0|[1-9]\d*)$/.test(x.v) && x.v.length <= 20)
        return integer(x.v);
    if (x.t === 'decimal' && x.v.length <= 200 && exports.jsonNumberPattern.test(x.v))
        return { t: 'decimal', v: x.v };
    if (x.t === 'date' && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.test(x.v) && new Date(x.v).toISOString() === x.v)
        return { t: 'date', v: x.v };
    throw Error('Invalid typed cell.');
}
function validateDataset(input) {
    if (!input || typeof input !== 'object')
        throw Error('Invalid dataset.');
    const x = input;
    if (!Array.isArray(x.columns) || !Array.isArray(x.records) || x.columns.length > exports.limits.columns || x.records.length > exports.limits.rows || x.records.length * x.columns.length > exports.limits.cells)
        throw Error('Dataset limit exceeded (50,000 rows, 200 columns, 5 million cells).');
    if (x.columns.some(c => typeof c !== 'string' || !c.trim() || c.length > 300) || new Set(x.columns).size !== x.columns.length)
        throw Error('Columns must have distinct, nonempty names of at most 300 characters.');
    const ids = new Set();
    let size = 0;
    const records = x.records.map(r => { if (!r || !Number.isSafeInteger(r.id) || r.id < 0 || ids.has(r.id) || !Array.isArray(r.values) || r.values.length !== x.columns.length)
        throw Error('Invalid row identity or width.'); ids.add(r.id); const values = r.values.map(validateValue); size += JSON.stringify(values).length; if (size > exports.limits.datasetBytes / 2)
        throw Error('Dataset exceeds the 128 MiB in-memory text budget.'); return { id: r.id, values }; });
    return { columns: [...x.columns], records };
}
function fresh(columns, rows) { return validateDataset({ columns, records: rows.map((values, id) => ({ id, values })) }); }
function sample(ds, head = 100, spread = 100) { if (ds.records.length <= head + spread)
    return ds; const rest = ds.records.length - head, indexes = Array.from({ length: Math.min(spread, rest) }, (_, i) => head + Math.floor(i * rest / spread)); return { columns: ds.columns, records: [...ds.records.slice(0, head), ...indexes.map(i => ds.records[i])] }; }
function checkCancelled(signal) { if (signal?.aborted)
    throw new DOMException('Run cancelled; previous completed result retained.', 'AbortError'); }
const words = (s) => s.toLowerCase().normalize('NFC').match(/[\p{L}\p{M}\p{N}]+/gu) ?? [];
exports.words = words;
const graphemeSegmenter = new Intl.Segmenter('en', { granularity: 'grapheme' });
const graphemes = (s) => Array.from(graphemeSegmenter.segment(s), x => x.segment);
exports.graphemes = graphemes;
function hash64(s) { let h = 0xcbf29ce484222325n; for (const byte of new TextEncoder().encode(s))
    h = BigInt.asUintN(64, (h ^ BigInt(byte)) * 0x100000001b3n); return h; }
function splitMix(seed) { let state = BigInt.asUintN(64, seed); return () => { state = BigInt.asUintN(64, state + 0x9e3779b97f4a7c15n); let z = state; z = BigInt.asUintN(64, (z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n); z = BigInt.asUintN(64, (z ^ (z >> 27n)) * 0x94d049bb133111ebn); return BigInt.asUintN(64, z ^ (z >> 31n)); }; }
