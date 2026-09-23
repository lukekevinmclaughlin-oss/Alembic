"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.splitDataset = splitDataset;
exports.runPipeline = runPipeline;
const model_1 = require("./model.cjs");
const recipe_1 = require("./recipe.cjs");
const normalize_1 = require("./normalize.cjs");
const types_1 = require("./types.cjs");
const dedupe_1 = require("./dedupe.cjs");
const expression_1 = require("./expression.cjs");
const quality_1 = require("./quality.cjs");
const chunker_1 = require("./chunker.cjs");
function splitDataset(ds, op) {
    const groups = new Map(), idx = op.stratifyBy ? (0, model_1.requireColumn)(ds, op.stratifyBy) : -1;
    for (const r of ds.records) {
        const key = idx >= 0 ? (0, model_1.cellKey)(r.values[idx]) : '';
        const ids = groups.get(key) ?? [];
        ids.push(r.id);
        groups.set(key, ids);
    }
    const assignment = new Map();
    for (const [key, ids] of [...groups].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)) {
        const random = (0, model_1.splitMix)(BigInt(op.seed) + (0, model_1.hash64)(key + '|' + ids.join(','))), shuffled = [...ids];
        for (let i = shuffled.length - 1; i > 0; i--) {
            const range = BigInt(i + 1), ceiling = (1n << 64n) - ((1n << 64n) % range);
            let n = random();
            while (n >= ceiling)
                n = random();
            const j = Number(n % range);
            [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
        }
        const quotas = [op.train, op.validation, op.test].map(f => f * ids.length), counts = quotas.map(Math.floor), remainders = quotas.map((q, i) => ({ i, remainder: q - counts[i] })).sort((a, b) => b.remainder - a.remainder || a.i - b.i);
        for (let left = ids.length - counts.reduce((a, b) => a + b, 0), j = 0; left > 0; left--, j++)
            counts[remainders[j].i]++;
        shuffled.forEach((id, i) => assignment.set(id, i < counts[0] ? 'train' : i < counts[0] + counts[1] ? 'validation' : 'test'));
    }
    return { columns: [...ds.columns, (0, model_1.uniqueColumn)(ds.columns, 'split')], records: ds.records.map(r => ({ id: r.id, values: [...r.values, (0, model_1.string)(assignment.get(r.id))] })) };
}
async function runPipeline(input, steps, tokenizer, options = {}) {
    if (steps.length > model_1.limits.steps)
        throw Error('Pipeline exceeds 100 steps.');
    let current = (0, model_1.validateDataset)(input);
    const metrics = [], rejected = [], conversions = [];
    const active = steps.filter(s => s.enabled);
    let skippedAugmentations = 0;
    for (let stepIndex = 0; stepIndex < active.length; stepIndex++) {
        (0, model_1.checkCancelled)(options.signal);
        const step = active[stepIndex], op = (0, recipe_1.validateOp)(step.op);
        options.progress?.(stepIndex, active.length, recipe_1.titles[op.kind]);
        (0, model_1.checkCancelled)(options.signal);
        if (options.preview && op.kind === 'augment') {
            skippedAugmentations++;
            continue;
        }
        const before = current, m = { stepId: step.id, opName: recipe_1.titles[op.kind], rowsIn: before.records.length, rowsOut: 0, cellsChanged: 0, notes: {} }, drops = { stepId: step.id, opName: m.opName, columns: before.columns, rows: [] };
        let out = { columns: [...before.columns], records: before.records.map(r => ({ id: r.id, values: [...r.values] })) };
        const column = (name) => (0, model_1.requireColumn)(before, name), indexes = (columns) => columns.length ? columns.map(column) : before.columns.map((_, i) => i), set = (r, i, v) => { if (!(0, model_1.same)(r.values[i], v)) {
            r.values[i] = v;
            m.cellsChanged++;
        } }, append = (base, values) => { const name = (0, model_1.uniqueColumn)(out.columns, base); out.columns.push(name); out.records.forEach((r, i) => r.values.push(values[i])); m.cellsChanged += values.length; m.notes.addedColumn = name; }, filter = (predicate) => { out.records = out.records.filter(r => { (0, model_1.checkCancelled)(options.signal); const reason = predicate(r); if (reason !== null) {
            drops.rows.push({ record: r, reason });
            return false;
        } return true; }); };
        try {
            switch (op.kind) {
                case 'selectColumns':
                case 'dropColumns': {
                    const selected = indexes(op.columns);
                    const keep = op.kind === 'selectColumns' ? op.columns.map(column) : out.columns.map((_, i) => i).filter(i => !selected.includes(i) || !op.columns.length);
                    if (!keep.length)
                        throw Error('Select at least one output column.');
                    out = { columns: keep.map(i => before.columns[i]), records: before.records.map(r => ({ id: r.id, values: keep.map(i => r.values[i]) })) };
                    break;
                }
                case 'renameColumn': {
                    const i = column(op.from);
                    if (op.to !== op.from && out.columns.includes(op.to))
                        throw Error('Renamed column would overwrite an existing column.');
                    out.columns[i] = op.to;
                    break;
                }
                case 'addColumn': {
                    if (out.columns.includes(op.name))
                        throw Error('Computed column already exists.');
                    const expr = (0, expression_1.parseExpression)(op.expression), values = before.records.map(r => { (0, model_1.checkCancelled)(options.signal); try {
                        return (0, expression_1.evaluateExpression)(expr, before, r, tokenizer);
                    }
                    catch (e) {
                        throw Error(`Row ${r.id}: ${e.message}`);
                    } });
                    append(op.name, values);
                    break;
                }
                case 'filterRows': {
                    const expr = (0, expression_1.parseExpression)(op.expression);
                    filter(r => (0, model_1.truthy)((0, expression_1.evaluateExpression)(expr, before, r, tokenizer)) ? null : 'Filter expression was false.');
                    break;
                }
                case 'normalizeText': {
                    for (const r of out.records) {
                        (0, model_1.checkCancelled)(options.signal);
                        for (const i of indexes(op.columns)) {
                            const v = r.values[i];
                            if (v.t === 'string') {
                                const s = (0, normalize_1.normalize)(v.v, op.options);
                                set(r, i, s ? (0, model_1.string)(s) : model_1.NIL);
                            }
                        }
                    }
                    m.notes.zeroWidth = op.options.stripZeroWidth ? 'Enabled; can alter emoji joins and writing-system shaping.' : 'Preserved';
                    break;
                }
                case 'unifyNulls':
                    for (const r of out.records) {
                        (0, model_1.checkCancelled)(options.signal);
                        for (const i of indexes(op.columns)) {
                            const v = r.values[i];
                            if (v.t === 'string' && (0, types_1.isNullString)(v.v))
                                set(r, i, model_1.NIL);
                        }
                    }
                    break;
                case 'autoType':
                case 'coerceType': {
                    let losses = 0, approximate = 0;
                    const idxs = op.kind === 'coerceType' ? [column(op.column)] : out.columns.map((_, i) => i);
                    for (const i of idxs) {
                        const type = op.kind === 'coerceType' ? op.type : (0, types_1.inferType)(out.records.map(r => r.values[i]));
                        if (op.kind === 'autoType' && type === 'string')
                            continue;
                        m.notes['type:' + out.columns[i]] = type;
                        for (const r of out.records) {
                            (0, model_1.checkCancelled)(options.signal);
                            const old = r.values[i], value = (0, types_1.coerce)(old, type);
                            if (value.t === 'null' && old.t !== 'null' && !(old.t === 'string' && (0, types_1.isNullString)(old.v))) {
                                losses++;
                                conversions.push({ stepId: step.id, recordId: r.id, column: out.columns[i], original: old, target: type });
                            }
                            if (type === 'double' && (old.t === 'decimal' || old.t === 'int' && !Number.isSafeInteger(Number(old.v))))
                                approximate++;
                            set(r, i, value);
                        }
                    }
                    m.notes.failedConversions = String(losses);
                    if (approximate)
                        m.notes.approximateDoubleConversions = String(approximate);
                    m.notes.dateConvention = 'UTC; ambiguous dotted dates use day/month; ambiguous slashed/dashed dates use month/day.';
                    break;
                }
                case 'dedupeExact':
                case 'dedupeFuzzy': {
                    const found = op.kind === 'dedupeFuzzy' ? (0, dedupe_1.fuzzyDedupe)(before, op.column, op.threshold, options.signal) : (0, dedupe_1.exactDedupe)(before, op.columns, options.signal), removed = new Set(found.droppedIDs);
                    filter(r => removed.has(r.id) ? 'Duplicate cluster; earliest row retained.' : null);
                    m.notes.clusters = String(found.clusters.length);
                    m.notes.candidatePairs = String(found.candidates);
                    m.notes.method = found.method;
                    break;
                }
                case 'redactPII': {
                    const counts = Object.create(null);
                    for (const r of out.records) {
                        (0, model_1.checkCancelled)(options.signal);
                        for (const i of indexes(op.columns)) {
                            const old = r.values[i];
                            if (old.t !== 'string')
                                continue;
                            const redacted = await (0, quality_1.redactPII)(old.v, op.kinds, op.mode);
                            set(r, i, (0, model_1.string)(redacted.text));
                            for (const [k, n] of Object.entries(redacted.counts))
                                counts[k] = (counts[k] ?? 0) + n;
                        }
                    }
                    for (const [k, n] of Object.entries(counts))
                        m.notes[k] = String(n);
                    m.notes.scope = 'Pattern-based detection can miss PII and can flag non-PII; review before sharing. Hashes are unsalted pseudonyms, not anonymization.';
                    break;
                }
                case 'qualityFilter': {
                    const i = column(op.column);
                    filter(r => { const verdict = (0, quality_1.quality)((0, model_1.display)(r.values[i]), op.rules); return verdict.passed ? null : verdict.reasons.join('; '); });
                    m.notes.method = 'Configurable text heuristics, including whitespace-based word counts; language/domain review required.';
                    break;
                }
                case 'languageFilter': {
                    const i = column(op.column);
                    filter(r => { const d = (0, quality_1.language)((0, model_1.display)(r.values[i])); return op.allowed.includes(d.code) && d.confidence >= op.minConfidence ? null : `Language ${d.code}, heuristic score ${d.confidence.toFixed(3)}; ${d.method}${d.script ? ' (' + d.script + ')' : ''}`; });
                    m.notes.method = 'Ten Latin stopword profiles; Japanese/Hangul script heuristics. Shared scripts remain undetermined.';
                    break;
                }
                case 'decontaminate': {
                    const i = column(op.column), index = (0, quality_1.evaluationIndex)(op.evalTexts, op.nGramSize);
                    filter(r => { let hits = 0; for (const g of (0, quality_1.ngrams)((0, model_1.display)(r.values[i]), op.nGramSize))
                        if (index.has(g))
                            hits++; return hits ? `${hits} exact normalized ${op.nGramSize}-word n-gram matches in evaluation text.` : null; });
                    m.notes.indexedNGrams = String(index.size);
                    m.notes.method = 'Exact normalized word overlap; not semantic leakage detection.';
                    break;
                }
                case 'addTokenCount': {
                    const i = column(op.column);
                    append('token_count', out.records.map(r => { (0, model_1.checkCancelled)(options.signal); return (0, model_1.integer)(tokenizer.count((0, model_1.display)(r.values[i]))); }));
                    m.notes.tokenizer = tokenizer.name;
                    break;
                }
                case 'addLanguage': {
                    const i = column(op.column), detections = out.records.map(r => (0, quality_1.language)((0, model_1.display)(r.values[i])));
                    append('lang', detections.map(d => (0, model_1.string)(d.code)));
                    append('lang_confidence', detections.map(d => (0, model_1.double)(d.confidence)));
                    m.notes.method = 'Heuristic score is not a probability; shared scripts may return und.';
                    break;
                }
                case 'addQualityScore': {
                    const i = column(op.column);
                    append('quality_score', out.records.map(r => (0, model_1.double)((0, quality_1.quality)((0, model_1.display)(r.values[i])).score)));
                    m.notes.method = '1 minus 0.25 per failed default heuristic, floored at zero.';
                    break;
                }
                case 'chunkText': {
                    const i = column(op.column), names = [];
                    for (const base of ['chunk_index', 'chunk_tokens', 'heading_path']) {
                        const name = (0, model_1.uniqueColumn)(out.columns, base);
                        out.columns.push(name);
                        names.push(name);
                    }
                    let nextID = Math.max(-1, ...before.records.map(r => r.id)) + 1;
                    out.records = [];
                    for (const r of before.records) {
                        (0, model_1.checkCancelled)(options.signal);
                        const chunks = (0, chunker_1.chunkText)((0, model_1.display)(r.values[i]), op.config, tokenizer, options.signal);
                        if (!chunks.length)
                            drops.rows.push({ record: r, reason: 'Empty text produced no chunks.' });
                        for (let k = 0; k < chunks.length; k++) {
                            if (out.records.length >= model_1.limits.rows)
                                throw Error('Chunked dataset exceeds 50,000 rows.');
                            const c = chunks[k], values = [...r.values];
                            values[i] = (0, model_1.string)(c.text);
                            out.records.push({ id: k === 0 ? r.id : nextID++, values: [...values, (0, model_1.integer)(c.index), (0, model_1.integer)(c.tokenCount), (0, model_1.string)(c.headingPath)] });
                        }
                    }
                    m.cellsChanged = out.records.length * 4;
                    m.notes.tokenizer = tokenizer.name;
                    m.notes.addedColumns = names.join(', ');
                    m.notes.budget = 'Every emitted chunk including heading is at or below target; oversized words split at grapheme boundaries.';
                    break;
                }
                case 'split':
                    out = splitDataset(out, op);
                    m.cellsChanged = out.records.length;
                    m.notes.seed = op.seed;
                    m.notes.method = 'Windows v1 SplitMix64/Fisher–Yates, largest-remainder counts per stratum. Repeatable within this engine; not bit-identical to Swift shuffle.';
                    break;
                case 'augment': {
                    if (!options.augment)
                        throw Error('Choose a provider and review augmentation consent before running.');
                    const result = await options.augment(op.config, before, options.signal);
                    out = result.dataset;
                    Object.assign(m.notes, result.notes);
                    break;
                }
            }
            (0, model_1.checkCancelled)(options.signal);
            current = (0, model_1.validateDataset)(out);
            m.rowsOut = current.records.length;
            metrics.push(m);
            if (drops.rows.length)
                rejected.push(drops);
        }
        catch (e) {
            if (e.name === 'AbortError')
                throw e;
            throw Error(`Step ${stepIndex + 1} (${m.opName}): ${e.message}`);
        }
        await new Promise(resolve => setTimeout(resolve, 0));
    }
    (0, model_1.checkCancelled)(options.signal);
    return { dataset: current, metrics, rejected, conversions, complete: !options.preview, skippedAugmentations };
}
