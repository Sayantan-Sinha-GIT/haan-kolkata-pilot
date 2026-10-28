import { createHmac, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { neon } from '@neondatabase/serverless';

const vars = Object.fromEntries(readFileSync(new URL('../worker/.dev.vars', import.meta.url), 'utf8')
  .split(/\r?\n/).filter(x => /^[A-Z_]+=/.test(x))
  .map(x => [x.slice(0, x.indexOf('=')), x.slice(x.indexOf('=') + 1)]));
if (new URL(vars.DATABASE_URL).hostname !== 'ep-bold-sea-b3lygotf-pooler.c-4.ap-southeast-1.aws.neon.tech')
  throw new Error('Refusing non-development database');
const sql = neon(vars.DATABASE_URL);
const base = 'http://127.0.0.1:8787';
const suffix = randomUUID().slice(0, 8);
const pickup = {lat: 22.5726, lng: 88.3639, text: 'Esplanade Kolkata'};
const drop = {lat: 22.5839, lng: 88.3425, text: 'Victoria Memorial Kolkata'};
const ids = [];
let customer, rider, checks = 0;
const token = user => {
  const p = Buffer.from(JSON.stringify({sub: user.id, role: user.role,
    exp: Math.floor(Date.now() / 1000) + 3600})).toString('base64url');
  return p + '.' + createHmac('sha256', vars.SESSION_SECRET).update(p).digest('hex');
};
async function call(path, method = 'GET', payload, who) {
  const response = await fetch(base + path, {method, headers: {
    ...(who ? {Authorization: `Bearer ${token(who)}`} : {}),
    ...(payload ? {'Content-Type': 'application/json'} : {})
  }, body: payload ? JSON.stringify(payload) : undefined, signal: AbortSignal.timeout(30000)});
  return {status: response.status, data: await response.json()};
}
function check(label, result, status, predicate = () => true) {
  checks++;
  if (result.status !== status || !predicate(result.data))
    throw new Error(`${label}: ${result.status} ${JSON.stringify(result.data).slice(0, 500)}`);
  console.log(`PASS ${label}`);
  return result.data;
}
async function newRide() {
  const data = check('create ride', await call('/v1/trips', 'POST',
    {pickup, drop, vehicle: 'Bike', confirmed: true}, customer), 201,
    x => /^\d{4}$/.test(x.pin));
  ids.push(data.trip.id);
  return data;
}
async function offerFor(id) {
  const data = check('rider offer list', await call('/v1/rider/offers', 'GET', undefined, rider),
    200, x => x.offers.some(o => o.trip_id === id));
  return data.offers.find(o => o.trip_id === id);
}
try {
  const [source] = await sql`select rp.* from rider_profiles rp join users u on u.id=rp.user_id
    where u.email='rider.demo@haan.invalid' and rp.verification_status='approved'`;
  if (!source) throw new Error('Development rider fixture missing');
  [customer] = await sql`insert into users(role,email,name,phone)
    values('customer',${`qa-bump-${suffix}@haan.invalid`},'Fare bump QA','9123456789') returning id,role`;
  [rider] = await sql`insert into users(role,email,name,phone)
    values('rider',${`qa-bump-rider-${suffix}@haan.invalid`},'Fare bump Rider','9876543210') returning id,role`;
  await sql`insert into rider_profiles(user_id,vehicle_type,vehicle_number,vehicle_make,vehicle_model,
    vehicle_color,vehicle_year,licence_number,insurance_expiry,permit_expiry,licence_key,rc_key,
    selfie_key,insurance_key,permit_key,verification_status)
    values(${rider.id}::uuid,'Bike',${source.vehicle_number},${source.vehicle_make},
      ${source.vehicle_model},${source.vehicle_color},${source.vehicle_year},${source.licence_number},
      ${source.insurance_expiry},${source.permit_expiry},${source.licence_key},${source.rc_key},
      ${source.selfie_key},${source.insurance_key},${source.permit_key},'approved')`;
  check('rider online', await call('/v1/rider/online', 'POST',
    {online: true, lat: pickup.lat, lng: pickup.lng}, rider), 200);

  const ride = await newRide();
  const first = await offerFor(ride.trip.id);
  check('reject malformed increase', await call(`/v1/trips/${ride.trip.id}/increase-fare`,
    'POST', {increment: 5}, customer), 400);
  check('reject missing cancellation reason', await call(`/v1/trips/${ride.trip.id}/cancel`,
    'POST', {}, customer), 400);
  const raised = check('restart search at +₹20', await call(`/v1/trips/${ride.trip.id}/increase-fare`,
    'POST', {increment: 20}, customer), 200,
    x => Number(x.trip.estimate_rupees) === Number(ride.trip.estimate_rupees) + 20
      && x.trip.fare_bump_count === 1 && x.trip.customer_fare_bump_rupees === 20);
  check('old offer cannot be accepted', await call(`/v1/rider/offers/${first.id}/accept`,
    'POST', {}, rider), 409);
  const second = await offerFor(ride.trip.id);
  if (second.id === first.id || Number(second.estimate_rupees) !== Number(raised.trip.estimate_rupees))
    throw new Error('New search did not issue a fresh higher-fare offer');
  checks++; console.log('PASS fresh higher-fare offer');
  check('second fare increase', await call(`/v1/trips/${ride.trip.id}/increase-fare`,
    'POST', {increment: 10}, customer), 200, x => x.trip.fare_bump_count === 2);
  check('third fare increase', await call(`/v1/trips/${ride.trip.id}/increase-fare`,
    'POST', {increment: 10}, customer), 200, x => x.trip.fare_bump_count === 3);
  check('fourth increase denied', await call(`/v1/trips/${ride.trip.id}/increase-fare`,
    'POST', {increment: 10}, customer), 409);
  const third = await offerFor(ride.trip.id);
  check('accept latest offer', await call(`/v1/rider/offers/${third.id}/accept`,
    'POST', {}, rider), 200);
  check('increase after acceptance denied', await call(`/v1/trips/${ride.trip.id}/increase-fare`,
    'POST', {increment: 10}, customer), 409);
  check('cancel after acceptance', await call(`/v1/trips/${ride.trip.id}/cancel`,
    'POST', {reason: 'QA customer choice'}, customer), 200);
  check('accepted cancellation appears in trips', await call('/v1/trips/history',
    'GET', undefined, customer), 200, x => x.trips.some(t => t.id === ride.trip.id));

  const unmatched = await newRide();
  await sql`update trips set status='no_riders_found' where id=${unmatched.trip.id}::uuid`;
  check('unmatched request stays out of Trips', await call('/v1/trips/history',
    'GET', undefined, customer), 200, x => !x.trips.some(t => t.id === unmatched.trip.id));
  const preaccept = await newRide();
  check('cancel before acceptance', await call(`/v1/trips/${preaccept.trip.id}/cancel`,
    'POST', {reason: 'QA changed plans'}, customer), 200);
  check('preaccept cancellation stays out of Trips', await call('/v1/trips/history',
    'GET', undefined, customer), 200, x => !x.trips.some(t => t.id === preaccept.trip.id));

  const completed = await newRide();
  check('raise completed trip fare', await call(`/v1/trips/${completed.trip.id}/increase-fare`,
    'POST', {increment: 30}, customer), 200);
  const finalOffer = await offerFor(completed.trip.id);
  check('accept final offer', await call(`/v1/rider/offers/${finalOffer.id}/accept`,
    'POST', {}, rider), 200);
  check('arrive', await call(`/v1/trips/${completed.trip.id}/arrived`, 'POST', {}, rider), 200);
  check('start with PIN', await call(`/v1/trips/${completed.trip.id}/start`, 'POST',
    {pin: completed.pin}, rider), 200);
  const done = check('finish raised-fare trip', await call(`/v1/trips/${completed.trip.id}/complete`,
    'POST', {}, rider), 200, x => Number(x.trip.platform_fee_rupees)
      === Math.round(Number(x.trip.customer_final_rupees) * .2));
  const [config] = await sql`select base,per_km,per_min,minimum from fare_config where vehicle_type='Bike'`;
  const [finished] = await sql`select final_km,duration_min,estimate_rupees,customer_fare_bump_rupees
    from trips where id=${completed.trip.id}::uuid`;
  const metered = Math.round(Math.max(Number(config.minimum), Number(config.base)
    + Number(config.per_km) * Number(finished.final_km)
    + Number(config.per_min) * Number(finished.duration_min)));
  const expected = Math.min(metered + 30, Math.round(Number(finished.estimate_rupees) * 1.5));
  if (Number(done.trip.final_rupees) !== expected) throw new Error('Final fare omitted customer increase');
  checks++; console.log('PASS final fare includes increase');
  check('customer rates rider', await call(`/v1/trips/${completed.trip.id}/rating`,
    'POST', {stars: 5}, customer), 200);
  check('rider rates customer', await call(`/v1/trips/${completed.trip.id}/rating`,
    'POST', {stars: 4}, rider), 200);
  check('customer rating visible on receipt', await call(`/v1/trips/${completed.trip.id}`,
    'GET', undefined, customer), 200, x => x.trip.my_rating_stars === 5);
  check('rider rating visible on receipt', await call(`/v1/trips/${completed.trip.id}`,
    'GET', undefined, rider), 200, x => x.trip.my_rating_stars === 4);
  check('duplicate rating denied', await call(`/v1/trips/${completed.trip.id}/rating`,
    'POST', {stars: 3}, rider), 409);
  for (let i = 0; i < 10; i++) {
    await call('/v1/rider/heartbeat', 'POST', {lat: pickup.lat, lng: pickup.lng}, rider);
    const contested = await newRide();
    const pending = await offerFor(contested.trip.id);
    const [increase, accept] = await Promise.all([
      call(`/v1/trips/${contested.trip.id}/increase-fare`, 'POST', {increment: 20}, customer),
      call(`/v1/rider/offers/${pending.id}/accept`, 'POST', {}, rider),
    ]);
    if (!((increase.status === 200 && accept.status === 409)
      || (increase.status === 409 && accept.status === 200)))
      throw new Error(`Fare/accept race ${i + 1}: ${increase.status}/${accept.status}`);
    checks++; console.log(`PASS fare/accept race ${i + 1}`);
    check('race cleanup cancellation', await call(`/v1/trips/${contested.trip.id}/cancel`,
      'POST', {reason: 'QA race complete'}, customer), 200);
  }
  console.log(`Fare increase checks passed: ${checks}`);
} finally {
  if (rider) await call('/v1/rider/online', 'POST', {online: false}, rider).catch(() => {});
  for (const id of ids) {
    await sql`delete from ratings where trip_id=${id}::uuid`;
    await sql`delete from trip_settlements where trip_id=${id}::uuid`;
    await sql`delete from trip_locations where trip_id=${id}::uuid`;
    await sql`delete from trip_offers where trip_id=${id}::uuid`;
    await sql`delete from trips where id=${id}::uuid`;
  }
  if (rider) await sql`delete from rider_profiles where user_id=${rider.id}::uuid`;
  if (rider) await sql`delete from users where id=${rider.id}::uuid`;
  if (customer) await sql`delete from users where id=${customer.id}::uuid`;
}
