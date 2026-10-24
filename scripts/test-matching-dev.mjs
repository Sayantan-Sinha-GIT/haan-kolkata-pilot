import { createHmac, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { neon } from '@neondatabase/serverless';
const vars=Object.fromEntries(readFileSync(new URL('../worker/.dev.vars',import.meta.url),'utf8').split(/\r?\n/).filter(x=>/^[A-Z_]+=/.test(x)).map(x=>[x.slice(0,x.indexOf('=')),x.slice(x.indexOf('=')+1)]));
if(new URL(vars.DATABASE_URL).hostname!=='ep-bold-sea-b3lygotf-pooler.c-4.ap-southeast-1.aws.neon.tech')throw new Error('Development database host mismatch');
const sql=neon(vars.DATABASE_URL),base='http://127.0.0.1:8787';
const [rider]=await sql`select u.id,u.role from users u join rider_profiles rp on rp.user_id=u.id where u.email='rider.demo@haan.invalid' and rp.verification_status='approved'`;
if(!rider)throw new Error('Development fixture missing');
function token(user){const body=Buffer.from(JSON.stringify({sub:user.id,role:user.role,exp:Math.floor(Date.now()/1000)+900})).toString('base64url');return `${body}.${createHmac('sha256',vars.SESSION_SECRET).update(body).digest('hex')}`;}
async function call(path,method='GET',body,auth){const r=await fetch(base+path,{method,headers:{...(body?{'Content-Type':'application/json'}:{}),...(auth?{Authorization:`Bearer ${auth}`}:{})},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(25000)});return {status:r.status,data:await r.json()};}
const riderToken=token(rider),pickup={lat:22.5726,lng:88.3639,text:'Esplanade Kolkata'},drop={lat:22.5839,lng:88.3425,text:'Victoria Memorial Kolkata'};
await sql`update rider_profiles set decline_streak=0,is_online=false where user_id=${rider.id}::uuid`;
const online=await call('/v1/rider/online','POST',{online:true,lat:22.5726,lng:88.3639},riderToken);
if(online.status!==200)throw new Error(`Rider could not go online: ${online.status}`);
try{
  for(let i=1;i<=3;i++){
    const [customer]=await sql`insert into users(email,role,name) values(${`qa-decline-${randomUUID()}@haan.invalid`},'customer','QA decline') returning id,role`;
    const customerToken=token(customer);
    const trip=await call('/v1/trips','POST',{pickup,drop,vehicle:'Bike',confirmed:true},customerToken);
    if(trip.status!==201)throw new Error(`Trip ${i} creation: ${trip.status}`);
    const offers=await call('/v1/rider/offers','GET',undefined,riderToken);
    const offer=offers.data.offers?.find(x=>x.trip_id===trip.data.trip.id);
    if(!offer)throw new Error(`Offer ${i} missing`);
    const declined=await call(`/v1/rider/offers/${offer.id}/decline`,'POST',{},riderToken);
    if(declined.status!==200)throw new Error(`Decline ${i}: ${declined.status}`);
    const [state]=await sql`select decline_streak,is_online from rider_profiles where user_id=${rider.id}::uuid`;
    if(Number(state.decline_streak)!==i||state.is_online!==(i<3))throw new Error(`Decline ${i} state mismatch`);
    console.log(`PASS decline ${i}: streak ${i}, online ${state.is_online}`);
    const cancelled=await call(`/v1/trips/${trip.data.trip.id}/cancel`,'POST',{reason:'QA decline'},customerToken);
    if(cancelled.status!==200)throw new Error(`Trip ${i} cancellation: ${cancelled.status}`);
    await call('/v1/profile','DELETE',undefined,customerToken);
  }
}finally{await call('/v1/rider/online','POST',{online:false},riderToken).catch(()=>{});}
