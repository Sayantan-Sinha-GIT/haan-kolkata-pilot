import { createHmac, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { neon } from '@neondatabase/serverless';

const vars = Object.fromEntries(readFileSync(new URL('../worker/.dev.vars', import.meta.url), 'utf8').split(/\r?\n/)
  .filter(line => /^[A-Z_]+=/.test(line)).map(line => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]));
if(new URL(vars.DATABASE_URL).hostname!=='ep-bold-sea-b3lygotf-pooler.c-4.ap-southeast-1.aws.neon.tech')throw new Error('Development database host mismatch');
const sql = neon(vars.DATABASE_URL);
const [rider] = await sql`select u.id,u.role from users u join rider_profiles rp on rp.user_id=u.id where u.email='rider.demo@haan.invalid' and rp.verification_status='approved'`;
if (!rider) throw new Error('Development fixture missing; refusing test writes');
const email = `qa-${randomUUID()}@haan.invalid`;
const [customer] = await sql`insert into users(email,role,name) values(${email},'customer','QA customer') returning id,role`;
const token = user => {
  const payload = Buffer.from(JSON.stringify({ sub: user.id, role: user.role, exp: Math.floor(Date.now()/1000)+900 })).toString('base64url');
  return `${payload}.${createHmac('sha256',vars.SESSION_SECRET).update(payload).digest('hex')}`;
};
const customerToken = token(customer), riderToken = token(rider);
const base = 'http://127.0.0.1:8787';
let checks = 0;
async function call(path, method = 'GET', body, auth) {
  const response = await fetch(base + path, { method, headers: { ...(auth ? { Authorization: `Bearer ${auth}` } : {}), ...(body ? { 'Content-Type': 'application/json' } : {}) }, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(25000) });
  return { status: response.status, data: await response.json() };
}
async function expectStatus(label, actual, status, predicate = () => true) {
  checks++;
  if (actual.status !== status || !predicate(actual.data)) throw new Error(`${label}: expected ${status}, got ${actual.status}, code ${actual.data?.code || 'none'}`);
  console.log(`PASS ${label}`);
  return actual.data;
}
const pickup = { lat: 22.5726, lng: 88.3639, text: 'Esplanade Kolkata' };
const drop = { lat: 22.5839, lng: 88.3425, text: 'Victoria Memorial Kolkata' };
try {
  await expectStatus('health', await call('/health'), 200, data => data.ok === true);
  await expectStatus('anonymous profile denied', await call('/v1/profile'), 401);
  await expectStatus('role boundary', await call('/v1/rider/profile', 'GET', undefined, customerToken), 403);
  await expectStatus('bad fare coordinates', await call('/v1/fare/estimate','POST',{pickup:{...pickup,lat:200},drop,vehicle:'Bike'}),400);
  await expectStatus('too-short trip', await call('/v1/fare/estimate','POST',{pickup,drop:{...pickup,lat:22.573},vehicle:'Bike'}),400);
  for (const vehicle of ['Bike','Auto','Cab']) {
    await expectStatus(`${vehicle} fare`, await call('/v1/fare/estimate','POST',{pickup,drop,vehicle}),200,data => data.rupees>0 && data.km>0 && ['ola','straight_line_fallback'].includes(data.route_source));
  }
  await expectStatus('booking requires confirmation', await call('/v1/trips','POST',{pickup,drop,vehicle:'Bike'},customerToken),400);
  await expectStatus('invalid rider GPS denied', await call('/v1/rider/online','POST',{online:true,lat:100,lng:88.3},riderToken),400);
  await expectStatus('rider online', await call('/v1/rider/online','POST',{online:true,lat:22.5726,lng:88.3639},riderToken),200,data=>data.online===true);
  await expectStatus('invalid heartbeat denied', await call('/v1/rider/heartbeat','POST',{lat:22.57,lng:200},riderToken),400);
  await expectStatus('valid heartbeat', await call('/v1/rider/heartbeat','POST',{lat:22.5726,lng:88.3639},riderToken),200);
  const created = await expectStatus('trip created', await call('/v1/trips','POST',{pickup,drop,vehicle:'Bike',confirmed:true},customerToken),201,data=>/^\d{4}$/.test(data.pin));
  const id = created.trip.id;
  await expectStatus('second active trip blocked', await call('/v1/trips','POST',{pickup,drop,vehicle:'Bike',confirmed:true},customerToken),409);
  const offers = await expectStatus('offer listed', await call('/v1/rider/offers','GET',undefined,riderToken),200,data=>data.offers.some(x=>x.trip_id===id));
  const offer = offers.offers.find(x=>x.trip_id===id);
  await expectStatus('offer accepted', await call(`/v1/rider/offers/${offer.id}/accept`,'POST',{},riderToken),200);
  await expectStatus('double accept denied', await call(`/v1/rider/offers/${offer.id}/accept`,'POST',{},riderToken),409);
  await expectStatus('PIN before arrival denied', await call(`/v1/trips/${id}/start`,'POST',{pin:created.pin},riderToken),409);
  await expectStatus('arrived', await call(`/v1/trips/${id}/arrived`,'POST',{},riderToken),200);
  await expectStatus('wrong PIN counted', await call(`/v1/trips/${id}/start`,'POST',{pin:created.pin==='0000'?'1111':'0000'},riderToken),400,data=>data.attempts_left===4);
  await expectStatus('correct PIN starts', await call(`/v1/trips/${id}/start`,'POST',{pin:created.pin},riderToken),200);
  await expectStatus('invalid heading denied', await call(`/v1/trips/${id}/location`,'POST',{lat:22.575,lng:88.36,heading:400},riderToken),400);
  await expectStatus('location accepted', await call(`/v1/trips/${id}/location`,'POST',{lat:22.575,lng:88.36,heading:90},riderToken),200);
  await expectStatus('trip visible to customer', await call(`/v1/trips/${id}`,'GET',undefined,customerToken),200,data=>data.trip.status==='in_progress' && Number(data.location.lat)===22.575);
  const shared = await expectStatus('trip share link', await call(`/v1/trips/${id}/share`,'GET',undefined,customerToken),200,data=>data.url?.includes('/trip.html'));
  const sharedUrl = new URL(shared.url);
  await expectStatus('anonymous signed share', await call(`/v1/shared/${id}${sharedUrl.search}`),200,data=>data.status==='in_progress');
  const badSig = new URLSearchParams(sharedUrl.search); badSig.set('sig','0'.repeat(64));
  await expectStatus('invalid share signature denied', await call(`/v1/shared/${id}?${badSig}`),404);
  await expectStatus('trip completed', await call(`/v1/trips/${id}/complete`,'POST',{final_km:1000},riderToken),200,data=>Number(data.trip.final_rupees)<=Number(created.trip.estimate_rupees)*1.5+0.5);
  await expectStatus('double completion denied', await call(`/v1/trips/${id}/complete`,'POST',{},riderToken),409);
  await expectStatus('customer rating', await call(`/v1/trips/${id}/rating`,'POST',{stars:5,comment:'QA'},customerToken),200);
  await expectStatus('duplicate rating denied', await call(`/v1/trips/${id}/rating`,'POST',{stars:5},customerToken),409);
  await expectStatus('customer history', await call('/v1/trips/history','GET',undefined,customerToken),200,data=>data.trips.some(x=>x.id===id));
  const ticket = await expectStatus('support ticket', await call('/v1/tickets','POST',{subject:'QA test',message:'Trip flow verified',trip_id:id},customerToken),201);
  await expectStatus('ticket visible', await call(`/v1/tickets/${ticket.ticket.id}`,'GET',undefined,customerToken),200,data=>data.messages.length===1);
  const second = await expectStatus('second trip created', await call('/v1/trips','POST',{pickup,drop,vehicle:'Bike',confirmed:true},customerToken),201);
  const secondId = second.trip.id;
  await expectStatus('active trip blocks deletion', await call('/v1/profile','DELETE',undefined,customerToken),409);
  const secondOffers = await expectStatus('second offer listed', await call('/v1/rider/offers','GET',undefined,riderToken),200,data=>data.offers.some(x=>x.trip_id===secondId));
  const secondOffer = secondOffers.offers.find(x=>x.trip_id===secondId);
  await expectStatus('second offer accepted', await call(`/v1/rider/offers/${secondOffer.id}/accept`,'POST',{},riderToken),200);
  await expectStatus('second trip arrived', await call(`/v1/trips/${secondId}/arrived`,'POST',{},riderToken),200);
  const wrongPin = second.pin === '0000' ? '1111' : '0000';
  for (let attempt=1;attempt<=5;attempt++) {
    await expectStatus(`wrong PIN attempt ${attempt}`, await call(`/v1/trips/${secondId}/start`,'POST',{pin:wrongPin},riderToken),400,data=>data.attempts_left===5-attempt);
  }
  await expectStatus('correct PIN rejected after lock', await call(`/v1/trips/${secondId}/start`,'POST',{pin:second.pin},riderToken),423);
  await expectStatus('customer cancels locked trip', await call(`/v1/trips/${secondId}/cancel`,'POST',{reason:'PIN locked QA'},customerToken),200);
  await expectStatus('completed trip cannot be cancelled', await call(`/v1/trips/${id}/cancel`,'POST',{reason:'too late'},customerToken),409);
  await expectStatus('account deletion', await call('/v1/profile','DELETE',undefined,customerToken),200);
  console.log(`PASS ${checks} development API checks`);
} finally {
  await call('/v1/rider/online','POST',{online:false},riderToken).catch(()=>{});
}
