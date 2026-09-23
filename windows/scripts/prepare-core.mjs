import fs from 'node:fs/promises';import ts from 'typescript';
await fs.mkdir('electron',{recursive:true});
const modules=['model','lossless-json','normalize','types','importers','tokenizer','quality','expression','dedupe','chunker','recipe','pipeline','exports','report','augmentation','workspace','engine'];
for(const name of modules){const source=await fs.readFile('src/'+name+'.ts','utf8');const result=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS,esModuleInterop:true,resolveJsonModule:true}}).outputText.replace(/require\("\.\/([a-z-]+)"\)/g,'require("./$1.cjs")');await fs.writeFile('electron/'+name+'.cjs',result);}
console.log('Prepared shared Alembic engine.');
