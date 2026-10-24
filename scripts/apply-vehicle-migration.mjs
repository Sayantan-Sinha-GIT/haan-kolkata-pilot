import { readFileSync } from 'node:fs';
import { neon } from '@neondatabase/serverless';

const root = new URL('../', import.meta.url);
const dev = Object.fromEntries(readFileSync(new URL('worker/.dev.vars', root), 'utf8')
  .split(/\r?\n/).filter(line => /^[A-Z_]+=/.test(line))
  .map(line => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]));
const prod = JSON.parse(readFileSync(new URL('secrets/worker-secrets.json', root), 'utf8'));
const migration = readFileSync(new URL('worker/migrations/2026-10-25-vehicle-verification.sql', root), 'utf8');
const hosts = {
  dev: 'ep-bold-sea-b3lygotf-pooler.c-4.ap-southeast-1.aws.neon.tech',
  prod: 'ep-odd-morning-b3s3fir1-pooler.c-4.ap-southeast-1.aws.neon.tech',
};
for (const [name, url] of [['dev', dev.DATABASE_URL], ['prod', prod.DATABASE_URL]]) {
  if (new URL(url).hostname !== hosts[name]) throw Error(`${name} database host mismatch`);
  const sql = neon(url);
  for (const statement of migration.split(';').map(s => s.trim()).filter(Boolean)) {
    await sql.query(statement);
  }
  const columns = await sql`select table_name,column_name from information_schema.columns where table_schema='public'
    and ((table_name='rider_profiles' and column_name in ('vehicle_make','vehicle_model','vehicle_color','vehicle_year','licence_number','insurance_expiry','permit_expiry','insurance_key','permit_key'))
      or (table_name='trips' and column_name='pickup_note'))`;
  if (columns.length !== 10) throw Error(`${name} migration verification failed: ${columns.length}/10 columns`);
  console.log(`${name}: verified 10 new columns`);
}
