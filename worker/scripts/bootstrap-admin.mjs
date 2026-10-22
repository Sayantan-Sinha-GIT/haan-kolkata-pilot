import { randomBytes, pbkdf2Sync, createCipheriv } from 'node:crypto';
import { access, mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { neon } from '@neondatabase/serverless';

const url=process.env.DATABASE_URL;
const email=process.env.HAAN_ADMIN_EMAIL?.trim().toLowerCase();
if(!url||!email)throw Error('Set DATABASE_URL and HAAN_ADMIN_EMAIL in the process environment.');
const directory=resolve('secrets');
const output=resolve(directory,'admin-onboarding.txt');
try { await access(output); throw Error(`Refusing to replace existing onboarding file: ${output}`); }
catch (error) { if (error.code!=='ENOENT') throw error; }
const password=randomBytes(24).toString('base64url');
const salt=randomBytes(32).toString('base64url');
const passwordHash=`${salt}:${pbkdf2Sync(password,salt,100000,32,'sha256').toString('hex')}`;
const suppliedKey=process.env.ADMIN_TOTP_KEY;
const key=suppliedKey?Buffer.from(suppliedKey,'base64url'):randomBytes(32);
if(key.length!==32)throw Error('ADMIN_TOTP_KEY must decode to exactly 32 bytes.');
const iv=randomBytes(12),totp=randomBytes(20).toString('base64url');
function base32(input){const alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';let bits=0,value=0,result='';for(const byte of input){value=(value<<8)|byte;bits+=8;while(bits>=5){result+=alphabet[(value>>>(bits-5))&31];bits-=5;}}if(bits>0)result+=alphabet[(value<<(5-bits))&31];return result;}
const setupKey=base32(Buffer.from(totp,'base64url'));
const cipher=createCipheriv('aes-256-gcm',key,iv);
const ciphertext=Buffer.concat([cipher.update(totp,'utf8'),cipher.final(),cipher.getAuthTag()]);
const encoded=`${iv.toString('base64url')}.${ciphertext.toString('base64url')}`;
const sql=neon(url);
const [user]=await sql`insert into users(email,role) values(${email},'super_admin') on conflict(email) do update set role='super_admin',deleted_at=null,is_blocked=false returning id`;
await sql`insert into admin_credentials(user_id,password_hash,totp_ciphertext) values(${user.id}::uuid,${passwordHash},${encoded}) on conflict(user_id) do update set password_hash=excluded.password_hash,totp_ciphertext=excluded.totp_ciphertext`;
await mkdir(directory,{recursive:true});
await writeFile(output,`Haan admin login\nEmail: ${email}\nPassword: ${password}\nAuthenticator setup key: ${setupKey}\nAuthenticator URI: otpauth://totp/Haan:${encodeURIComponent(email)}?secret=${setupKey}&issuer=Haan&algorithm=SHA1&digits=6&period=30\nWorker secret ADMIN_TOTP_KEY: ${key.toString('base64url')}\nKeep this file private. Store the authenticator setup key in your authenticator app, then remove this file after backing up the credentials securely.\n`,{mode:0o600,flag:'wx'});
process.stdout.write(`Admin created. Private onboarding instructions: ${output}\n`);
