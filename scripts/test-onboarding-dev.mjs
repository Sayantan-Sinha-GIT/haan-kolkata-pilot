import { createHmac, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { neon } from '@neondatabase/serverless';

const vars=Object.fromEntries(readFileSync(new URL('../worker/.dev.vars',import.meta.url),'utf8').split(/\r?\n/)
  .filter(x=>/^[A-Z_]+=/.test(x)).map(x=>[x.slice(0,x.indexOf('=')),x.slice(x.indexOf('=')+1)]));
if(new URL(vars.DATABASE_URL).hostname!=='ep-bold-sea-b3lygotf-pooler.c-4.ap-southeast-1.aws.neon.tech')throw Error('Development database host mismatch');
const sql=neon(vars.DATABASE_URL),base='http://127.0.0.1:8787';
const [admin]=await sql`insert into users(email,role,name) values('qa-admin@haan.invalid','super_admin','QA admin')
  on conflict(email) do update set role='super_admin',is_blocked=false,deleted_at=null returning id,role`;
await sql`insert into admin_activity(user_id,last_seen_at) values(${admin.id}::uuid,now()) on conflict(user_id) do update set last_seen_at=now()`;
const [rider]=await sql`select id,role from users where email='rider.demo@haan.invalid' and role='rider'`;
if(!rider)throw Error('Development rider fixture missing');
const token=user=>{const body=Buffer.from(JSON.stringify({sub:user.id,role:user.role,exp:Math.floor(Date.now()/1000)+900})).toString('base64url');return `${body}.${createHmac('sha256',vars.SESSION_SECRET).update(body).digest('hex')}`};
const riderToken=token(rider),adminToken=token(admin);
let count=0;
async function call(path,method='GET',body,auth=riderToken,type='application/json'){
  const response=await fetch(base+path,{method,headers:{Authorization:`Bearer ${auth}`, ...(body?{'Content-Type':type}:{})},
    body:body?(type==='application/json'?JSON.stringify(body):body):undefined,signal:AbortSignal.timeout(25000)});
  const data=await response.json().catch(()=>({}));return {status:response.status,data};
}
function check(label,result,status,predicate=()=>true){count++;if(result.status!==status||!predicate(result.data))throw Error(`${label}: ${result.status} ${result.data.code||''}`);console.log(`PASS ${label}`)}
const profile={vehicle_type:'Bike',vehicle_number:'WB 12 AB 1234',vehicle_make:'Hero',vehicle_model:'Splendor',vehicle_color:'Black',
  vehicle_year:2022,licence_number:'WB1220120001234',insurance_expiry:'2027-12-31',upi_id:'qa@upi'};
check('invalid mobile rejected',await call('/v1/profile','PATCH',{phone:'1234'}),400);
check('mobile saved',await call('/v1/profile','PATCH',{name:'QA Rider',phone:'9876543210'}),200);
check('bad plate rejected',await call('/v1/rider/profile','PATCH',{...profile,vehicle_number:'ABC'}),400);
check('expired insurance rejected',await call('/v1/rider/profile','PATCH',{...profile,insurance_expiry:'2020-01-01'}),400);
check('profile saved',await call('/v1/rider/profile','PATCH',profile),200);
check('cannot approve missing documents',await call(`/v1/admin/riders/${rider.id}/verify`,'POST',{decision:'approved'},adminToken),409);
check('cannot go online before review',await call('/v1/rider/online','POST',{online:true,lat:22.5726,lng:88.3639}),403);
const fake=Buffer.from('not a webp image');
check('forged image rejected',await call('/v1/rider/documents/licence','POST',fake,riderToken,'image/webp'),400);
const image=readFileSync(new URL('../web/photos/kolkata-auto-driver.webp',import.meta.url));
for(const kind of ['licence','rc','selfie','insurance'])check(`${kind} uploaded`,await call(`/v1/rider/documents/${kind}`,'POST',image,riderToken,'image/webp'),200);
const after=await call('/v1/rider/profile');
check('registration complete',after,200,d=>d.profile.registration_complete===true&&d.profile.vehicle_number==='WB12AB1234');
check('admin sees all four documents',await call(`/v1/admin/riders/${rider.id}`,'GET',undefined,adminToken),200,d=>['licence','rc','selfie','insurance'].every(k=>d.documents[k]));
check('approval succeeds',await call(`/v1/admin/riders/${rider.id}/verify`,'POST',{decision:'approved'},adminToken),200);
check('approved rider can go online',await call('/v1/rider/online','POST',{online:true,lat:22.5726,lng:88.3639}),200,d=>d.online===true);
check('rider offline',await call('/v1/rider/online','POST',{online:false}),200,d=>d.online===false);

const email=`qa-auto-${randomUUID()}@haan.invalid`;
const [auto]=await sql`insert into users(email,role,name,phone) values(${email},'rider','QA Auto','9876543210') returning id,role`;
const autoToken=token(auto),autoProfile={...profile,vehicle_type:'Auto',vehicle_number:'WB 02 CD 5678',vehicle_make:'Bajaj',vehicle_model:'RE Auto',vehicle_color:'Yellow',permit_expiry:'2027-12-31'};
check('auto profile saved',await call('/v1/rider/profile','PATCH',autoProfile,autoToken),200);
for(const kind of ['licence','rc','selfie','insurance'])check(`auto ${kind} uploaded`,await call(`/v1/rider/documents/${kind}`,'POST',image,autoToken,'image/webp'),200);
check('auto approval needs permit',await call(`/v1/admin/riders/${auto.id}/verify`,'POST',{decision:'approved'},adminToken),409);
check('auto permit uploaded',await call('/v1/rider/documents/permit','POST',image,autoToken,'image/webp'),200);
check('auto approval succeeds',await call(`/v1/admin/riders/${auto.id}/verify`,'POST',{decision:'approved'},adminToken),200);
console.log(`PASS ${count} onboarding checks`);
