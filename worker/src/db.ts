import { neon } from '@neondatabase/serverless';
import type { Env } from './types';

export const db = (env: Env) => neon(env.DATABASE_URL);

export async function consumeLimit(env: Env, key: string, max: number, bucketMinutes: number): Promise<boolean> {
  const sql = db(env);
  const bucket = new Date(Math.floor(Date.now() / (bucketMinutes * 60_000)) * bucketMinutes * 60_000).toISOString();
  const rows = await sql`insert into request_limits(key,bucket,count) values(${key},${bucket}::timestamptz,1)
    on conflict(key,bucket) do update set count=request_limits.count+1
    where request_limits.count<${max} returning count`;
  return rows.length > 0;
}

export async function useQuota(env: Env, service: 'ola' | 'gemini' | 'groq' | 'brevo'): Promise<boolean> {
  const cap = Number(env[`${service.toUpperCase()}_DAILY_FREE_CAP` as keyof Env] || 0);
  if (!Number.isFinite(cap) || cap <= 0) return false;
  const sql = db(env);
  const rows = await sql`insert into quota_usage(service,usage_date,count) values(${service},current_date,1)
    on conflict(service,usage_date) do update set count=quota_usage.count+1
    where quota_usage.count<${Math.floor(cap * 0.8)} returning count`;
  return rows.length > 0;
}
