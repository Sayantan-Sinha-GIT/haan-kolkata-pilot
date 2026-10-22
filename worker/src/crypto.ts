const bytes = (s: string) => new TextEncoder().encode(s);
const hex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map(v => v.toString(16).padStart(2, '0')).join('');
const b64url = (buf: ArrayBuffer | Uint8Array) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const fromB64 = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - s.length % 4) % 4)), c => c.charCodeAt(0));

export async function hmac(secret: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', bytes(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return hex(await crypto.subtle.sign('HMAC', key, bytes(value)));
}
export function randomDigits(length: number): string {
  const a = new Uint32Array(length);
  crypto.getRandomValues(a);
  return [...a].map(n => String(n % 10)).join('');
}
export function randomToken(): string {
  const a = new Uint8Array(32);
  crypto.getRandomValues(a);
  return b64url(a);
}
export async function passwordHash(password: string, salt = randomToken()): Promise<string> {
  const key = await crypto.subtle.importKey('raw', bytes(password), 'PBKDF2', false, ['deriveBits']);
  return `${salt}:${hex(await crypto.subtle.deriveBits({ name: 'PBKDF2', salt: bytes(salt), iterations: 100_000, hash: 'SHA-256' }, key, 256))}`;
}
export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const salt = stored.split(':')[0];
  return !!salt && await passwordHash(password, salt) === stored;
}
export async function signAccess(secret: string, user: { id: string; role: string }): Promise<string> {
  const body = b64url(bytes(JSON.stringify({ sub: user.id, role: user.role, exp: Math.floor(Date.now() / 1000) + 900 })));
  return `${body}.${await hmac(secret, body)}`;
}
export async function verifyAccess(secret: string, token: string): Promise<{ sub: string; role: string } | null> {
  const [body, sig] = token.split('.');
  if (!body || !sig || await hmac(secret, body) !== sig) return null;
  try {
    const claims = JSON.parse(new TextDecoder().decode(fromB64(body))) as { sub: string; role: string; exp: number };
    return claims.exp > Date.now() / 1000 ? claims : null;
  } catch { return null; }
}
export async function totp(secret: string, at = Date.now()): Promise<string> {
  const raw = fromB64(secret);
  const key = await crypto.subtle.importKey('raw', raw, { name: 'HMAC', hash: 'SHA-1' }, false, ['sign']);
  const counter = Math.floor(at / 30_000);
  const value = new Uint8Array(8);
  new DataView(value.buffer).setUint32(4, counter);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, value));
  const offset = mac[mac.length - 1] & 15;
  const code = (((mac[offset] & 127) << 24) | (mac[offset + 1] << 16) | (mac[offset + 2] << 8) | mac[offset + 3]) % 1_000_000;
  return String(code).padStart(6, '0');
}
export async function verifyTotp(secret: string, code: string): Promise<boolean> {
  if (!/^\d{6}$/.test(code)) return false;
  for (const delta of [-30_000, 0, 30_000]) if (await totp(secret, Date.now() + delta) === code) return true;
  return false;
}
export async function decryptTotp(keyString: string, encoded: string): Promise<string> {
  const [ivString, cipherString] = encoded.split('.');
  const key = await crypto.subtle.importKey('raw', fromB64(keyString), 'AES-GCM', false, ['decrypt']);
  const decrypted = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: fromB64(ivString) }, key, fromB64(cipherString));
  return new TextDecoder().decode(decrypted);
}
export function newTotpSecret():string {const a=new Uint8Array(20);crypto.getRandomValues(a);return b64url(a);}
export function totpSetupKey(secret:string):string{
  const alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZ234567',raw=fromB64(secret);let bits=0,value=0,result='';
  for(const byte of raw){value=(value<<8)|byte;bits+=8;while(bits>=5){result+=alphabet[(value>>>(bits-5))&31];bits-=5;}}
  if(bits>0)result+=alphabet[(value<<(5-bits))&31];return result;
}
export async function encryptTotp(keyString:string,secret:string):Promise<string>{
  const key=await crypto.subtle.importKey('raw',fromB64(keyString),'AES-GCM',false,['encrypt']);
  const iv=new Uint8Array(12);crypto.getRandomValues(iv);
  const cipher=await crypto.subtle.encrypt({name:'AES-GCM',iv},key,bytes(secret));
  return `${b64url(iv)}.${b64url(cipher)}`;
}

