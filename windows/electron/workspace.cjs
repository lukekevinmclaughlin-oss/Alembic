"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.MAX_WORKSPACE_BYTES = void 0;
exports.emptyWorkspace = emptyWorkspace;
exports.validateSteps = validateSteps;
exports.validateImport = validateImport;
exports.validateResult = validateResult;
exports.validateWorkspace = validateWorkspace;
exports.parseWorkspace = parseWorkspace;
exports.stringifyWorkspace = stringifyWorkspace;
exports.guessTextColumn = guessTextColumn;
exports.starterSteps = starterSteps;
exports.editSteps = editSteps;
exports.historyStep = historyStep;
const model_1 = require("./model.cjs");
const recipe_1 = require("./recipe.cjs");
const normalize_1 = require("./normalize.cjs");
const chunker_1 = require("./chunker.cjs");
exports.MAX_WORKSPACE_BYTES = 256 * 1024 * 1024;
function emptyWorkspace() { return { version: 1, revision: 0, theme: 'system', reduceMotion: false, mode: 'curate', screen: 'pipeline', source: null, steps: [], undo: [], redo: [], completed: null, cache: Object.create(null), priceInput: null, priceOutput: null }; }
function obj(x) { if (!x || typeof x !== 'object' || Array.isArray(x))
    throw Error('Invalid workspace object.'); return x; }
function text(x, max = 1000) { if (typeof x !== 'string' || x.length > max)
    throw Error('Invalid workspace text.'); return x; }
function int(x, max = Number.MAX_SAFE_INTEGER) { if (typeof x !== 'number' || !Number.isSafeInteger(x) || x < 0 || x > max)
    throw Error('Invalid workspace count.'); return x; }
function choice(x, values) { if (typeof x !== 'string' || !values.includes(x))
    throw Error('Invalid workspace option.'); return x; }
function bool(x) { if (typeof x !== 'boolean')
    throw Error('Invalid workspace boolean.'); return x; }
function array(x, max) { if (!Array.isArray(x) || x.length > max)
    throw Error('Invalid workspace list.'); return x; }
function details(x, max = 200) { const entries = Object.entries(obj(x)); if (entries.length > max)
    throw Error('Too many metadata fields.'); const out = Object.create(null); for (const [k, v] of entries)
    out[text(k, 400)] = text(v, 8000); return out; }
function validateSteps(x) { const ids = new Set(); return array(x, model_1.limits.steps).map(v => { const s = obj(v), id = text(s.id, 80); if (!id || ids.has(id))
    throw Error('Invalid or duplicate step identity.'); ids.add(id); return { id, enabled: bool(s.enabled), op: (0, recipe_1.validateOp)(s.op) }; }); }
function validateImport(x) { const s = obj(x), dataset = (0, model_1.validateDataset)(s.dataset); return { dataset, source: text(s.source, 1000), format: choice(s.format, ['csv', 'tsv', 'json', 'jsonl', 'text', 'markdown', 'html', 'sqlite', 'folder']), details: details(s.details), warnings: array(s.warnings, 1000).map(s => text(s, 10000)), rejected: array(s.rejected, 50000).map(v => { const r = obj(v); return { row: int(r.row, 50001), reason: text(r.reason, 10000), original: text(r.original, model_1.limits.cellChars) }; }) }; }
function validateMetrics(x) { return array(x, 100).map(v => { const m = obj(v); return { stepId: text(m.stepId, 80), opName: text(m.opName, 200), rowsIn: int(m.rowsIn, 50000), rowsOut: int(m.rowsOut, 50000), cellsChanged: int(m.cellsChanged, 10000000), notes: details(m.notes, 500) }; }); }
function validateResult(x) { const r = obj(x), dataset = (0, model_1.validateDataset)(r.dataset), rejected = array(r.rejected, 100).map(v => { const b = obj(v), rows = array(b.rows, 50000).map(v => obj(v)), checked = (0, model_1.validateDataset)({ columns: b.columns, records: rows.map(r => r.record) }); return { stepId: text(b.stepId, 80), opName: text(b.opName, 200), columns: checked.columns, rows: rows.map((r, i) => ({ record: checked.records[i], reason: text(r.reason, 10000) })) }; }), conversions = array(r.conversions, 5000000).map(v => { const c = obj(v); return { stepId: text(c.stepId, 80), recordId: int(c.recordId), column: text(c.column, 300), original: (0, model_1.validateValue)(c.original), target: choice(c.target, ['int', 'double', 'bool', 'date', 'string']) }; }); return { dataset, metrics: validateMetrics(r.metrics), rejected, conversions, complete: bool(r.complete), skippedAugmentations: int(r.skippedAugmentations, 100) }; }
function validateWorkspace(input) {
    const s = obj(input);
    if (s.version !== 1)
        throw Error('Unsupported workspace version.');
    const revision = int(s.revision), source = s.source === null ? null : validateImport(s.source), steps = validateSteps(s.steps), cache = Object.create(null), entries = Object.entries(obj(s.cache));
    if (entries.length > 50000)
        throw Error('Augmentation cache exceeds 50,000 entries.');
    let cacheBytes = 0;
    for (const [k, v] of entries) {
        if (!/^[0-9a-f]{64}$/.test(k))
            throw Error('Invalid checkpoint identity.');
        const values = array(v, 2).map(model_1.validateValue);
        cacheBytes += JSON.stringify(values).length;
        if (cacheBytes > 32 * 1024 * 1024)
            throw Error('Augmentation cache exceeds 64 MiB of text.');
        cache[k] = values;
    }
    let completed = null;
    if (s.completed !== null) {
        const c = obj(s.completed), result = validateResult(c.result);
        if (!result.complete)
            throw Error('A sampled preview cannot be restored as a full result.');
        completed = { revision: int(c.revision), result };
        if (completed.revision > revision || !source)
            throw Error('Completed result does not belong to this workspace.');
    }
    const history = (x) => array(x, 100).map(validateSteps), price = (x) => { if (x === null)
        return null; if (typeof x !== 'number' || !Number.isFinite(x) || x < 0 || x > 1000000)
        throw Error('Invalid optional provider price.'); return x; };
    return { version: 1, revision, theme: choice(s.theme, ['system', 'light', 'dark']), reduceMotion: bool(s.reduceMotion), mode: choice(s.mode, ['curate', 'retrieve']), screen: choice(s.screen, ['pipeline', 'preview', 'report', 'export', 'settings']), source, steps, undo: history(s.undo), redo: history(s.redo), completed, cache, priceInput: price(s.priceInput), priceOutput: price(s.priceOutput) };
}
function parseWorkspace(text) { if (new TextEncoder().encode(text).length > exports.MAX_WORKSPACE_BYTES)
    throw Error('Workspace exceeds 256 MiB.'); return validateWorkspace(JSON.parse(text)); }
function stringifyWorkspace(s) { const raw = JSON.stringify(s); if (new TextEncoder().encode(raw).length > exports.MAX_WORKSPACE_BYTES)
    throw Error('Workspace exceeds 256 MiB; export and start a smaller batch.'); return raw; }
function guessTextColumn(ds) { let best = ds.columns[0] ?? 'text', score = -1; ds.columns.forEach((c, i) => { let length = 0; for (const r of ds.records.slice(0, 50)) {
    const v = r.values[i];
    if (v.t === 'string')
        length += v.v.length;
} if (length > score) {
    score = length;
    best = c;
} }); return best; }
function starterSteps(mode, ds) { const column = guessTextColumn(ds); return (mode === 'curate' ? [{ kind: 'normalizeText', columns: [], options: normalize_1.standard }, { kind: 'unifyNulls', columns: [] }, { kind: 'autoType' }, { kind: 'dedupeExact', columns: [] }] : [{ kind: 'normalizeText', columns: [], options: normalize_1.standard }, { kind: 'chunkText', column, config: chunker_1.defaultChunk }, { kind: 'addTokenCount', column }]).map(recipe_1.makeStep); }
function editSteps(s, steps) { const checked = validateSteps(steps), undo = [...s.undo, s.steps]; while (undo.length > 100 || JSON.stringify(undo).length > 4 * 1024 * 1024)
    undo.shift(); return { ...s, revision: s.revision + 1, steps: checked, undo, redo: [] }; }
function historyStep(s, direction) { const stack = s[direction]; if (!stack.length)
    return s; const previous = stack.at(-1); return { ...s, revision: s.revision + 1, steps: previous, [direction]: stack.slice(0, -1), [direction === 'undo' ? 'redo' : 'undo']: [...s[direction === 'undo' ? 'redo' : 'undo'], s.steps].slice(-100) }; }
