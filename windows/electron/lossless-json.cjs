"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.JSONNumber = void 0;
exports.parseLossless = parseLossless;
exports.stringifyLossless = stringifyLossless;
exports.jsonCell = jsonCell;
exports.cellJSON = cellJSON;
const model_1 = require("./model.cjs");
class JSONNumber {
    raw;
    constructor(raw) {
        this.raw = raw;
        if (!model_1.jsonNumberPattern.test(raw) || raw.length > 200)
            throw Error('Invalid or oversized JSON number.');
    }
}
exports.JSONNumber = JSONNumber;
function parseLossless(text) {
    if (new TextEncoder().encode(text).length > model_1.limits.inputBytes)
        throw Error('JSON exceeds 32 MiB.');
    let pos = 0, nodes = 0;
    function error(message) { throw Error(`${message} at character ${pos + 1}.`); }
    function whitespace() { while (/[\x20\t\r\n]/.test(text[pos] ?? '\0'))
        pos++; }
    function str() { const start = pos++; let closed = false; while (pos < text.length) {
        const c = text[pos++];
        if (c === '\\') {
            pos++;
            continue;
        }
        if (c === '"') {
            closed = true;
            break;
        }
        if (c.charCodeAt(0) < 32)
            error('Unescaped control character');
    } if (!closed)
        error('Unclosed JSON string'); const s = JSON.parse(text.slice(start, pos)); if (s.length > model_1.limits.cellChars)
        error('JSON string exceeds cell limit'); return s; }
    function value(depth) {
        if (++nodes > 1_000_000 || depth > 64)
            error('JSON complexity limit exceeded');
        whitespace();
        const c = text[pos];
        if (c === '"')
            return str();
        if (c === '[' || c === '{') {
            pos++;
            whitespace();
            const array = c === '[', end = array ? ']' : '}', result = array ? [] : Object.create(null);
            if (text[pos] === end) {
                pos++;
                return result;
            }
            while (true) {
                whitespace();
                if (array)
                    result.push(value(depth + 1));
                else {
                    if (text[pos] !== '"')
                        error('Expected object key');
                    const key = str();
                    whitespace();
                    if (text[pos++] !== ':')
                        error('Expected colon');
                    if (Object.hasOwn(result, key))
                        error(`Duplicate JSON key ${JSON.stringify(key)}`);
                    result[key] = value(depth + 1);
                }
                whitespace();
                if (text[pos] === end) {
                    pos++;
                    break;
                }
                if (text[pos++] !== ',')
                    error('Expected comma');
            }
            return result;
        }
        for (const [literal, parsed] of [['null', null], ['true', true], ['false', false]])
            if (text.startsWith(literal, pos)) {
                pos += literal.length;
                return parsed;
            }
        const match = text.slice(pos).match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/);
        if (!match)
            error('Expected JSON value');
        pos += match[0].length;
        return new JSONNumber(match[0]);
    }
    const out = value(0);
    whitespace();
    if (pos !== text.length)
        error('Trailing JSON data');
    return out;
}
function stringifyLossless(value, depth = 0) { if (depth > 64)
    throw Error('JSON depth limit.'); if (value instanceof JSONNumber)
    return value.raw; if (value === null || typeof value !== 'object') {
    if (typeof value === 'number' && !Number.isFinite(value))
        throw Error('Non-finite JSON value.');
    return JSON.stringify(value);
} if (Array.isArray(value))
    return '[' + value.map(v => stringifyLossless(v, depth + 1)).join(',') + ']'; return '{' + Object.keys(value).map(k => JSON.stringify(k) + ':' + stringifyLossless(value[k], depth + 1)).join(',') + '}'; }
function jsonCell(v) { if (v === null)
    return model_1.NIL; if (typeof v === 'boolean')
    return (0, model_1.boolean)(v); if (typeof v === 'string')
    return (0, model_1.string)(v); if (v instanceof JSONNumber) {
    if (/^-?\d+$/.test(v.raw) && v.raw !== '-0') {
        const n = BigInt(v.raw);
        if (n >= model_1.INT_MIN && n <= model_1.INT_MAX)
            return (0, model_1.integer)(n);
    }
    return { t: 'decimal', v: v.raw };
} if (typeof v === 'number')
    throw Error('JSON numbers must be parsed losslessly.'); return (0, model_1.string)(stringifyLossless(v)); }
function cellJSON(v) { if (v.t === 'null')
    return null; if (v.t === 'int' || v.t === 'decimal')
    return new JSONNumber(v.v); if (v.t === 'blob')
    return { $binary: v.v, encoding: 'base64' }; return v.v; }
