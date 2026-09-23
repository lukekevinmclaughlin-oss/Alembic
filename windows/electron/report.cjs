"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.tokenStats = tokenStats;
exports.profileColumn = profileColumn;
exports.datasetCard = datasetCard;
exports.cardMarkdown = cardMarkdown;
exports.datasetDiff = datasetDiff;
const model_1 = require("./model.cjs");
const quality_1 = require("./quality.cjs");
function tokenStats(counts, totalRows = counts.length) { if (!counts.length)
    return null; const sorted = [...counts].sort((a, b) => a - b), sampleTotal = counts.reduce((a, b) => a + b, 0), mean = sampleTotal / counts.length, bounds = [0, 64, 128, 256, 512, 1024, 2048, 4096, 8192, Infinity]; const histogram = bounds.slice(0, -1).map((min, i) => ({ label: Number.isFinite(bounds[i + 1]) ? `${min}–${bounds[i + 1] - 1}` : `${min}+`, count: counts.filter(n => n >= min && n < bounds[i + 1]).length })).filter(b => b.count); return { sampleRows: counts.length, sampled: counts.length < totalRows, min: sorted[0], max: sorted.at(-1), mean, p50: sorted[Math.floor((sorted.length - 1) * .5)], p95: sorted[Math.floor((sorted.length - 1) * .95)], sampleTotal, estimatedTotal: Math.round(mean * totalRows), histogram }; }
function numericStats(values) { const nums = values.filter(v => v.t === 'int' || v.t === 'double'); if (!nums.length)
    return null; if (nums.every(v => v.t === 'int')) {
    const ints = nums.map(v => BigInt(v.v));
    let sum = 0n, min = ints[0], max = ints[0];
    for (const n of ints) {
        sum += n;
        if (n < min)
            min = n;
        if (n > max)
            max = n;
    }
    const count = BigInt(ints.length), negative = sum < 0n, absolute = negative ? -sum : sum, whole = absolute / count, fraction = (absolute % count * 1000000n / count).toString().padStart(6, '0');
    return { min: min.toString(), max: max.toString(), mean: (negative ? '-' : '') + whole + '.' + fraction, note: 'Exact integer extrema; mean truncated to six decimal places.' };
} if (nums.some(v => v.t === 'int' && !Number.isSafeInteger(Number(v.v))))
    return { min: '—', max: '—', mean: '—', note: 'Mixed large integers and doubles: numeric summary withheld to avoid rounding exact integers.' }; const xs = nums.map(v => Number(v.v)); let min = xs[0], max = xs[0], mean = 0; xs.forEach((n, i) => { min = Math.min(min, n); max = Math.max(max, n); mean = mean * (i / (i + 1)) + n / (i + 1); }); return { min: String(min), max: String(max), mean: Number.isFinite(mean) ? String(mean) : 'unavailable', note: 'Binary floating-point summary; exact decimal-text cells are excluded.' }; }
function profileColumn(ds, column, tokenizer, withTokens = true) {
    const idx = (0, model_1.requireColumn)(ds, column), values = ds.records.map(r => r.values[idx]), types = new Map(), unique = new Set(), top = new Map();
    let nonNull = 0, uniqueCapped = false, topValuesCapped = false;
    for (const v of values) {
        if (v.t === 'null')
            continue;
        nonNull++;
        types.set(v.t, (types.get(v.t) ?? 0) + 1);
        const key = (0, model_1.cellKey)(v);
        if (unique.has(key)) { }
        else if (unique.size < 10000)
            unique.add(key);
        else
            uniqueCapped = true;
        const old = top.get(key);
        if (old)
            old.count++;
        else if (top.size < 10000)
            top.set(key, { value: (0, model_1.display)(v), type: v.t, count: 1 });
        else
            topValuesCapped = true;
    }
    const typeMix = [...types].map(([type, count]) => ({ type, count })).sort((a, b) => b.count - a.count || a.type.localeCompare(b.type, 'en')), sampled = (0, model_1.sample)(ds, 1000, 1000);
    return { name: column, rows: values.length, nonNull, nullFraction: values.length ? (values.length - nonNull) / values.length : 0, dominantType: typeMix[0]?.type ?? 'null', typeMix, uniqueCount: unique.size, uniqueCapped, topValues: [...top.values()].sort((a, b) => b.count - a.count || a.value.localeCompare(b.value, 'en')).slice(0, 10), topValuesCapped, numeric: numericStats(values), tokens: withTokens && values.some(v => v.t === 'string') ? tokenStats(sampled.records.map(r => tokenizer.count((0, model_1.display)(r.values[idx]))), values.length) : null };
}
function datasetCard(ds, metrics, tokenizer, now = new Date().toISOString()) { let textColumn = null, maxText = 0; ds.columns.forEach((c, i) => { let length = 0; for (const r of ds.records) {
    const v = r.values[i];
    if (v.t === 'string')
        length += v.v.length;
} if (length > maxText) {
    maxText = length;
    textColumn = c;
} }); const columns = ds.columns.map(c => profileColumn(ds, c, tokenizer, c === textColumn)), mix = new Map(); let languageSampleRows = 0; if (textColumn) {
    const idx = (0, model_1.requireColumn)(ds, textColumn), sampled = (0, model_1.sample)(ds, 250, 250);
    languageSampleRows = sampled.records.length;
    for (const r of sampled.records) {
        const code = (0, quality_1.language)((0, model_1.display)(r.values[idx])).code;
        mix.set(code, (mix.get(code) ?? 0) + 1);
    }
} return { generatedAt: now, engine: 'Alembic Windows 1', rows: ds.records.length, columnCount: ds.columns.length, columns, textColumn, tokenizer: tokenizer.name, languageSampleRows, languageMix: [...mix].map(([code, count]) => ({ code, count, fraction: count / Math.max(1, languageSampleRows) })).sort((a, b) => b.count - a.count || a.code.localeCompare(b.code, 'en')), metrics, notes: ['Token statistics use at most 2,000 deterministic head/spread rows; totals are estimates when sampled.', 'Language mix uses at most 500 head/spread rows and offline heuristics; und means undetermined.', 'Exact-decimal text preserves JSON numeric literals; coerce explicitly for floating-point operations.', 'PII, quality and overlap checks are limited detectors, not guarantees of anonymization, truth or training suitability.'] }; }
const md = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\|/g, '\\|').replace(/[\r\n]+/g, ' ');
function cardMarkdown(card) { let out = `# Dataset Card\n\n${card.engine} · ${card.generatedAt}\n\n**${card.rows} rows × ${card.columnCount} columns**\n\nTokenizer: ${md(card.tokenizer)}.\n\n| Column | Dominant type | Nulls | Distinct typed cells |\n|---|---|---|---|\n`; for (const c of card.columns)
    out += `| ${md(c.name)} | ${c.dominantType} | ${(c.nullFraction * 100).toFixed(1)}% | ${c.uniqueCount}${c.uniqueCapped ? '+' : ''} |\n`; const tokens = card.columns.find(c => c.name === card.textColumn)?.tokens; if (tokens) {
    out += `\n## Token distribution\n\nColumn: ${md(card.textColumn)}. ${tokens.sampleRows} ${tokens.sampled ? 'sampled' : 'total'} rows. ${tokens.sampled ? 'Estimated' : 'Exact'} total: ${tokens.estimatedTotal}. Mean: ${tokens.mean.toFixed(2)}; median: ${tokens.p50}; p95: ${tokens.p95}.\n\n| Tokens | Rows in sample |\n|---|---|\n`;
    for (const b of tokens.histogram)
        out += `| ${b.label} | ${b.count} |\n`;
} out += `\n## Language mix\n\n${card.languageSampleRows} sampled rows; heuristic labels.\n\n`; for (const l of card.languageMix)
    out += `- ${l.code}: ${(l.fraction * 100).toFixed(1)}% (${l.count})\n`; out += '\n## Pipeline provenance\n\n| Step | Rows in | Rows out | Changed cells | Notes |\n|---|---|---|---|---|\n'; for (const m of card.metrics)
    out += `| ${md(m.opName)} | ${m.rowsIn} | ${m.rowsOut} | ${m.cellsChanged} | ${md(Object.entries(m.notes).map(([k, v]) => k + ': ' + v).join('; '))} |\n`; out += '\n## Interpretation\n\n' + card.notes.map(s => '- ' + s).join('\n') + '\n'; return out; }
function datasetDiff(before, after) { const originals = new Map(before.records.map(r => [r.id, r])), afterIDs = new Set(after.records.map(r => r.id)), shared = after.columns.map((name, i) => ({ name, after: i, before: before.columns.indexOf(name) })).filter(c => c.before >= 0), rows = Object.create(null); for (const r of after.records) {
    const old = originals.get(r.id);
    if (!old) {
        rows[r.id] = { kind: 'added', columns: after.columns };
        continue;
    }
    const changed = shared.filter(c => !(0, model_1.same)(old.values[c.before], r.values[c.after])).map(c => c.name);
    rows[r.id] = { kind: changed.length ? 'modified' : 'unchanged', columns: changed };
} return { rows, droppedIDs: before.records.filter(r => !afterIDs.has(r.id)).map(r => r.id), addedColumns: after.columns.filter(c => !before.columns.includes(c)), removedColumns: before.columns.filter(c => !after.columns.includes(c)) }; }
