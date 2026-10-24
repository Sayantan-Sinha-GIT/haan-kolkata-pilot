import { createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
const base='https://haan-api.srimantasutapa123.workers.dev';
async function call(path,method='GET',body,token,origin){
  const response=await fetch(base+path,{method,headers:{...(body?{'Content-Type':'application/json'}:{}),...(token?{Authorization:`Bearer ${token}`}:{}),...(origin?{Origin:origin}:{})},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(25000)});
  return {status:response.status,data:await response.json()};
}
function check(label,result,status,predicate=()=>true){if(result.status!==status||!predicate(result.data))throw new Error(`${label}: expected ${status}, got ${result.status}, code ${result.data?.code||'none'}`);console.log(`PASS ${label}`);return result.data;}
check('production health',await call('/health'),200,data=>data.ok);
check('production fares',await call('/v1/fares'),200,data=>Array.isArray(data)&&data.length===3);
check('production bad origin blocked',await call('/v1/fares','GET',undefined,undefined,'https://example.invalid'),403);
const places=check('production Ola search',await call('/v1/places/search?q=Howrah%20Railway%20Station'),200,data=>data.places?.length>0);
if(!places.places.some(x=>x.source==='ola'))throw new Error('Ola search did not use configured key');
const pickup={lat:22.5726,lng:88.3639,text:'Esplanade Kolkata'},drop={lat:22.5839,lng:88.3425,text:'Victoria Memorial Kolkata'};
check('production fare routing',await call('/v1/fare/estimate','POST',{pickup,drop,vehicle:'Auto'}),200,data=>data.rupees>0&&data.route_source==='ola');
check('production protected endpoint',await call('/v1/profile'),401);
const email=`srimantasutapa123+haanprodqa${Date.now().toString(36)}@gmail.com`;
check('production Brevo OTP',await call('/v1/auth/request-otp','POST',{email,role:'customer'}),200);

const text=readFileSync(new URL('../secrets/admin-onboarding.txt',import.meta.url),'utf8');
const field=name=>text.match(new RegExp(`^${name}:\\s*(.+)$`,'m'))?.[1]?.trim();
const adminEmail=field('Email'),password=field('Password'),uri=field('Authenticator URI');
if(!adminEmail||!password||!uri)throw new Error('Admin onboarding fields missing');
const secret=new URL(uri).searchParams.get('secret');
if(!secret)throw new Error('Authenticator setup key missing');
const alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';let bits=0,value=0,raw=[];
for(const letter of secret.toUpperCase()){const digit=alphabet.indexOf(letter);if(digit<0)continue;value=(value<<5)|digit;bits+=5;if(bits>=8){raw.push((value>>>(bits-8))&255);bits-=8;}}
const counter=Buffer.alloc(8);counter.writeBigUInt64BE(BigInt(Math.floor(Date.now()/30000)));
const digest=createHmac('sha1',Buffer.from(raw)).update(counter).digest();
const offset=digest[digest.length-1]&15,totp=String((digest.readUInt32BE(offset)&0x7fffffff)%1000000).padStart(6,'0');
const login=check('production admin login',await call('/v1/admin/login','POST',{email:adminEmail,password,totp}),200,data=>Boolean(data.access_token));
check('production admin dashboard',await call('/v1/admin/dashboard','GET',undefined,login.access_token),200,data=>Boolean(data.trips&&data.riders));
const quotas=check('production quota dashboard',await call('/v1/admin/quotas','GET',undefined,login.access_token),200,data=>data.caps.ola===1000&&data.caps.brevo===300);
console.log(JSON.stringify({quotaCaps:quotas.caps,used:quotas.used}));
