"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.titles = exports.augmentKinds = void 0;
exports.validateOp = validateOp;
exports.parseRecipe = parseRecipe;
exports.exportRecipe = exportRecipe;
exports.makeStep = makeStep;
const model_1 = require("./model.cjs");
const normalize_1 = require("./normalize.cjs");
const quality_1 = require("./quality.cjs");
const chunker_1 = require("./chunker.cjs");
const expression_1 = require("./expression.cjs");
const lossless_json_1 = require("./lossless-json.cjs");
exports.augmentKinds = ['generateQA', 'judgeScore', 'rewrite', 'classify', 'preferencePair'];
exports.titles = { selectColumns: 'Select columns', dropColumns: 'Drop columns', renameColumn: 'Rename column', addColumn: 'Add computed column', filterRows: 'Filter rows', normalizeText: 'Normalize text', unifyNulls: 'Unify nulls', autoType: 'Auto-detect types', coerceType: 'Coerce type', dedupeExact: 'Exact duplicates', dedupeFuzzy: 'Near-duplicates', redactPII: 'Redact PII & secrets', qualityFilter: 'Quality filter', languageFilter: 'Language filter', decontaminate: 'Decontaminate vs evaluation set', addTokenCount: 'Token count', addLanguage: 'Language', addQualityScore: 'Quality score', chunkText: 'Chunk for RAG', split: 'Train / validation / test split', augment: 'Optional augmentation' };
function object(x) { if (!x || typeof x !== 'object' || Array.isArray(x))
    throw Error('Expected an operation object.'); return x; }
function str(x, max = 300, empty = false) { if (typeof x !== 'string' || x.length > max || (!empty && !x.trim()))
    throw Error(`Expected ${empty ? 'a' : 'a nonempty'} string of at most ${max} characters.`); return x; }
function list(x, max = 200, itemMax = 300) { if (!Array.isArray(x) || x.length > max)
    throw Error('Invalid list length.'); return x.map(v => str(v, itemMax)); }
function num(x, min, max, integer = false) { if (typeof x !== 'number' || !Number.isFinite(x) || x < min || x > max || (integer && !Number.isInteger(x)))
    throw Error(`Expected ${integer ? 'an integer' : 'a number'} between ${min} and ${max}.`); return x; }
function choice(x, choices) { if (typeof x !== 'string' || !choices.includes(x))
    throw Error('Unsupported operation option.'); return x; }
function bool(x) { if (typeof x !== 'boolean')
    throw Error('Expected a boolean.'); return x; }
function validateOp(input) {
    let x = object(input);
    if (!Object.hasOwn(x, 'kind')) {
        const keys = Object.keys(x);
        if (keys.length !== 1)
            throw Error('Invalid Mac recipe operation.');
        x = { ...object(x[keys[0]]), kind: keys[0] };
    }
    const kind = choice(x.kind, Object.keys(exports.titles)), columns = () => { const c = list(x.columns ?? []); if (new Set(c).size !== c.length)
        throw Error('Repeated column selection.'); return c; }, column = () => str(x.column);
    switch (kind) {
        case 'selectColumns':
        case 'dropColumns':
        case 'unifyNulls':
        case 'dedupeExact': return { kind, columns: columns() };
        case 'renameColumn': return { kind, from: str(x.from), to: str(x.to) };
        case 'addColumn':
        case 'filterRows': {
            const expression = str(x.expression, 10000);
            (0, expression_1.parseExpression)(expression);
            return kind === 'filterRows' ? { kind, expression } : { kind, name: str(x.name), expression };
        }
        case 'normalizeText': {
            const raw = { ...normalize_1.standard, ...object(x.options ?? {}) }, options = { ...normalize_1.standard };
            for (const key of Object.keys(normalize_1.standard)) {
                if (key === 'unicodeForm')
                    options[key] = choice(raw[key], ['none', 'nfc', 'nfkc']);
                else
                    options[key] = bool(raw[key]);
            }
            return { kind, columns: columns(), options };
        }
        case 'autoType': return { kind };
        case 'coerceType': return { kind, column: column(), type: choice(x.type, ['string', 'int', 'double', 'bool', 'date']) };
        case 'dedupeFuzzy': return { kind, column: column(), threshold: num(x.threshold, .5, 1) };
        case 'redactPII': return { kind, columns: columns(), kinds: list(x.kinds ?? [], 8).map(k => choice(k, quality_1.piiKinds)), mode: choice(x.mode, ['tag', 'hash', 'remove']) };
        case 'qualityFilter': {
            const raw = { ...quality_1.standardQuality, ...object(x.rules ?? {}) }, rules = { ...quality_1.standardQuality };
            for (const key of Object.keys(quality_1.standardQuality)) {
                if (key === 'flagTruncated' || key === 'requireTerminalPunctuation')
                    rules[key] = bool(raw[key]);
                else
                    rules[key] = num(raw[key], 0, key === 'maxWords' ? 100000 : key === 'minWords' ? 100000 : key.includes('WordLength') ? 100 : 1, key === 'minWords' || key === 'maxWords');
            }
            if (rules.minWords > rules.maxWords || rules.minMeanWordLength > rules.maxMeanWordLength)
                throw Error('Quality minimum exceeds maximum.');
            return { kind, column: column(), rules };
        }
        case 'languageFilter': {
            const allowed = list(x.allowed, 30, 8);
            if (allowed.some(c => !/^[a-z]{2,3}$/.test(c)))
                throw Error('Invalid language code.');
            return { kind, column: column(), allowed, minConfidence: num(x.minConfidence, 0, 1) };
        }
        case 'decontaminate': {
            const evalTexts = list(x.evalTexts, 100, model_1.limits.cellChars);
            if (evalTexts.reduce((n, s) => n + s.length, 0) > 4_000_000)
                throw Error('Evaluation text exceeds four million characters.');
            return { kind, column: column(), evalTexts, nGramSize: num(x.nGramSize, 1, 20, true) };
        }
        case 'addTokenCount':
        case 'addLanguage':
        case 'addQualityScore': return { kind, column: column() };
        case 'chunkText': {
            const r = { ...chunker_1.defaultChunk, ...object(x.config ?? {}) }, config = { targetTokens: num(r.targetTokens, 32, 8192, true), overlapTokens: num(r.overlapTokens, 0, 8191, true), minChunkTokens: num(r.minChunkTokens, 0, 8192, true), respectMarkdown: bool(r.respectMarkdown), includeHeadingContext: bool(r.includeHeadingContext) };
            if (config.overlapTokens >= config.targetTokens || config.minChunkTokens > config.targetTokens)
                throw Error('Overlap/minimum must fit the target chunk budget.');
            return { kind, column: column(), config };
        }
        case 'split': {
            const train = num(x.train, 0, 1), validation = num(x.validation, 0, 1), test = num(x.test, 0, 1);
            if (Math.abs(train + validation + test - 1) > 1e-9)
                throw Error('Split fractions must sum to one.');
            if (typeof x.seed === 'number' && !Number.isSafeInteger(x.seed))
                throw Error('Large seeds must be preserved as decimal strings.');
            const seed = String(x.seed);
            if (!/^\d{1,20}$/.test(seed) || BigInt(seed) > (1n << 64n) - 1n)
                throw Error('Seed must be an unsigned 64-bit integer.');
            return { kind, train, validation, test, seed, stratifyBy: x.stratifyBy == null ? null : str(x.stratifyBy) };
        }
        case 'augment': {
            const r = object(x.config), labels = list(r.labels ?? [], 100, 100);
            if (new Set(labels).size !== labels.length)
                throw Error('Duplicate classification labels.');
            return { kind, config: { kind: choice(r.kind, exports.augmentKinds), column: str(r.column), instruction: str(r.instruction ?? '', 4000, true), labels, concurrency: num(r.concurrency ?? 4, 1, 16, true), maxTokens: num(r.maxTokens ?? 1024, 128, 8192, true) } };
        }
    }
}
function plain(v) { if (v instanceof lossless_json_1.JSONNumber) {
    const n = Number(v.raw);
    if (!Number.isFinite(n))
        throw Error('Recipe number is not finite.');
    return /^-?\d+$/.test(v.raw) && !Number.isSafeInteger(n) ? v.raw : n;
} if (Array.isArray(v))
    return v.map(plain); if (v !== null && typeof v === 'object') {
    const o = Object.create(null);
    for (const [k, x] of Object.entries(v))
        o[k] = plain(x);
    return o;
} return v; }
function parseRecipe(text) { if (text.length > 8_000_000)
    throw Error('Recipe exceeds 8 million characters.'); const x = object(plain((0, lossless_json_1.parseLossless)(text))); if (x.version !== 1)
    throw Error('Unsupported recipe version.'); if (!Array.isArray(x.ops) || x.ops.length > model_1.limits.steps)
    throw Error('Recipe exceeds 100 steps.'); const createdAt = str(x.createdAt, 40); if (!Number.isFinite(Date.parse(createdAt)))
    throw Error('Invalid recipe date.'); return { name: str(x.name, 300), createdAt, ops: x.ops.map(validateOp) }; }
function exportRecipe(name, steps, createdAt = new Date().toISOString()) { const ops = steps.filter(s => s.enabled).map(s => { const { kind, ...args } = validateOp(s.op); const params = args; if (kind === 'split')
    params.seed = new lossless_json_1.JSONNumber(String(params.seed)); return { [kind]: params }; }); return (0, lossless_json_1.stringifyLossless)({ version: 1, name, createdAt, ops }) + '\n'; }
function makeStep(op) { return { id: crypto.randomUUID(), enabled: true, op: validateOp(op) }; }
