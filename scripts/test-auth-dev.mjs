import { createCipheriv, createHmac, pbkdf2Sync, randomBytes, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { neon } from '@neondatabase/serverless';

const vars = Object.fromEntries(readFileSync(new URL('../worker/.dev.vars', import.meta.url),'utf8').split(/\r?\n/)
  .filter(line=>/^[A-Z_]+=/.test(line)).map(line=>[line.slice(0,line.indexOf('=')),line.slice(line.indexOf('=')+1)]));
if(new URL(vars.DATABASE_URL).hostname!=='ep-bold-sea-b3lygotf-pooler.c-4.ap-southeast-1.aws.neon.tech')throw new Error('Development database host mismatch');
const sql = neon(vars.DATABASE_URL), base = 'http://127.0.0.1:8787';
const [fixture] = await sql`select id from users where email='rider.demo@haan.invalid'`;
if (!fixture) throw new Error('Development fixture missing; refusing test writes');
let checks=0;
async function request(path,method='GET',body,token,ip='198.51.100.11') {
  const response=await fetch(base+path,{method,headers:{'CF-Connecting-IP':ip,...(body?{'Content-Type':'application/json'}:{}),...(token?{Authorization:`Bearer ${token}`}:{})},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(25000)});
  return {status:response.status,data:await response.json()};
}
function assert(label,result,status,predicate=()=>true){checks++;if(result.status!==status||!predicate(result.data))throw new Error(`${label}: expected ${status}, got ${result.status}, code ${result.data?.code||'none'}`);console.log(`PASS ${label}`);return result.data;}
const suffix=Date.now().toString(36), email=`srimantasutapa123+haanqa${suffix}@gmail.com`;
const code='482913';
const adminIds=[];
const hash=value=>createHmac('sha256',vars.SESSION_SECRET).update(value).digest('hex');
function totp(secret){const counter=Buffer.alloc(8);counter.writeBigUInt64BE(BigInt(Math.floor(Date.now()/30000)));const digest=createHmac('sha1',secret).update(counter).digest();const offset=digest[digest.length-1]&15;return String((digest.readUInt32BE(offset)&0x7fffffff)%1000000).padStart(6,'0');}
async function makeAdmin(role){
  const address=`qa-${role}-${randomUUID()}@haan.invalid`, password=randomBytes(28).toString('base64url');
  const salt=randomBytes(32).toString('base64url');
  const passwordHash=`${salt}:${pbkdf2Sync(password,salt,100000,32,'sha256').toString('hex')}`;
  const secret=randomBytes(20).toString('base64url'),iv=randomBytes(12);
  const cipher=createCipheriv('aes-256-gcm',Buffer.from(vars.ADMIN_TOTP_KEY,'base64'),iv);
  const encrypted=Buffer.concat([cipher.update(secret,'utf8'),cipher.final(),cipher.getAuthTag()]);
  const ciphertext=`${iv.toString('base64url')}.${encrypted.toString('base64url')}`;
  const [user]=await sql`insert into users(email,role) values(${address},${role}::user_role) returning id`;
  adminIds.push(user.id);
  await sql`insert into admin_credentials(user_id,password_hash,totp_ciphertext) values(${user.id}::uuid,${passwordHash},${ciphertext})`;
  return {email:address,password,code:totp(Buffer.from(secret,'base64url')),id:user.id};
}
try {
  assert('Google login requires token',await request('/v1/auth/google','POST',{role:'customer'}),400);
  assert('forged Google token rejected',await request('/v1/auth/google','POST',
    {role:'customer',id_token:'header.payload.signature'}),401);
  assert('OTP email sent',await request('/v1/auth/request-otp','POST',{email,role:'customer'}),200);
  assert('resend cooldown',await request('/v1/auth/request-otp','POST',{email,role:'customer'}),429,data=>data.code==='resend_cooldown');
  assert('wrong OTP attempt',await request('/v1/auth/verify-otp','POST',{email,role:'customer',code:'000000'}),400,data=>data.attempts_left===4);
  await sql`update otp_codes set code_hash=${hash(`${email}:${code}`)} where email=${email}`;
  const login=assert('correct OTP accepted',await request('/v1/auth/verify-otp','POST',{email,role:'customer',code}),200,data=>Boolean(data.access_token&&data.refresh_token));
  assert('OTP reuse blocked',await request('/v1/auth/verify-otp','POST',{email,role:'customer',code}),400);
  assert('customer profile',await request('/v1/profile','GET',undefined,login.access_token),200,data=>data.profile.email===email);
  const refreshed=assert('session refresh',await request('/v1/auth/refresh','POST',{refresh_token:login.refresh_token}),200,data=>Boolean(data.refresh_token));
  assert('old refresh token blocked',await request('/v1/auth/refresh','POST',{refresh_token:login.refresh_token}),401);
  assert('logout',await request('/v1/auth/logout','POST',{refresh_token:refreshed.refresh_token},refreshed.access_token),200);
  assert('logged-out refresh blocked',await request('/v1/auth/refresh','POST',{refresh_token:refreshed.refresh_token}),401);
  assert('customer deletion',await request('/v1/profile','DELETE',undefined,refreshed.access_token),200);
  assert('deleted account token blocked',await request('/v1/profile','GET',undefined,refreshed.access_token),401);

  const superAdmin=await makeAdmin('super_admin'),support=await makeAdmin('support_agent');
  const lockIp=`203.0.113.${50+Math.floor(Math.random()*100)}`;
  for(let i=1;i<=5;i++) assert(`wrong admin password ${i}`,await request('/v1/admin/login','POST',{email:superAdmin.email,password:'wrong',totp:superAdmin.code},undefined,lockIp),401);
  assert('admin locked after five',await request('/v1/admin/login','POST',{email:superAdmin.email,password:superAdmin.password,totp:superAdmin.code},undefined,lockIp),429);
  const adminLogin=assert('super admin TOTP login',await request('/v1/admin/login','POST',{email:superAdmin.email,password:superAdmin.password,totp:superAdmin.code},undefined,'203.0.113.201'),200,data=>Boolean(data.access_token));
  assert('admin dashboard',await request('/v1/admin/dashboard','GET',undefined,adminLogin.access_token),200,data=>Boolean(data.trips&&data.riders));
  assert('admin audit login',await request('/v1/admin/audit','GET',undefined,adminLogin.access_token),200,data=>data.entries.some(x=>x.action==='login'&&x.admin_email===superAdmin.email));
  const supportLogin=assert('support TOTP login',await request('/v1/admin/login','POST',{email:support.email,password:support.password,totp:support.code},undefined,'198.51.100.14'),200);
  assert('support fare edit denied',await request('/v1/admin/fares/Bike','PATCH',{base:20,per_km:6,per_min:0.5,minimum:30,reason:'QA'},supportLogin.access_token),403);
  assert('support cannot settle rider balances',await request('/v1/admin/settlements/00000000-0000-0000-0000-000000000000/settle','POST',
    {reason:'QA'},supportLogin.access_token),403);
  assert('support audit denied',await request('/v1/admin/audit','GET',undefined,supportLogin.access_token),403);
  console.log(`PASS ${checks} development auth/admin checks`);
} finally {
  for(const id of adminIds){
    await sql`delete from admin_credentials where user_id=${id}::uuid`;
    await sql`update users set email='deleted+'||id||'@haan.invalid',deleted_at=now() where id=${id}::uuid`;
  }
}
