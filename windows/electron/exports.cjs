"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.schemas = void 0;
exports.autoMap = autoMap;
exports.shapeDataset = shapeDataset;
exports.quarantinedJSONL = quarantinedJSONL;
const model_1 = require("./model.cjs");
const lossless_json_1 = require("./lossless-json.cjs");
exports.schemas = { alpaca: { name: 'Instruction (Alpaca)', required: ['instruction', 'output'], optional: ['input'] }, openaiMessages: { name: 'Chat (OpenAI messages)', required: ['user', 'assistant'], optional: ['system'] }, anthropicTurns: { name: 'Chat (Anthropic turns)', required: ['user', 'assistant'], optional: ['system'] }, chatml: { name: 'ChatML (rendered)', required: ['user', 'assistant'], optional: ['system'] }, dpo: { name: 'Preference pairs (DPO)', required: ['prompt', 'chosen', 'rejected'], optional: [] }, completion: { name: 'Prompt → completion', required: ['prompt', 'completion'], optional: [] }, corpus: { name: 'Raw corpus', required: ['text'], optional: [] }, ragChunks: { name: 'RAG chunks', required: ['text'], optional: ['source', 'heading'] } };
const synonyms = { instruction: ['instruction', 'question', 'prompt', 'query', 'task', 'q'], input: ['input', 'context', 'passage'], output: ['output', 'answer', 'response', 'completion', 'a'], system: ['system', 'system_prompt'], user: ['user', 'question', 'prompt', 'instruction', 'human', 'q', 'input'], assistant: ['assistant', 'answer', 'response', 'output', 'completion', 'a', 'bot'], prompt: ['prompt', 'question', 'instruction', 'query', 'input'], chosen: ['chosen', 'preferred', 'good', 'winner'], rejected: ['rejected', 'dispreferred', 'bad', 'loser'], completion: ['completion', 'output', 'answer', 'response', 'text'], text: ['text', 'content', 'body', 'document', 'passage'], source: ['source', 'file', 'url', 'origin', 'doc'], heading: ['heading', 'title', 'section', 'heading_path'] };
function autoMap(schema, columns) { const map = Object.create(null); for (const field of [...exports.schemas[schema].required, ...exports.schemas[schema].optional])
    for (const alias of synonyms[field]) {
        const hits = columns.filter(c => c.toLowerCase() === alias);
        if (hits.length === 1) {
            map[field] = hits[0];
            break;
        }
    } return map; }
function shapeDataset(ds, schema, mapping) {
    if (!Object.hasOwn(exports.schemas, schema))
        throw Error('Unknown export schema.');
    const spec = exports.schemas[schema], fields = [...spec.required, ...spec.optional], indexes = new Map();
    for (const field of fields)
        if (mapping[field])
            indexes.set(field, (0, model_1.requireColumn)(ds, mapping[field]));
    const lines = [], quarantined = [];
    for (const row of ds.records) {
        const get = (field) => { const idx = indexes.get(field); return idx === undefined ? '' : (0, model_1.display)(row.values[idx]); }, missing = spec.required.filter(f => !get(f).trim());
        if (missing.length) {
            quarantined.push({ record: row, reason: 'Missing required fields: ' + missing.join(', ') });
            continue;
        }
        let obj = Object.create(null);
        switch (schema) {
            case 'alpaca':
                obj = { instruction: get('instruction'), input: get('input'), output: get('output') };
                break;
            case 'openaiMessages':
                obj = { messages: [...(get('system').trim() ? [{ role: 'system', content: get('system') }] : []), { role: 'user', content: get('user') }, { role: 'assistant', content: get('assistant') }] };
                break;
            case 'anthropicTurns':
                obj = { ...(get('system').trim() ? { system: get('system') } : {}), messages: [{ role: 'user', content: get('user') }, { role: 'assistant', content: get('assistant') }] };
                break;
            case 'chatml':
                if (fields.some(f => /<\|im_(?:start|end)\|>/.test(get(f)))) {
                    quarantined.push({ record: row, reason: 'ChatML control delimiter occurs in field content.' });
                    continue;
                }
                obj = { text: (get('system') ? `<|im_start|>system\n${get('system')}<|im_end|>\n` : '') + `<|im_start|>user\n${get('user')}<|im_end|>\n<|im_start|>assistant\n${get('assistant')}<|im_end|>` };
                break;
            case 'dpo':
                if (get('chosen').trim() === get('rejected').trim()) {
                    quarantined.push({ record: row, reason: 'Chosen and rejected responses are identical.' });
                    continue;
                }
                obj = { prompt: get('prompt'), chosen: get('chosen'), rejected: get('rejected') };
                break;
            case 'completion':
                obj = { prompt: get('prompt'), completion: get('completion') };
                break;
            case 'corpus':
                obj = { text: get('text') };
                break;
            case 'ragChunks': {
                const metadata = Object.create(null), extra = Object.create(null), mapped = new Set(indexes.values());
                if (indexes.has('source'))
                    metadata.source = get('source');
                if (indexes.has('heading'))
                    metadata.heading = get('heading');
                ds.columns.forEach((c, i) => { if (!mapped.has(i))
                    extra[c] = (0, lossless_json_1.cellJSON)(row.values[i]); });
                if (Object.keys(extra).length)
                    metadata.fields = extra;
                obj = { id: row.id, text: get('text'), metadata };
                break;
            }
        }
        lines.push((0, lossless_json_1.stringifyLossless)(obj));
    }
    return { jsonl: lines.join('\n') + (lines.length ? '\n' : ''), validCount: lines.length, quarantined, columns: ds.columns };
}
function quarantinedJSONL(columns, rows, metadata = null) { return rows.map(({ record, reason }) => { const data = Object.create(null); columns.forEach((c, i) => data[c] = (0, lossless_json_1.cellJSON)(record.values[i])); return (0, lossless_json_1.stringifyLossless)({ ...metadata, recordId: record.id, reason, data }); }).join('\n') + (rows.length ? '\n' : ''); }
