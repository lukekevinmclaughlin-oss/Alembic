import fs from'node:fs/promises';import crypto from'node:crypto';import{spawnSync}from'node:child_process';
await fs.mkdir('public',{recursive:true});await fs.mkdir('build',{recursive:true});
const icon=await fs.readFile('../App/Resources/Assets.xcassets/AppIcon.appiconset/icon_ios_1024.png');await fs.writeFile('public/icon.png',icon);await fs.copyFile('resources/cl100k_base.tiktoken','public/cl100k_base.tiktoken');
const hash=crypto.createHash('sha256').update(await fs.readFile('resources/cl100k_base.tiktoken')).digest('hex');if(hash!=='223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7')throw Error('Tokenizer vocabulary checksum mismatch.');
const{default:pngToIco}=await import('png-to-ico');await fs.writeFile('build/icon.ico',await pngToIco(icon));const result=spawnSync(process.execPath,['scripts/prepare-core.mjs'],{stdio:'inherit'});if(result.status)process.exit(result.status);console.log('Prepared Alembic icon, verified tokenizer and shared engine.');
