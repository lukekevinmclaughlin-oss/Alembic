import profiles from '../content/language-profiles.json';
import { words, graphemes } from './model';
export type QualityRules = { minWords: number; maxWords: number; minMeanWordLength: number; maxMeanWordLength: number; maxSymbolRatio: number; maxDigitRatio: number; maxUppercaseRatio: number; maxDuplicateLineRatio: number; maxTopBigramRatio: number; requireTerminalPunctuation: boolean; minAlphaRatio: number; flagTruncated: boolean };
export const standardQuality: QualityRules = { minWords: 3, maxWords: 100000, minMeanWordLength: 2, maxMeanWordLength: 12, maxSymbolRatio: .3, maxDigitRatio: .5, maxUppercaseRatio: .6, maxDuplicateLineRatio: .4, maxTopBigramRatio: .25, requireTerminalPunctuation: false, minAlphaRatio: .5, flagTruncated: true };
export function quality(text: string, rules: QualityRules = standardQuality): { passed: boolean; score: number; reasons: string[] } {
  const trimmed = text.trim(), reasons: string[] = []; if (!trimmed) return { passed: false, score: 0, reasons: ['empty'] };
  const tokens = trimmed.split(/\s+/u), count = tokens.length;
  if (count < rules.minWords) reasons.push(`too_few_words(${count})`); if (count > rules.maxWords) reasons.push(`too_many_words(${count})`);
  const mean = tokens.reduce((n, s) => n + graphemes(s).length, 0) / count; if (mean < rules.minMeanWordLength) reasons.push(`mean_word_length_low(${mean.toFixed(1)})`); if (mean > rules.maxMeanWordLength) reasons.push(`mean_word_length_high(${mean.toFixed(1)})`);
  let letters = 0, digits = 0, symbols = 0, uppers = 0, nonSpace = 0;
  for (const c of graphemes(trimmed)) { if (/^\s+$/u.test(c)) continue; nonSpace++; if (/\p{L}/u.test(c)) { letters++; if (/\p{Lu}/u.test(c)) uppers++; } else if (/\p{N}/u.test(c)) digits++; else symbols++; }
  if (symbols / nonSpace > rules.maxSymbolRatio) reasons.push(`symbol_ratio(${(symbols / nonSpace).toFixed(2)})`); if (digits / nonSpace > rules.maxDigitRatio) reasons.push(`digit_ratio(${(digits / nonSpace).toFixed(2)})`); if (letters / nonSpace < rules.minAlphaRatio) reasons.push(`alpha_ratio_low(${(letters / nonSpace).toFixed(2)})`); if (letters > 20 && uppers / letters > rules.maxUppercaseRatio) reasons.push(`uppercase_ratio(${(uppers / letters).toFixed(2)})`);
  const lines = trimmed.split('\n').map(s => s.trim()).filter(Boolean); if (lines.length >= 4) { const ratio = 1 - new Set(lines).size / lines.length; if (ratio > rules.maxDuplicateLineRatio) reasons.push(`duplicate_lines(${ratio.toFixed(2)})`); }
  if (count >= 20) { const counts = new Map<string, number>(); for (let i = 1; i < count; i++) { const key = tokens[i - 1].toLowerCase() + ' ' + tokens[i].toLowerCase(); counts.set(key, (counts.get(key) ?? 0) + 1); } let top = 0; for (const n of counts.values()) top = Math.max(top, n); if (top / (count - 1) > rules.maxTopBigramRatio) reasons.push(`repetitive_bigram(${(top / (count - 1)).toFixed(2)})`); }
  if (rules.requireTerminalPunctuation && !/[.!?"”。！？):]$/u.test(trimmed)) reasons.push('no_terminal_punctuation');
  if (rules.flagTruncated && count >= 10 && (new Set(['the','a','an','and','or','but','of','to','in','with','for','is','was','der','die','das','und','le','la','et','de']).has(tokens.at(-1)!.toLowerCase()) || /(?:\.\.\.|…|,|-)$/u.test(trimmed))) reasons.push('truncated_ending');
  return { passed: reasons.length === 0, score: Math.max(0, 1 - reasons.length * .25), reasons };
}
export type Detection = { code: string; confidence: number; method: string; script?: string; candidate?: string };
const stopwords = Object.entries(profiles).map(([code, words]) => [code, new Set(words)] as const);
export function language(text: string): Detection {
  const sample = graphemes(text.slice(0, 16000)).slice(0, 4000).join(''), alphabetic = sample.match(/\p{Alphabetic}/gu) ?? [], n = alphabetic.length; if (!n) return { code: 'und', confidence: 0, method: 'insufficient text' };
  const scriptCount = (rx: RegExp) => alphabetic.filter(c => rx.test(c)).length / n;
  const kana = scriptCount(/[\p{Script=Hiragana}\p{Script=Katakana}]/u), han = scriptCount(/\p{Script=Han}/u);
  if (kana > .1) return { code: 'ja', confidence: Math.min(1, kana + han + .3), method: 'script heuristic', script: 'Japanese kana' };
  if (scriptCount(/\p{Script=Hangul}/u) > .5) return { code: 'ko', confidence: scriptCount(/\p{Script=Hangul}/u), method: 'script heuristic', script: 'Hangul' };
  for (const [rx, script, candidate] of [[/\p{Script=Han}/u,'Han','zh'],[/\p{Script=Cyrillic}/u,'Cyrillic','ru'],[/\p{Script=Arabic}/u,'Arabic','ar'],[/\p{Script=Devanagari}/u,'Devanagari','hi'],[/\p{Script=Thai}/u,'Thai','th'],[/\p{Script=Greek}/u,'Greek','el'],[/\p{Script=Hebrew}/u,'Hebrew','he']] as const) if (scriptCount(rx) > .5) return { code: 'und', confidence: 0, method: 'shared script; language uncertain', script, candidate };
  if (scriptCount(/\p{Script=Latin}/u) <= .5) return { code: 'und', confidence: 0, method: 'mixed or unsupported script' };
  const tokens = words(sample); if (tokens.length < 3) return { code: 'und', confidence: .1, method: 'insufficient text' };
  const scores = stopwords.map(([code, set]) => ({ code, score: tokens.filter(w => w.length <= 12 && set.has(w)).length / tokens.length })).sort((a,b) => b.score - a.score || a.code.localeCompare(b.code,'en'));
  if (scores[0].score <= .03 || scores[0].score === scores[1].score) return { code: 'und', confidence: .1, method: 'stopword profile ambiguous' };
  return { code: scores[0].code, confidence: Math.min(1, scores[0].score * 3 + (scores[0].score - scores[1].score) * 2), method: 'stopword heuristic; score is not a probability' };
}
export const piiKinds = ['email','phone','ipAddress','creditCard','iban','ssn','apiKey','url_credentials'] as const;
export type PIIKind = typeof piiKinds[number];
export type PIIMatch = { kind: PIIKind; start: number; end: number; text: string };
export function validCard(s: string): boolean { const digits = s.replace(/[^0-9]/g,''); if (digits.length < 13 || digits.length > 19 || new Set(digits).size < 2) return false; let sum=0; [...digits].reverse().forEach((c,i)=>{let d=+c;if(i%2){d*=2;if(d>9)d-=9;}sum+=d;});return sum%10===0; }
export function validIBAN(s: string): boolean { s=s.replace(/ /g,'').toUpperCase();if(!/^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$/.test(s))return false;let rem=0;for(const c of s.slice(4)+s.slice(0,4)){const n=/[A-Z]/.test(c)?c.charCodeAt(0)-55:+c;rem=(rem*(n>=10?100:10)+n)%97;}return rem===1; }
function validIP(s:string):boolean{if(s.includes('.'))return /^(?:\d{1,3}\.){3}\d{1,3}$/.test(s)&&s.split('.').every(n=>+n<=255);if(!/^[0-9a-f:]+$/i.test(s)||!s.includes(':')||s.includes(':::'))return false;const parts=s.split('::');if(parts.length>2)return false;const groups=parts.flatMap(p=>p?p.split(':'):[]);return groups.every(p=>/^[0-9a-f]{1,4}$/i.test(p))&&(parts.length===2?groups.length<8:groups.length===8);}
export function detectPII(text: string, kinds: PIIKind[] = []): PIIMatch[] {
  const active=new Set(kinds.length?kinds:piiKinds), found:PIIMatch[]=[];
  const packs: [PIIKind,RegExp,((s:string)=>boolean)?][] = [
    ['url_credentials',/[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\s/:@]+:[^\s/@]+@[^\s]+/g],
    ['apiKey',/(?:sk-(?:ant-)?[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|gh[pou]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|ya29\.[0-9A-Za-z_-]{20,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})/g],
    ['iban',/\b[A-Z]{2}[0-9]{2}(?: ?[A-Z0-9]){11,30}\b/g,validIBAN],
    ['creditCard',/\b(?:[0-9][ -]?){13,19}\b/g,validCard],
    ['email',/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,24}/g],
    ['ssn',/\b\d{3}-\d{2}-\d{4}\b/g,s=>!/^(000|666|9)/.test(s)&&s.slice(4,6)!=='00'&&s.slice(7)!=='0000'],
    ['ipAddress',/(?<![\w.:])(?:(?:[0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-fA-F:]*:[0-9a-fA-F:]+)(?![\w.:])/g,validIP],
    ['phone',/(?<![\d.\w])(?:\+?[0-9]{1,3}[ .-]?)?(?:\(?\d{2,4}\)?[ .-]?)\d{3,4}[ .-]?\d{3,5}(?![\d.])/g,s=>{const digits=s.replace(/\D/g,'');return digits.length>=8&&digits.length<=15&&/[+ .()-]/.test(s);}],
  ];
  for(const [kind,rx,valid] of packs){if(!active.has(kind))continue;for(const m of text.matchAll(rx)){const start=m.index;let match=m[0];if(kind==='iban'&&valid&&!valid(match)){let prefix='';for(let j=match.length-1;j>=15;j--){if(match[j]!==' '||match[j-1]===' ')continue;const candidate=match.slice(0,j);if(valid(candidate)){prefix=candidate;break;}}if(!prefix)continue;match=prefix;}else if(valid&&!valid(match))continue;const end=start+match.length;if(found.some(f=>start<f.end&&end>f.start))continue;found.push({kind,start,end,text:match});if(found.length>10000)throw Error('PII scan exceeds 10,000 matches in one cell.');}}
  return found.sort((a,b)=>a.start-b.start);
}
export async function redactPII(text:string,kinds:PIIKind[]=[],mode:'tag'|'hash'|'remove'='tag'):Promise<{text:string;counts:Partial<Record<PIIKind,number>>}>{const matches=detectPII(text,kinds),counts:Partial<Record<PIIKind,number>>={};let out=text;for(const m of matches.reverse()){counts[m.kind]=(counts[m.kind]??0)+1;let replacement='';if(mode==='tag')replacement='['+m.kind.toUpperCase()+']';if(mode==='hash'){const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(m.text));const hash=Array.from(new Uint8Array(digest),b=>b.toString(16).padStart(2,'0')).join('').slice(0,16);replacement=`[${m.kind.toUpperCase()}:${hash}]`;}out=out.slice(0,m.start)+replacement+out.slice(m.end);}return {text:out,counts};}
export function ngrams(text:string,n:number):Set<string>{if(!Number.isInteger(n)||n<1||n>20)throw Error('N-gram size must be 1–20.');const tokens=words(text),set=new Set<string>();for(let i=0;i+n<=tokens.length;i++)set.add(tokens.slice(i,i+n).join(' '));return set;}
export function evaluationIndex(texts:string[],n:number):Set<string>{const set=new Set<string>();for(const t of texts)for(const g of ngrams(t,n)){set.add(g);if(set.size>1_000_000)throw Error('Evaluation corpus exceeds one million unique n-grams.');}return set;}
