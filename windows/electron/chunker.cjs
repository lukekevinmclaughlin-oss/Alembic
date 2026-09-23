"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.defaultChunk = void 0;
exports.splitSentences = splitSentences;
exports.chunkText = chunkText;
const model_1 = require("./model.cjs");
const importers_1 = require("./importers.cjs");
exports.defaultChunk = { targetTokens: 512, overlapTokens: 64, respectMarkdown: true, minChunkTokens: 24, includeHeadingContext: true };
const abbreviations = new Set(['mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'st', 'vs', 'etc', 'eg', 'ie', 'inc', 'ltd', 'co', 'corp', 'dept', 'est', 'fig', 'no', 'vol', 'approx', 'appt', 'apt', 'ave', 'blvd', 'cf', 'al', 'ed', 'eds', 'min', 'max']);
function splitSentences(text) {
    const out = [];
    let start = 0;
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (c === '\n') {
            const s = text.slice(start, i).trim();
            if (s)
                out.push(s);
            start = i + 1;
            continue;
        }
        if (!'.!?。！？'.includes(c))
            continue;
        const next = text[i + 1] ?? '';
        if (c === '.') {
            if (/\d/.test(text[i - 1] ?? '') && /\d/.test(next))
                continue;
            const previous = text.slice(start, i).match(/([\p{L}.]+)$/u)?.[1] ?? '';
            const last = previous.split('.').filter(Boolean).at(-1) ?? '';
            if (abbreviations.has(last.toLowerCase()) || /^\p{Lu}$/u.test(last))
                continue;
            const look = text.slice(i + 1).match(/^\s*(.)/u)?.[1] ?? '';
            if (/\p{Ll}/u.test(look))
                continue;
        }
        if (!next || /[\s"”)]/u.test(next) || '。！？'.includes(c)) {
            while (/["”)]/u.test(text[i + 1] ?? '\0'))
                i++;
            const s = text.slice(start, i + 1).trim();
            if (s)
                out.push(s);
            start = i + 1;
        }
    }
    const tail = text.slice(start).trim();
    if (tail)
        out.push(tail);
    return out;
}
function splitOversized(text, prefix, budget, tokenizer, signal) { if (tokenizer.count(prefix + text) <= budget)
    return [text]; const chars = (0, model_1.graphemes)(text), out = []; let start = 0; while (start < chars.length) {
    (0, model_1.checkCancelled)(signal);
    let lo = 1, hi = Math.min(chars.length - start, budget * 8), best = 0;
    while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        if (tokenizer.count(prefix + chars.slice(start, start + mid).join('')) <= budget) {
            best = mid;
            lo = mid + 1;
        }
        else
            hi = mid - 1;
    }
    if (!best)
        throw Error('A single grapheme plus heading exceeds the chunk budget. Increase target tokens or disable heading context.');
    let end = start + best;
    if (end < chars.length) {
        for (let j = end - 1; j > start + Math.floor(best / 2); j--)
            if (/^\s+$/u.test(chars[j])) {
                end = j + 1;
                break;
            }
    }
    const part = chars.slice(start, end).join('').trim();
    if (part)
        out.push(part);
    start = end;
    if (out.length > model_1.limits.rows)
        throw Error('Chunk output exceeds 50,000 rows.');
} return out; }
function chunkText(text, config, tokenizer, signal) {
    const c = config;
    if (!Number.isInteger(c.targetTokens) || c.targetTokens < 32 || c.targetTokens > 8192 || !Number.isInteger(c.overlapTokens) || c.overlapTokens < 0 || c.overlapTokens >= c.targetTokens || !Number.isInteger(c.minChunkTokens) || c.minChunkTokens < 0 || c.minChunkTokens > c.targetTokens)
        throw Error('Invalid chunk budget, overlap or minimum.');
    if (!text.trim())
        return [];
    const sections = c.respectMarkdown ? (0, importers_1.markdownSections)(text) : [{ heading: '', level: 0, body: text }], stack = [], result = [];
    for (const section of sections) {
        (0, model_1.checkCancelled)(signal);
        if (section.level) {
            while (stack.length && stack.at(-1).level >= section.level)
                stack.pop();
            stack.push(section);
        }
        const path = stack.map(s => s.heading).join(' > '), prefix = c.includeHeadingContext && path ? '[' + path + ']\n' : '';
        if (tokenizer.count(prefix) >= c.targetTokens)
            throw Error('Heading context fills the chunk budget. Increase target tokens or disable heading context.');
        const units = splitSentences(section.body).flatMap(s => splitOversized(s, prefix, c.targetTokens, tokenizer, signal));
        let start = 0;
        let last;
        const render = (a, b) => prefix + units.slice(a, b).join(' ').trim();
        while (start < units.length) {
            (0, model_1.checkCancelled)(signal);
            let end = start + 1;
            while (end < units.length && tokenizer.count(render(start, end + 1)) <= c.targetTokens)
                end++;
            const body = render(start, end);
            if (tokenizer.count(body) > c.targetTokens)
                throw Error('Chunk exceeds requested budget.');
            if (end === units.length && tokenizer.count(body) < c.minChunkTokens && last && tokenizer.count(render(last.start, end)) <= c.targetTokens) {
                const merged = render(last.start, end);
                result[last.resultIndex] = { text: merged, tokenCount: tokenizer.count(merged), index: last.resultIndex, headingPath: path };
                break;
            }
            const index = result.length;
            result.push({ text: body, tokenCount: tokenizer.count(body), index, headingPath: path });
            if (result.length > model_1.limits.rows)
                throw Error('Chunk output exceeds 50,000 rows.');
            last = { start, end, resultIndex: index };
            if (end === units.length)
                break;
            let next = end;
            for (let j = end - 1; j > start; j--) {
                if (tokenizer.count(units.slice(j, end).join(' ')) <= c.overlapTokens && tokenizer.count(render(j, end + 1)) <= c.targetTokens)
                    next = j;
                else
                    break;
            }
            start = next;
        }
    }
    return result;
}
