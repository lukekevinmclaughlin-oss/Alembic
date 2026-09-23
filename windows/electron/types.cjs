"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.isNullString = exports.nullSentinels = void 0;
exports.parseInteger = parseInteger;
exports.parseDouble = parseDouble;
exports.parseBool = parseBool;
exports.parseDate = parseDate;
exports.inferType = inferType;
exports.coerce = coerce;
const model_1 = require("./model.cjs");
exports.nullSentinels = new Set(['', 'na', 'n/a', 'nan', 'null', 'none', 'nil', '-', '--', '?', 'missing', '#n/a', '#null!', '(null)', 'undefined']);
const isNullString = (s) => exports.nullSentinels.has(s.trim().toLowerCase());
exports.isNullString = isNullString;
function parseInteger(s) { s = s.trim(); if (/^[+-]?\d{1,3}(,\d{3})+$/.test(s))
    s = s.replace(/,/g, ''); if (!/^[+-]?\d{1,20}$/.test(s))
    return null; const n = BigInt(s); return n >= model_1.INT_MIN && n <= model_1.INT_MAX ? n : null; }
function parseDouble(s) {
    s = s.trim();
    let pct = false;
    if (s.endsWith('%')) {
        pct = true;
        s = s.slice(0, -1).trim();
    }
    const signed = '[+-]?';
    if (s.includes(',') && s.includes('.')) {
        if (s.lastIndexOf(',') > s.lastIndexOf('.')) {
            if (!new RegExp('^' + signed + '(?:\\d{1,3}(?:\\.\\d{3})+|\\d+),\\d+(?:[eE][+-]?\\d+)?$').test(s))
                return null;
            s = s.replace(/\./g, '').replace(',', '.');
        }
        else {
            if (!new RegExp('^' + signed + '\\d{1,3}(?:,\\d{3})+\\.\\d+(?:[eE][+-]?\\d+)?$').test(s))
                return null;
            s = s.replace(/,/g, '');
        }
    }
    else if (s.includes(',')) {
        if (/^[+-]?\d{1,3}(,\d{3})+$/.test(s))
            s = s.replace(/,/g, '');
        else if (/^[+-]?\d+,\d+$/.test(s) && s.split(',')[1].length !== 3)
            s = s.replace(',', '.');
        else
            return null;
    }
    if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(s))
        return null;
    const n = Number(s) / (pct ? 100 : 1);
    return Number.isFinite(n) ? n : null;
}
function parseBool(s) { s = s.trim().toLowerCase(); if (['true', 'yes', 'y', 't', '1️⃣'].includes(s))
    return true; if (['false', 'no', 'n', 'f'].includes(s))
    return false; return null; }
function ymd(y, m, d, hour = 0, minute = 0, second = 0, ms = 0) { if (y < 1000 || y > 9999 || m < 1 || m > 12 || d < 1 || d > 31 || hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59 || ms < 0 || ms > 999)
    return null; const date = new Date(Date.UTC(y, m - 1, d, hour, minute, second, ms)); return date.getUTCFullYear() === y && date.getUTCMonth() === m - 1 && date.getUTCDate() === d ? date.toISOString() : null; }
const months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
function parseDate(s) {
    s = s.trim();
    if (s.length < 6 || s.length > 40)
        return null;
    let m = s.match(/^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?(Z|[+-]\d{2}:\d{2})?$/i);
    if (m) {
        const base = ymd(+m[1], +m[2], +m[3], +m[4], +m[5], +m[6], +(m[7] ?? '').padEnd(3, '0'));
        if (!base)
            return null;
        if (!m[8] || m[8].toUpperCase() === 'Z')
            return base;
        const h = +m[8].slice(1, 3), min = +m[8].slice(4);
        if (h > 23 || min > 59)
            return null;
        const date = new Date(new Date(base).getTime() - (m[8][0] === '+' ? 1 : -1) * (h * 60 + min) * 60000);
        return date.getUTCFullYear() >= 1000 && date.getUTCFullYear() <= 9999 ? date.toISOString() : null;
    }
    if (/^\d{10}$/.test(s) && +s > 631152000)
        return new Date(+s * 1000).toISOString();
    if (/^\d{13}$/.test(s))
        return new Date(+s).toISOString();
    if ((m = s.match(/^(\d{4})(\d{2})(\d{2})$/)))
        return +m[1] >= 1900 && +m[1] <= 2100 ? ymd(+m[1], +m[2], +m[3]) : null;
    if ((m = s.match(/^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$/)))
        return ymd(+m[1], +m[2], +m[3]);
    if ((m = s.match(/^(\d{1,2})([./-])(\d{1,2})\2(\d{2}|\d{4})$/))) {
        let y = +m[4];
        if (y < 100)
            y += y < 50 ? 2000 : 1900;
        if (y < 1900 || y > 2100)
            return null;
        const a = +m[1], b = +m[3], dayFirst = a > 12 || (b <= 12 && m[2] === '.');
        return ymd(y, dayFirst ? b : a, dayFirst ? a : b);
    }
    const cleaned = s.replace(/(\d)(st|nd|rd|th)\b/gi, '$1').replace(/,/g, '');
    if ((m = cleaned.match(/^([A-Za-z]+) (\d{1,2}) (\d{4})$/)))
        return months.includes(m[1].toLowerCase().slice(0, 3)) ? ymd(+m[3], months.indexOf(m[1].toLowerCase().slice(0, 3)) + 1, +m[2]) : null;
    if ((m = cleaned.match(/^(\d{1,2}) ([A-Za-z]+) (\d{4})$/)))
        return months.includes(m[2].toLowerCase().slice(0, 3)) ? ymd(+m[3], months.indexOf(m[2].toLowerCase().slice(0, 3)) + 1, +m[1]) : null;
    return null;
}
function inferType(values) { const xs = values.filter(v => v.t === 'string' && !(0, exports.isNullString)(v.v)).slice(0, 500).map(model_1.display); if (!xs.length)
    return 'string'; const counts = { bool: 0, int: 0, double: 0, date: 0 }; for (const s of xs) {
    if (parseBool(s) !== null)
        counts.bool++;
    if (parseInteger(s) !== null)
        counts.int++;
    if (parseDouble(s) !== null)
        counts.double++;
    else if (parseDate(s) !== null)
        counts.date++;
} for (const t of ['bool', 'int', 'double', 'date'])
    if (counts[t] / xs.length >= .95)
        return t; return 'string'; }
function coerce(v, type) {
    if (v.t === 'null')
        return model_1.NIL;
    if (type === 'string')
        return (0, model_1.string)((0, model_1.display)(v));
    if (v.t === type)
        return v;
    const s = (0, model_1.display)(v);
    if ((0, exports.isNullString)(s))
        return model_1.NIL;
    if (type === 'int') {
        if (v.t === 'bool')
            return (0, model_1.integer)(v.v ? 1 : 0);
        if (v.t === 'double')
            return Number.isSafeInteger(Math.trunc(v.v)) ? (0, model_1.integer)(Math.trunc(v.v)) : model_1.NIL;
        const n = parseInteger(s);
        return n === null ? model_1.NIL : (0, model_1.integer)(n);
    }
    if (type === 'double') {
        if (v.t === 'bool')
            return (0, model_1.double)(v.v ? 1 : 0);
        const n = parseDouble(s);
        return n === null ? model_1.NIL : (0, model_1.double)(n);
    }
    if (type === 'bool') {
        if (v.t === 'int')
            return (0, model_1.boolean)(BigInt(v.v) !== 0n);
        if (v.t === 'double')
            return (0, model_1.boolean)(v.v !== 0);
        const b = parseBool(s);
        return b === null ? model_1.NIL : (0, model_1.boolean)(b);
    }
    const date = parseDate(s);
    return date === null ? model_1.NIL : { t: 'date', v: date };
}
