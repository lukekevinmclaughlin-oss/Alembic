"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.parseExpression = parseExpression;
exports.evaluateExpression = evaluateExpression;
const model_1 = require("./model.cjs");
const quality_1 = require("./quality.cjs");
const precedence = { or: 1, '||': 1, and: 2, '&&': 2, '==': 3, '!=': 3, '<': 4, '>': 4, '<=': 4, '>=': 4, '+': 5, '-': 5, '*': 6, '/': 6, '%': 6 };
const arities = { len: [1, 1], lower: [1, 1], upper: [1, 1], trim: [1, 1], contains: [2, 2], starts_with: [2, 2], ends_with: [2, 2], replace: [3, 3], substr: [2, 3], concat: [1, 50], coalesce: [1, 50], col: [1, 1], tokens: [1, 1], words: [1, 1], lang: [1, 1], is_null: [1, 1], abs: [1, 1], round: [1, 2], min: [1, 50], max: [1, 50], if: [3, 3] };
function lex(input) { if (input.length > 10000)
    throw Error('Expression exceeds 10,000 characters.'); const out = []; let pos = 0; while (pos < input.length) {
    if (/\s/u.test(input[pos])) {
        pos++;
        continue;
    }
    const start = pos, c = input[pos];
    if (c === '"' || c === "'") {
        pos++;
        let s = '', closed = false;
        while (pos < input.length) {
            const ch = input[pos++];
            if (ch === c) {
                closed = true;
                break;
            }
            if (ch === '\\') {
                if (pos === input.length)
                    throw Error('Unclosed expression escape.');
                const next = input[pos++];
                s += next === 'n' ? '\n' : next === 't' ? '\t' : next === 'r' ? '\r' : next;
            }
            else
                s += ch;
        }
        if (!closed)
            throw Error('Unclosed expression string.');
        out.push({ type: 'string', text: s, pos: start });
        continue;
    }
    const number = input.slice(pos).match(/^(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/);
    if (number) {
        pos += number[0].length;
        out.push({ type: 'number', text: number[0], pos: start });
        continue;
    }
    const id = input.slice(pos).match(/^[\p{L}_][\p{L}\p{M}\p{N}_]*/u);
    if (id) {
        pos += id[0].length;
        out.push({ type: ['and', 'or', 'not'].includes(id[0]) ? 'op' : 'id', text: id[0], pos: start });
        continue;
    }
    const pair = input.slice(pos, pos + 2);
    if (['==', '!=', '<=', '>=', '&&', '||'].includes(pair)) {
        pos += 2;
        out.push({ type: 'op', text: pair, pos: start });
        continue;
    }
    if ('()+-*/%,!<>'.includes(c)) {
        pos++;
        out.push({ type: 'op', text: c, pos: start });
        continue;
    }
    throw Error(`Unexpected expression character at ${pos + 1}.`);
} out.push({ type: 'end', text: '', pos }); if (out.length > 2000)
    throw Error('Expression exceeds 2,000 tokens.'); return out; }
function parseExpression(input) {
    const tokens = lex(input);
    let pos = 0, nodes = 0;
    const peek = () => tokens[pos], take = () => tokens[pos++];
    function need(t) { if (take().text !== t)
        throw Error(`Expected ${t} at character ${peek()?.pos ?? input.length}.`); }
    function parse(min = 1, depth = 0) {
        if (depth > 64 || ++nodes > 2000)
            throw Error('Expression complexity limit exceeded.');
        let left;
        const t = take();
        if (t.type === 'number')
            left = { kind: 'value', value: /^\d+$/.test(t.text) ? (0, model_1.integer)(t.text) : (0, model_1.double)(Number(t.text)) };
        else if (t.type === 'string')
            left = { kind: 'value', value: (0, model_1.string)(t.text) };
        else if (t.text === 'not' || t.text === '!' || t.text === '-') {
            if (t.text === '-' && peek().type === 'number' && /^\d+$/.test(peek().text)) {
                left = { kind: 'value', value: (0, model_1.integer)('-' + take().text) };
            }
            else
                left = { kind: 'unary', op: t.text, right: parse(t.text === 'not' ? 3 : 7, depth + 1) };
        }
        else if (t.text === '(') {
            left = parse(1, depth + 1);
            need(')');
        }
        else if (t.type === 'id') {
            if (['true', 'false', 'null'].includes(t.text))
                left = { kind: 'value', value: t.text === 'null' ? model_1.NIL : (0, model_1.boolean)(t.text === 'true') };
            else if (peek().text === '(') {
                take();
                const args = [];
                if (peek().text !== ')') {
                    while (true) {
                        args.push(parse(1, depth + 1));
                        if (peek().text !== ',')
                            break;
                        take();
                    }
                }
                need(')');
                const arity = arities[t.text];
                if (!arity)
                    throw Error(`Unknown function: ${t.text}`);
                if (args.length < arity[0] || args.length > arity[1])
                    throw Error(`Invalid argument count for ${t.text}.`);
                left = { kind: 'call', name: t.text, args };
            }
            else
                left = { kind: 'column', name: t.text };
        }
        else
            throw Error(`Expected expression at character ${t.pos + 1}.`);
        while ((precedence[peek().text] ?? 0) >= min) {
            const op = take().text, right = parse(precedence[op] + 1, depth + 1);
            left = { kind: 'binary', op, left, right };
        }
        return left;
    }
    const expr = parse();
    if (peek().type !== 'end')
        throw Error(`Unexpected expression input at character ${peek().pos + 1}.`);
    return expr;
}
function compare(a, b) { if (a.t === 'null' || b.t === 'null')
    return a.t === b.t ? 0 : a.t === 'null' ? -1 : 1; const numericType = (v) => ['int', 'double', 'bool'].includes(v.t); if (numericType(a) && numericType(b)) {
    const val = (v) => v.t === 'int' ? BigInt(v.v) : v.t === 'bool' ? (v.v ? 1 : 0) : v.v;
    const x = val(a), y = val(b);
    return x < y ? -1 : x > y ? 1 : 0;
} const x = (0, model_1.display)(a), y = (0, model_1.display)(b); return x < y ? -1 : x > y ? 1 : 0; }
function evaluateExpression(expr, ds, row, tokenizer) {
    let operations = 0;
    function run(e, depth = 0) {
        if (++operations > 5000 || depth > 128)
            throw Error('Expression evaluation limit exceeded.');
        if (e.kind === 'value')
            return e.value;
        if (e.kind === 'column')
            return row.values[(0, model_1.requireColumn)(ds, e.name)];
        if (e.kind === 'unary') {
            const v = run(e.right, depth + 1);
            return e.op === '-' ? (v.t === 'int' ? (0, model_1.integer)(-BigInt(v.v)) : (0, model_1.double)(-(0, model_1.numeric)(v))) : (0, model_1.boolean)(!(0, model_1.truthy)(v));
        }
        if (e.kind === 'binary') {
            const a = run(e.left, depth + 1);
            if (e.op === 'and' || e.op === '&&')
                return (0, model_1.boolean)((0, model_1.truthy)(a) && (0, model_1.truthy)(run(e.right, depth + 1)));
            if (e.op === 'or' || e.op === '||')
                return (0, model_1.boolean)((0, model_1.truthy)(a) || (0, model_1.truthy)(run(e.right, depth + 1)));
            const b = run(e.right, depth + 1);
            if (['==', '!=', '<', '>', '<=', '>='].includes(e.op)) {
                const c = compare(a, b);
                return (0, model_1.boolean)(e.op === '==' ? c === 0 : e.op === '!=' ? c !== 0 : e.op === '<' ? c < 0 : e.op === '>' ? c > 0 : e.op === '<=' ? c <= 0 : c >= 0);
            }
            if (e.op === '+' && (a.t === 'string' || b.t === 'string'))
                return (0, model_1.string)((0, model_1.display)(a) + (0, model_1.display)(b));
            if (a.t === 'null' || b.t === 'null')
                return model_1.NIL;
            if (a.t === 'int' && b.t === 'int' && e.op !== '/') {
                const x = BigInt(a.v), y = BigInt(b.v);
                if (e.op === '%' && y === 0n)
                    return model_1.NIL;
                return (0, model_1.integer)(e.op === '+' ? x + y : e.op === '-' ? x - y : e.op === '*' ? x * y : x % y);
            }
            const x = (0, model_1.numeric)(a), y = (0, model_1.numeric)(b);
            if ((e.op === '/' || e.op === '%') && y === 0)
                return model_1.NIL;
            return (0, model_1.double)(e.op === '+' ? x + y : e.op === '-' ? x - y : e.op === '*' ? x * y : e.op === '/' ? x / y : x % y);
        }
        if (e.name === 'if')
            return run((0, model_1.truthy)(run(e.args[0], depth + 1)) ? e.args[1] : e.args[2], depth + 1);
        if (e.name === 'coalesce') {
            for (const x of e.args) {
                const v = run(x, depth + 1);
                if (v.t !== 'null')
                    return v;
            }
            return model_1.NIL;
        }
        const args = e.args.map(a => run(a, depth + 1)), s = (i = 0) => (0, model_1.display)(args[i]);
        const index = (i) => { const n = args[i].t === 'int' ? Number(args[i].v) : (0, model_1.numeric)(args[i]); if (!Number.isSafeInteger(n))
            throw Error('Expected a safe integer index.'); return n; };
        switch (e.name) {
            case 'len': return (0, model_1.integer)((0, model_1.graphemes)(s()).length);
            case 'lower': return (0, model_1.string)(s().toLowerCase());
            case 'upper': return (0, model_1.string)(s().toUpperCase());
            case 'trim': return (0, model_1.string)(s().trim());
            case 'contains': return (0, model_1.boolean)(s().includes(s(1)));
            case 'starts_with': return (0, model_1.boolean)(s().startsWith(s(1)));
            case 'ends_with': return (0, model_1.boolean)(s().endsWith(s(1)));
            case 'replace': {
                const source = s(), find = s(1), replacement = s(2);
                if (!find)
                    throw Error('Replacement search text cannot be empty.');
                let count = 0, position = 0;
                while ((position = source.indexOf(find, position)) !== -1) {
                    count++;
                    position += find.length;
                    if (source.length + count * (replacement.length - find.length) > model_1.limits.cellChars)
                        throw Error('Replacement output exceeds the cell limit.');
                }
                return (0, model_1.string)(source.split(find).join(replacement));
            }
            case 'substr': {
                const start = index(1), length = args.length === 3 ? index(2) : undefined;
                if (start < 0 || length !== undefined && length < 0)
                    throw Error('Substring indexes must be nonnegative.');
                return (0, model_1.string)((0, model_1.graphemes)(s()).slice(start, length === undefined ? undefined : start + length).join(''));
            }
            case 'concat': return (0, model_1.string)(args.map(model_1.display).join(''));
            case 'col': return row.values[(0, model_1.requireColumn)(ds, s())];
            case 'tokens': return (0, model_1.integer)(tokenizer.count(s()));
            case 'words': return (0, model_1.integer)(s().trim() ? s().trim().split(/\s+/u).length : 0);
            case 'lang': return (0, model_1.string)((0, quality_1.language)(s()).code);
            case 'is_null': return (0, model_1.boolean)(args[0].t === 'null');
            case 'abs': return args[0].t === 'int' ? (0, model_1.integer)(BigInt(args[0].v) < 0n ? -BigInt(args[0].v) : BigInt(args[0].v)) : (0, model_1.double)(Math.abs((0, model_1.numeric)(args[0])));
            case 'round': {
                const digits = args.length === 2 ? index(1) : 0;
                if (digits < -15 || digits > 15)
                    throw Error('Round precision must be between -15 and 15.');
                if (args[0].t === 'int' && digits >= 0)
                    return args[0];
                const factor = 10 ** digits;
                return (0, model_1.double)(Math.round((0, model_1.numeric)(args[0]) * factor) / factor);
            }
            case 'min':
            case 'max': return args.reduce((a, b) => ((compare(a, b) < 0) === (e.name === 'min')) ? a : b);
            default: throw Error('Unknown expression function.');
        }
    }
    return run(expr);
}
