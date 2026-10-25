import {createHmac,randomUUID} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {neon} from '@neondatabase/serverless';

const vars=Object.fromEntries(readFileSync(new URL('../worker/.dev.vars',import.meta.url),'utf8')
  .split(/\r?\n/).filter(x=>/^[A-Z_]+=/.test(x)).map(x=>[x.slice(0,x.indexOf('=')),x.slice(x.indexOf('=')+1)]));
if(new URL(vars.DATABASE_URL).hostname!=='ep-bold-sea-b3lygotf-pooler.c-4.ap-southeast-1.aws.neon.tech')
  throw Error('Refusing non-development database');
const sql=neon(vars.DATABASE_URL),base='http://127.0.0.1:8787';
const suffix=randomUUID().slice(0,8),pickup={lat:22.5726,lng:88.3639,text:'Esplanade'};
const stop={lat:22.58,lng:88.355,text:'Maidan'};
const drop={lat:22.5944,lng:88.37,text:'Sealdah'};
const token=u=>{const p=Buffer.from(JSON.stringify({sub:u.id,role:u.role,exp:Math.floor(Date.now()/1000)+3600})).toString('base64url');
  return p+'.'+createHmac('sha256',vars.SESSION_SECRET).update(p).digest('hex')};
const [source]=await sql`select rp.* from rider_profiles rp join users u on u.id=rp.user_id
  where u.email='rider.demo@haan.invalid' and rp.verification_status='approved'`;
if(!source)throw Error('Approved development rider fixture missing');
const [customer]=await sql`insert into users(role,email,name,phone) values('customer',${'qa-features-'+suffix+'@haan.invalid'},'Feature QA','9123456789') returning id,role`;
const [rider]=await sql`insert into users(role,email,name,phone) values('rider',${'qa-features-rider-'+suffix+'@haan.invalid'},'Feature QA Rider','9876543210') returning id,role`;
await sql`insert into rider_profiles(user_id,vehicle_type,vehicle_number,vehicle_make,vehicle_model,vehicle_color,vehicle_year,
  licence_number,insurance_expiry,permit_expiry,licence_key,rc_key,selfie_key,insurance_key,permit_key,upi_id,verification_status)
  values(${rider.id}::uuid,'Bike',${source.vehicle_number},${source.vehicle_make},${source.vehicle_model},
  ${source.vehicle_color},${source.vehicle_year},${source.licence_number},${source.insurance_expiry},
  ${source.permit_expiry},${source.licence_key},${source.rc_key},${source.selfie_key},
  ${source.insurance_key},${source.permit_key},'qa.rider@upi','approved')`;
const [admin]=await sql`insert into users(role,email,name) values('super_admin',${'qa-features-admin-'+suffix+'@haan.invalid'},'QA Admin') returning id,role`;
await sql`insert into admin_activity(user_id) values(${admin.id}::uuid)`;
const auth={customer:token(customer),rider:token(rider),admin:token(admin)};
let checks=0;
async function call(path,method='GET',payload,who){
  const r=await fetch(base+path,{method,headers:{...(who?{Authorization:'Bearer '+auth[who]}:{}),
    ...(payload?{'Content-Type':'application/json'}:{})},body:payload?JSON.stringify(payload):undefined,
    signal:AbortSignal.timeout(30000)});
  return {status:r.status,data:await r.json()};
}
function check(name,r,status,predicate=()=>true){checks++;
  if(r.status!==status||!predicate(r.data))throw Error(name+': '+r.status+' '+JSON.stringify(r.data).slice(0,500));
  console.log('PASS '+name);return r.data;
}
async function makeRide(extra={}){
  const d=check('create ride',await call('/v1/trips','POST',{pickup,drop,vehicle:'Bike',confirmed:true,...extra},'customer'),201,x=>/^\d{4}$/.test(x.pin));
  const offers=check('offer',await call('/v1/rider/offers','GET',undefined,'rider'),200,x=>x.offers.some(o=>o.trip_id===d.trip.id));
  const o=offers.offers.find(x=>x.trip_id===d.trip.id);
  check('accept',await call('/v1/rider/offers/'+o.id+'/accept','POST',{},'rider'),200);
  return d;
}
try{
  check('invalid extra stop',await call('/v1/fare/estimate','POST',{pickup,drop,vehicle:'Bike',stops:[pickup]}),400);
  check('two-stop quote',await call('/v1/fare/estimate','POST',{pickup,drop,vehicle:'Bike',
    stops:[stop,{lat:22.586,lng:88.363,text:'College Street'}]}),200,x=>x.stops.length===2&&x.km>0);
  check('guest requires valid phone',await call('/v1/fare/estimate','POST',
    {pickup,drop,vehicle:'Bike',guest:{name:'Friend',phone:'1234'}}),400);
  check('guest ride quote',await call('/v1/fare/estimate','POST',
    {pickup,drop,vehicle:'Bike',guest:{name:'Friend',phone:'9876543210'}}),200);
  check('shared Cab preview',await call('/v1/fare/estimate','POST',
    {pickup,drop,vehicle:'Cab',mode:'shared_preview'}),200,x=>x.service_mode==='shared_preview');
  check('shared Bike rejected',await call('/v1/fare/estimate','POST',
    {pickup,drop,vehicle:'Bike',mode:'shared_preview'}),400);
  check('intercity distance required',await call('/v1/fare/estimate','POST',
    {pickup,drop,vehicle:'Cab',mode:'intercity'}),400);
  check('intercity quote',await call('/v1/fare/estimate','POST',{pickup,
    drop:{lat:22.9,lng:88.3,text:'Barrackpore'},vehicle:'Cab',mode:'intercity'}),200);
  check('customer cannot create promotion',await call('/v1/admin/promotions','POST',{},'customer'),403);
  const promo=check('create promotion',await call('/v1/admin/promotions','POST',{
    code:'QA'+suffix.toUpperCase(),title:'QA discount',discount_type:'flat',amount:20,
    max_discount:20,max_redemptions:2,starts_at:new Date(Date.now()-60000).toISOString(),
    ends_at:new Date(Date.now()+3600000).toISOString()},'admin'),201).promotion;
  check('enable promotion',await call('/v1/admin/promotions/'+promo.id,'PATCH',{active:true,reason:'QA test'},'admin'),200);
  check('promo quote',await call('/v1/fare/estimate','POST',
    {pickup,drop,vehicle:'Bike',promo_code:promo.code}),200,x=>x.rider_fare_rupees-x.rupees===20);
  check('rider online',await call('/v1/rider/online','POST',{online:true,lat:pickup.lat,lng:pickup.lng},'rider'),200);
  check('bad destination filter',await call('/v1/rider/destination-filter','PATCH',{destination:{lat:300,lng:88,text:'Bad'}},'rider'),400);
  check('set destination filter',await call('/v1/rider/destination-filter','PATCH',
    {destination:{lat:22.65,lng:88.37,text:'North Kolkata'}},'rider'),200);
  check('clear destination filter',await call('/v1/rider/destination-filter','PATCH',{destination:null},'rider'),200);
  const ride=await makeRide({stops:[stop],guest:{name:'Guest Rider',phone:'9876543210'},promo_code:promo.code});
  const id=ride.trip.id;
  check('rider sees guest and route',await call('/v1/trips/'+id,'GET',undefined,'rider'),200,
    x=>x.trip.customer_phone==='9876543210'&&x.trip.guest_name==='Guest Rider'&&x.trip.stops.length===1);
  check('pickup is first target',await call('/v1/trips/'+id+'/route?lat=22.57&lng=88.36','GET',undefined,'rider'),200,
    x=>Number(x.target.lat)===pickup.lat);
  check('stop before PIN denied',await call('/v1/trips/'+id+'/stops/arrive','POST',{},'rider'),409);
  check('arrive',await call('/v1/trips/'+id+'/arrived','POST',{},'rider'),200);
  check('start',await call('/v1/trips/'+id+'/start','POST',{pin:ride.pin},'rider'),200);
  check('next target is stop',await call('/v1/trips/'+id+'/route?lat=22.57&lng=88.36','GET',undefined,'rider'),200,
    x=>Number(x.target.lat)===stop.lat&&x.stop_index===0);
  check('completion blocked at stop',await call('/v1/trips/'+id+'/complete','POST',{},'rider'),409);
  check('mark stop',await call('/v1/trips/'+id+'/stops/arrive','POST',{},'rider'),200,x=>x.remaining===0);
  check('next target is drop',await call('/v1/trips/'+id+'/route?lat=22.58&lng=88.355','GET',undefined,'rider'),200,
    x=>Number(x.target.lat)===drop.lat);
  check('complete discounted trip with 20% final-fare fee',await call('/v1/trips/'+id+'/complete','POST',{},'rider'),200,
    x=>Number(x.trip.final_rupees)-Number(x.trip.customer_final_rupees)===20&&
      Number(x.trip.platform_fee_rupees)===Math.round(Number(x.trip.customer_final_rupees)*.2)&&
      Number(x.trip.rider_earnings_rupees)===Number(x.trip.final_rupees)-Math.round(Number(x.trip.final_rupees)*.2));
  check('rider receipt shows fee and earnings',await call('/v1/trips/'+id,'GET',undefined,'rider'),200,
    x=>Number(x.trip.platform_fee_rupees)===Math.round(Number(x.trip.customer_final_rupees)*.2)&&
      Number(x.trip.promotion_topup_rupees)>0&&x.trip.settlement_status==='pending');
  check('customer cannot view operator settlements',await call('/v1/admin/settlements','GET',undefined,'customer'),403);
  const settlement=check('admin sees pending commission ledger',await call('/v1/admin/settlements','GET',undefined,'admin'),200,
    x=>x.settlements.some(s=>s.trip_id===id&&s.status==='pending')).settlements.find(s=>s.trip_id===id);
  check('settlement arithmetic', {status:200,data:settlement},200,s=>
    Number(s.customer_due_rupees)===Number(s.platform_fee_rupees)+Number(s.rider_earnings_rupees)-Number(s.promotion_topup_rupees)&&
    Number(s.net_due_to_platform_rupees)===Number(s.customer_due_rupees)-Number(s.rider_earnings_rupees));
  const redemption=check('subsidy pending',await call('/v1/admin/promo-redemptions','GET',undefined,'admin'),200,
    x=>x.redemptions.some(r=>r.trip_id===id&&r.subsidy_status==='pending')).redemptions.find(r=>r.trip_id===id);
  check('manual settlement needs reason',await call('/v1/admin/promo-redemptions/'+redemption.id+'/settle','POST',{},'admin'),400);
  check('manual settlement',await call('/v1/admin/promo-redemptions/'+redemption.id+'/settle','POST',
    {reason:'QA mock settlement'},'admin'),200);
  check('legacy subsidy settlement syncs trip ledger',await call('/v1/admin/settlements','GET',undefined,'admin'),200,
    x=>x.settlements.some(s=>s.trip_id===id&&s.status==='settled'));
  const secondPromo=await makeRide({promo_code:promo.code});
  check('second promo arrive',await call('/v1/trips/'+secondPromo.trip.id+'/arrived','POST',{},'rider'),200);
  check('second promo start',await call('/v1/trips/'+secondPromo.trip.id+'/start','POST',
    {pin:secondPromo.pin},'rider'),200);
  check('second promo complete',await call('/v1/trips/'+secondPromo.trip.id+'/complete','POST',{},'rider'),200);
  check('promo cap blocks third quote',await call('/v1/fare/estimate','POST',
    {pickup,drop,vehicle:'Bike',promo_code:promo.code}),409,x=>x.code==='invalid_promotion');
  check('disable promotion',await call('/v1/admin/promotions/'+promo.id,'PATCH',
    {active:false,reason:'QA complete'},'admin'),200);
  const flexPromo=check('create final-fare promotion',await call('/v1/admin/promotions','POST',{
    code:'LOW'+suffix.toUpperCase(),title:'Final fare QA',discount_type:'flat',amount:100,
    max_discount:100,max_redemptions:1,starts_at:new Date(Date.now()-60000).toISOString(),
    ends_at:new Date(Date.now()+3600000).toISOString()},'admin'),201).promotion;
  check('enable final-fare promotion',await call('/v1/admin/promotions/'+flexPromo.id,'PATCH',
    {active:true,reason:'QA final fare'},'admin'),200);
  const flexRide=await makeRide({promo_code:flexPromo.code});
  check('final-fare arrive',await call('/v1/trips/'+flexRide.trip.id+'/arrived','POST',{},'rider'),200);
  check('final-fare start',await call('/v1/trips/'+flexRide.trip.id+'/start','POST',
    {pin:flexRide.pin},'rider'),200);
  const flexDone=check('final-fare complete',await call('/v1/trips/'+flexRide.trip.id+'/complete','POST',
    {final_km:0.1},'rider'),200,x=>Number(x.trip.platform_fee_rupees)===Math.round(Number(x.trip.customer_final_rupees)*.2)).trip;
  check('subsidy uses final discount',await call('/v1/admin/promo-redemptions','GET',undefined,'admin'),200,
    x=>x.redemptions.some(r=>r.trip_id===flexRide.trip.id&&
      Number(r.discount_rupees)===Number(flexDone.final_rupees)-Number(flexDone.customer_final_rupees)));
  check('new settlement needs reason',await call('/v1/admin/settlements/'+flexRide.trip.id+'/settle','POST',{},'admin'),400);
  check('new settlement endpoint',await call('/v1/admin/settlements/'+flexRide.trip.id+'/settle','POST',
    {reason:'QA external transfer receipt'},'admin'),200);
  check('settlement cannot be repeated',await call('/v1/admin/settlements/'+flexRide.trip.id+'/settle','POST',
    {reason:'QA duplicate'},'admin'),409);
  const ticket=check('support case',await call('/v1/tickets','POST',
    {subject:'QA safety case',message:'Please review',trip_id:id},'customer'),201).ticket;
  check('triage support case',await call('/v1/admin/tickets/'+ticket.id,'PATCH',
    {priority:'urgent',category:'safety',assigned_to:admin.id,status:'in_progress'},'admin'),200,
    x=>x.ticket.priority==='urgent'&&x.ticket.assigned_to===admin.id);
  check('resolve case',await call('/v1/admin/tickets/'+ticket.id,'PATCH',
    {status:'resolved',resolution:'QA resolved'},'admin'),200,x=>x.ticket.status==='resolved');
  const time=new Date(Date.now()+30*60000).toISOString();
  const scheduled=check('schedule ride',await call('/v1/scheduled','POST',
    {pickup,drop,vehicle:'Bike',scheduled_for:time,confirmed:true},'customer'),201).scheduled;
  check('scheduled visible to customer',await call('/v1/scheduled','GET',undefined,'customer'),200,
    x=>x.scheduled.some(s=>s.id===scheduled.id));
  check('scheduled visible to admin',await call('/v1/admin/scheduled','GET',undefined,'admin'),200,
    x=>x.scheduled.some(s=>s.id===scheduled.id));
  check('cancel scheduled ride',await call('/v1/scheduled/'+scheduled.id+'/cancel','POST',{},'customer'),200);
  for(let i=0;i<3;i++){
    const r=await makeRide();
    check('rider self-cancel '+(i+1),await call('/v1/trips/'+r.trip.id+'/cancel','POST',
      {reason:'QA self cancel'},'rider'),200);
    check('cancel quota '+(i+1),await call('/v1/rider/cancellations','GET',undefined,'rider'),200,
      x=>x.used===i+1&&x.remaining===2-i);
  }
  const fourth=await makeRide();
  check('fourth self-cancel denied',await call('/v1/trips/'+fourth.trip.id+'/cancel','POST',
    {reason:'QA fourth'},'rider'),429,x=>x.code==='rider_cancel_limit');
  check('customer can cancel',await call('/v1/trips/'+fourth.trip.id+'/cancel','POST',
    {reason:'QA cleanup'},'customer'),200);
  const noShow=await makeRide();
  check('arrive after quota',await call('/v1/trips/'+noShow.trip.id+'/arrived','POST',{},'rider'),200);
  await sql`update trips set arrived_at=now()-interval '6 minutes' where id=${noShow.trip.id}::uuid`;
  check('no-show after quota allowed',await call('/v1/trips/'+noShow.trip.id+'/no-show','POST',{},'rider'),200);
  check('no-show does not consume quota',await call('/v1/rider/cancellations','GET',undefined,'rider'),200,
    x=>x.used===3&&x.remaining===0);
  console.log('Feature expansion checks passed: '+checks);
}finally{
  await call('/v1/rider/online','POST',{online:false},'rider').catch(()=>{});
}
