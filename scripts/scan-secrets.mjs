import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const provider=Object.fromEntries(readFileSync(new URL('../secrets/provider-keys.env',import.meta.url),'utf8').split(/\r?\n/)
  .filter(x=>/^[A-Z_]+=/.test(x)).map(x=>[x.slice(0,x.indexOf('=')),x.slice(x.indexOf('=')+1).trim()]));
const worker=JSON.parse(readFileSync(new URL('../secrets/worker-secrets.json',import.meta.url),'utf8'));
const firebase=JSON.parse(readFileSync(new URL('../secrets/firebase-service-account.json',import.meta.url),'utf8'));
const secrets={...provider,...worker,FIREBASE_PRIVATE_KEY:firebase.private_key,FIREBASE_CLIENT_EMAIL:firebase.client_email};
const files=execFileSync('git',['ls-files','-z','--cached','--others','--exclude-standard'],{cwd:root}).toString().split('\0').filter(Boolean);
const apks=['.qa/release-1.0.2/customer/app-arm64-v8a-release.apk','.qa/release-1.0.2/rider/app-arm64-v8a-release.apk'];
let hits=0;
for(const relative of [...files,...apks]){
  let bytes;try{bytes=readFileSync(join(root,relative));}catch{continue;}
  for(const [name,value] of Object.entries(secrets)){
    if(typeof value!=='string'||value.length<16)continue;
    if(bytes.includes(Buffer.from(value))||bytes.includes(Buffer.from(encodeURIComponent(value)))){
      console.log(`SECRET_MATCH ${name} ${relative}`);hits++;
    }
  }
}
console.log(`Secret scan: ${files.length} tracked/new files and ${apks.length} APKs; ${hits} matches`);
if(hits)process.exitCode=1;
