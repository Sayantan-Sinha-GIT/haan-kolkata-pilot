import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root=fileURLToPath(new URL('../web/',import.meta.url));
const families=['Big Shoulders Display','Hind','IBM Plex Mono','Instrument Serif'];
const url='https://fonts.googleapis.com/css2?family=Big+Shoulders+Display:wght@600..900&family=Hind:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500&family=Instrument+Serif:ital@1&display=optional';
const response=await fetch(url,{headers:{'User-Agent':'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36'}});
if(!response.ok)throw new Error(`Font CSS HTTP ${response.status}`);
const source=await response.text();
const blocks=[...source.matchAll(/\/\*\s*([^*]+)\s*\*\/\s*(@font-face\s*\{[^}]+\})/g)];
const dir=join(root,'fonts');mkdirSync(dir,{recursive:true});
const selected=[];let count=0,bytes=0;
for(const [,subsetRaw,block] of blocks){
  const subset=subsetRaw.trim();if(!['latin','devanagari'].includes(subset))continue;
  const family=block.match(/font-family:\s*'([^']+)'/)?.[1];if(!families.includes(family))continue;
  const remote=block.match(/url\((https:\/\/[^)]+\.woff2)\)/)?.[1];if(!remote)throw new Error(`Font URL missing: ${family}`);
  const weight=block.match(/font-weight:\s*([^;]+);/)?.[1]?.trim().replace(/\s+/g,'-')||'400';
  const style=block.match(/font-style:\s*([^;]+);/)?.[1]?.trim()||'normal';
  const filename=`${family.toLowerCase().replace(/\s+/g,'-')}-${subset}-${weight}-${style}.woff2`;
  const asset=await fetch(remote);if(!asset.ok)throw new Error(`Font asset HTTP ${asset.status}`);
  const data=Buffer.from(await asset.arrayBuffer());writeFileSync(join(dir,filename),data);bytes+=data.length;count++;
  selected.push(`/* ${subset} */\n${block.replace(remote,`fonts/${filename}`)}`);
}
if(count!==12)throw new Error(`Expected 12 font subsets, got ${count}`);
writeFileSync(join(root,'fonts.css'),selected.join('\n\n')+'\n');
for(const [family,path] of Object.entries({
  'big-shoulders-display':'bigshouldersdisplay',hind:'hind','ibm-plex-mono':'ibmplexmono','instrument-serif':'instrumentserif',
})){
  const license=await fetch(`https://raw.githubusercontent.com/google/fonts/main/ofl/${path}/OFL.txt`);
  if(!license.ok)throw new Error(`${family} font license HTTP ${license.status}`);
  writeFileSync(join(dir,`${family}-OFL.txt`),await license.text());
}
console.log(`Vendored ${count} WOFF2 subsets (${bytes} bytes) with four OFL licenses.`);
