"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.BPETokenizer = void 0;
const model_1 = require("./model.cjs");
class Heap {
    values = [];
    before(a, b) { return a.rank < b.rank || (a.rank === b.rank && a.left < b.left); }
    push(v) { const a = this.values; a.push(v); let i = a.length - 1; while (i > 0) {
        const p = (i - 1) >> 1;
        if (!this.before(a[i], a[p]))
            break;
        [a[i], a[p]] = [a[p], a[i]];
        i = p;
    } }
    pop() { const a = this.values, out = a[0], tail = a.pop(); if (!a.length)
        return out; a[0] = tail; let i = 0; while (true) {
        let n = i, l = 2 * i + 1, r = l + 1;
        if (l < a.length && this.before(a[l], a[n]))
            n = l;
        if (r < a.length && this.before(a[r], a[n]))
            n = r;
        if (n === i)
            break;
        [a[i], a[n]] = [a[n], a[i]];
        i = n;
    } return out; }
}
const encoder = new TextEncoder(), decoder = new TextDecoder('utf-8', { ignoreBOM: true });
const pattern = /'(?:[sSdDmMtT]|[lL][lL]|[vV][eE]|[rR][eE])|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}| ?[^\p{White_Space}\p{L}\p{N}]+[\r\n]*|\p{White_Space}*[\r\n]|\p{White_Space}+(?![^\p{White_Space}])|\p{White_Space}+/gu;
function byteString(bytes) { let out = ''; for (let i = 0; i < bytes.length; i += 8192)
    out += String.fromCharCode(...bytes.subarray(i, i + 8192)); return out; }
class BPETokenizer {
    name = 'cl100k_base (ordinary text)';
    ranks = new Map();
    reverse = new Map();
    longest = 0;
    cache = new Map();
    constructor(vocabulary) {
        const lines = vocabulary.trim().split(/\r?\n/);
        if (lines.length !== 100256)
            throw Error('Tokenizer vocabulary is incomplete.');
        for (const line of lines) {
            const pair = line.split(' ');
            if (pair.length !== 2 || !/^\d+$/.test(pair[1]))
                throw Error('Invalid tokenizer vocabulary.');
            const raw = atob(pair[0]), rank = Number(pair[1]);
            if (rank >= 100256 || this.ranks.has(raw) || this.reverse.has(rank))
                throw Error('Duplicate tokenizer rank.');
            this.ranks.set(raw, rank);
            this.reverse.set(rank, Uint8Array.from(raw, x => x.charCodeAt(0)));
            this.longest = Math.max(this.longest, raw.length);
        }
        for (let b = 0; b < 256; b++)
            if (!this.ranks.has(String.fromCharCode(b)))
                throw Error('Missing byte token.');
    }
    encode(text) {
        if (text.length > model_1.limits.cellChars)
            throw Error('Token input exceeds cell limit.');
        const cached = this.cache.get(text);
        if (cached)
            return [...cached];
        const result = [];
        let consumed = 0;
        pattern.lastIndex = 0;
        for (const match of text.matchAll(pattern)) {
            if (match.index !== consumed)
                throw Error('Tokenizer pre-split gap.');
            consumed += match[0].length;
            const key = byteString(encoder.encode(match[0]));
            const rank = this.ranks.get(key);
            if (rank !== undefined)
                result.push(rank);
            else
                for (const id of this.merge(key))
                    result.push(id);
        }
        if (consumed !== text.length)
            throw Error('Tokenizer did not consume all input.');
        if (text.length <= 5000) {
            if (this.cache.size >= 1000)
                this.cache.delete(this.cache.keys().next().value);
            this.cache.set(text, [...result]);
        }
        return result;
    }
    count(text) { return this.encode(text).length; }
    decode(tokens) { let total = 0; const parts = tokens.map(id => { const b = this.reverse.get(id); if (!b)
        throw Error('Unknown token id.'); total += b.length; if (total > model_1.limits.cellChars * 4)
        throw Error('Decoded token limit.'); return b; }); const bytes = new Uint8Array(total); let pos = 0; for (const b of parts) {
        bytes.set(b, pos);
        pos += b.length;
    } return decoder.decode(bytes); }
    merge(bytes) {
        const n = bytes.length, next = new Int32Array(n), prev = new Int32Array(n), end = new Int32Array(n), version = new Int32Array(n), alive = new Uint8Array(n).fill(1), heap = new Heap();
        for (let i = 0; i < n; i++) {
            next[i] = i + 1 < n ? i + 1 : -1;
            prev[i] = i - 1;
            end[i] = i + 1;
        }
        const offer = (left) => { if (left < 0 || !alive[left])
            return; const right = next[left]; if (right < 0 || end[right] - left > this.longest)
            return; const rank = this.ranks.get(bytes.slice(left, end[right])); if (rank !== undefined)
            heap.push({ rank, left, right, lv: version[left], rv: version[right] }); };
        for (let i = 0; i < n - 1; i++)
            offer(i);
        while (heap.values.length) {
            const c = heap.pop();
            if (!alive[c.left] || !alive[c.right] || version[c.left] !== c.lv || version[c.right] !== c.rv || next[c.left] !== c.right)
                continue;
            end[c.left] = end[c.right];
            next[c.left] = next[c.right];
            if (next[c.right] >= 0)
                prev[next[c.right]] = c.left;
            alive[c.right] = 0;
            version[c.left]++;
            offer(prev[c.left]);
            offer(c.left);
        }
        const out = [];
        for (let i = 0; i >= 0; i = next[i]) {
            const rank = this.ranks.get(bytes.slice(i, end[i]));
            if (rank === undefined)
                throw Error('Invalid BPE merge.');
            out.push(rank);
        }
        return out;
    }
}
exports.BPETokenizer = BPETokenizer;
