import QRCode from 'qrcode';
import { readFile, mkdir, copyFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const links = JSON.parse(await readFile(resolve(root, 'web/links.json'), 'utf8'));
const directory = resolve(root, 'web/qr');
await mkdir(directory, { recursive: true });

for (const [role, label] of [['customer', 'Customer'], ['rider', 'Rider']]) {
  const url = links[role];
  if (typeof url !== 'string' || new URL(url).protocol !== 'https:') {
    throw new Error(`Missing HTTPS ${role} download URL`);
  }
  const name = `Haan-${label}-Download-QR.png`;
  const inWeb = resolve(directory, name);
  await QRCode.toFile(inWeb, url, {
    errorCorrectionLevel: 'H',
    margin: 4,
    width: 1024,
    color: { dark: '#0a0907', light: '#f4efe4' },
  });
  await copyFile(inWeb, resolve(root, name));
  console.log(`${name} -> ${url}`);
}
