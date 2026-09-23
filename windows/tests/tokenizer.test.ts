import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { BPETokenizer } from '../src/tokenizer';
import golden from './tokenizer-golden.json';
const vocab=readFileSync('resources/cl100k_base.tiktoken','utf8'), tokenizer=new BPETokenizer(vocab);
describe('verified real cl100k tokenizer',()=>{
  it('uses the exact official vocabulary and refuses incomplete data',()=>{expect(createHash('sha256').update(vocab).digest('hex')).toBe('223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7');expect(()=>new BPETokenizer('IQ== 0')).toThrow('incomplete');});
  it.each(golden.cases.map((c,i)=>({i,...c})))('matches OpenAI tiktoken 0.14.0 case $i',c=>{const ids=tokenizer.encode(c.text);if('tokens' in c && c.tokens)expect(ids).toEqual(c.tokens);else {expect(ids.length).toBe(c.count);expect(createHash('sha256').update(JSON.stringify(ids)).digest('hex')).toBe(c.tokenSHA256);}expect(tokenizer.decode(ids)).toBe(c.text);});
  it('handles a long uninterrupted Unicode input without quadratic rescanning or argument overflow',()=>{const text='あ'.repeat(150000); const ids=tokenizer.encode(text);expect(ids.length).toBe(150000);expect(tokenizer.decode(ids)).toBe(text);},30000);
});
