import sharp from 'sharp';
import { readFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
const sizes={mdpi:48,hdpi:72,xhdpi:96,xxhdpi:144,xxxhdpi:192};
for(const [app,source] of [['customer','haan-mark.svg'],['rider','haan-rider-mark.svg']]){
  const svg=await readFile(resolve('brand',source));
  for(const [density,size] of Object.entries(sizes)){
    const dir=resolve('apps',app,'android','app','src','main','res',`mipmap-${density}`);
    await mkdir(dir,{recursive:true});
    await sharp(svg).resize(size,size).png().toFile(resolve(dir,'ic_launcher.png'));
  }
}
