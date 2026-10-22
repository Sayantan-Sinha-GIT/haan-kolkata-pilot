import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { db, consumeLimit } from './db';
import { hmac, randomDigits, randomToken, signAccess, verifyAccess, verifyPassword, decryptTotp, verifyTotp, passwordHash, newTotpSecret, encryptTotp, totpSetupKey } from './crypto';
import { fare, haversineKm, validPoint, scrubAssistantText, type Vehicle } from './rules';
import { advanceMatch } from './matching';
import { assistantIntent, broadcast, routeEstimate, searchPlaces, sendEmail, transcribe, TripRoom } from './services';
import { sendPush } from './push';
import type { App, Env, Principal } from './types';

export { TripRoom };
const api = new Hono<App>();
const error = (message: string, code: string, status = 400) => Response.json({ error: message, code }, { status });
const ip = (req: Request) => req.headers.get('CF-Connecting-IP') || '127.0.0.1';
const emailOk = (s: unknown): s is string => typeof s === 'string' && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s) && s.length <= 254;
const uuidOk = (s: unknown): s is string => typeof s === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
const body = async <T>(request: Request): Promise<T> => {
  try { return await request.json() as T; }
  catch { return {} as T; }
};

async function principal(env: Env, request: Request): Promise<Principal | null> {
  const token = request.headers.get('authorization')?.replace(/^Bearer\s+/i, '') || '';
  const claim = await verifyAccess(env.SESSION_SECRET, token);
  if (!claim || !uuidOk(claim.sub)) return null;
  const [user] = await db(env)`select id,role,email,is_blocked from users where id=${claim.sub}::uuid and deleted_at is null`;
  return user && !user.is_blocked ? user as Principal : null;
}
async function requireRole(env: Env, request: Request, roles: Principal['role'][]): Promise<Principal | Response> {
  const user = await principal(env, request);
  if (!user) return error('Please sign in again.', 'not_signed_in', 401);
  if (!roles.includes(user.role)) return error('You cannot access this.', 'forbidden', 403);
  if (user.role === 'super_admin' || user.role === 'support_agent') {
    const sql = db(env);
    const activity = await sql`update admin_activity set last_seen_at=now() where user_id=${user.id}::uuid
      and last_seen_at>now()-interval '30 minutes' returning id`;
    if (!activity.length) return error('Admin session expired. Sign in again.', 'admin_idle_timeout', 401);
  }
  return user;
}
const isResponse = (v: Principal | Response): v is Response => v instanceof Response;
async function audit(env: Env, admin: Principal, action: string, entity: string, details: unknown, req: Request) {
  await db(env)`insert into admin_audit_log(admin_id,action,entity,details,ip) values(${admin.id}::uuid,${action},${entity},${JSON.stringify(details)}::jsonb,${ip(req)}::inet)`;
}
async function issueTokens(env: Env, user: Principal, device: string) {
  const refresh = randomToken();
  await db(env)`insert into sessions(user_id,refresh_token_hash,device,expires_at) values
    (${user.id}::uuid,${await hmac(env.SESSION_SECRET, refresh)},${device.slice(0,100)},now()+interval '30 days')`;
  return { access_token: await signAccess(env.SESSION_SECRET, user), refresh_token: refresh, user };
}

const allowedOrigin = (origin: string, expected: string) => origin === expected || /^http:\/\/(localhost|127\.0\.0\.1):\d+$/.test(origin);
api.use('*', async (c, next) => {
  const origin = c.req.header('Origin');
  if (origin && !allowedOrigin(origin,c.env.APP_ORIGIN)) return error('Origin not allowed.', 'origin_denied', 403);
  await next();
});
api.use('*', cors({ origin: (origin, c) => allowedOrigin(origin,c.env.APP_ORIGIN) ? origin : '', allowHeaders: ['Authorization','Content-Type'], allowMethods: ['GET','POST','PATCH','DELETE','OPTIONS'] }));
api.get('/health', c => c.json({ ok: true, service: 'haan-api' }));
api.get('/api/version', c => c.json({ commit: 'local' }));

api.post('/v1/auth/request-otp', async c => {
  const input = await body<{ email?: string; role?: string }>(c.req.raw);
  const email = input.email?.trim().toLowerCase();
  if (!emailOk(email) || !['customer','rider'].includes(input.role || 'customer')) return error('Enter a valid email.', 'invalid_email');
  if (!await consumeLimit(c.env, `otp:email:${email}`, 3, 60) || !await consumeLimit(c.env, `otp:ip:${ip(c.req.raw)}`, 10, 60)) return error('Please try again later.', 'rate_limited', 429);
  const sql = db(c.env);
  const [recent] = await sql`select created_at from otp_codes where email=${email} order by created_at desc limit 1`;
  if (recent && Date.now() - new Date(recent.created_at).getTime() < 30_000) return error('Wait 30 seconds before requesting another code.', 'resend_cooldown', 429);
  const code = randomDigits(6);
  const hash = await hmac(c.env.SESSION_SECRET, `${email}:${code}`);
  if (!await sendEmail(c.env, email, 'Your Haan sign-in code', `Your code is ${code}. It expires in 10 minutes.`)) return error('Email is temporarily unavailable. Please try later.', 'email_unavailable', 503);
  await sql`insert into otp_codes(email,code_hash,expires_at,sent_ip) values(${email},${hash},now()+interval '10 minutes',${ip(c.req.raw)}::inet)`;
  return c.json({ ok: true, expires_in_seconds: 600, resend_after_seconds: 30 });
});

api.post('/v1/auth/verify-otp', async c => {
  const input = await body<{ email?: string; code?: string; role?: 'customer'|'rider'; device?: string }>(c.req.raw);
  const email = input.email?.trim().toLowerCase();
  if (!emailOk(email) || !/^\d{6}$/.test(input.code || '') || !['customer','rider'].includes(input.role || '')) return error('Check the email and code.', 'invalid_input');
  const sql = db(c.env);
  const [otp] = await sql`select id,code_hash,expires_at,attempts,consumed_at from otp_codes where email=${email} order by created_at desc limit 1`;
  if (!otp || otp.consumed_at || new Date(otp.expires_at).getTime() < Date.now()) return error('The code expired. Request a new one.', 'expired_code', 400);
  if (Number(otp.attempts) >= 5) return error('Too many tries. Request a new code.', 'too_many_attempts', 429);
  const valid = await hmac(c.env.SESSION_SECRET, `${email}:${input.code}`) === otp.code_hash;
  if (!valid) {
    await sql`update otp_codes set attempts=attempts+1 where id=${otp.id}::uuid`;
    return c.json({ error: 'That code is not right.', code: 'wrong_code', attempts_left: 4 - Number(otp.attempts) }, 400);
  }
  const consumed = await sql`update otp_codes set consumed_at=now() where id=${otp.id}::uuid and consumed_at is null returning id`;
  if (!consumed.length) return error('This code was already used.', 'used_code', 409);
  const users = await sql`insert into users(email,role) values(${email},${input.role}::user_role)
    on conflict(email) do update set updated_at=now() returning id,role,email,is_blocked`;
  const user = users[0] as Principal;
  if (user.role !== input.role || user.is_blocked) return error('This account cannot sign in here.', 'role_mismatch', 403);
  return c.json(await issueTokens(c.env, user, input.device || 'Android'));
});

api.post('/v1/auth/refresh', async c => {
  const input = await body<{ refresh_token?: string; device?: string }>(c.req.raw);
  if (!input.refresh_token) return error('Sign in again.', 'missing_token', 401);
  const sql = db(c.env), hash = await hmac(c.env.SESSION_SECRET, input.refresh_token);
  const [session] = await sql`select s.id,u.id as user_id,u.role,u.email,u.is_blocked from sessions s join users u on u.id=s.user_id
    where s.refresh_token_hash=${hash} and s.expires_at>now() and s.revoked_at is null and u.deleted_at is null`;
  if (!session || session.is_blocked) return error('Sign in again.', 'expired_session', 401);
  const changed = await sql`update sessions set revoked_at=now() where id=${session.id}::uuid and revoked_at is null returning id`;
  if (!changed.length) return error('Sign in again.', 'expired_session', 401);
  return c.json(await issueTokens(c.env, { id: session.user_id, role: session.role, email: session.email, is_blocked: false }, input.device || 'Android'));
});

api.post('/v1/auth/logout', async c => {
  const user = await requireRole(c.env,c.req.raw,['customer','rider','super_admin','support_agent']);
  if (isResponse(user)) return user;
  const input = await body<{ refresh_token?: string }>(c.req.raw);
  if (input.refresh_token) await db(c.env)`update sessions set revoked_at=now() where user_id=${user.id}::uuid and refresh_token_hash=${await hmac(c.env.SESSION_SECRET,input.refresh_token)}`;
  return c.json({ ok: true });
});

api.get('/v1/config', async c => {
  const rows = await db(c.env)`select key,value from app_config where key='minimum_versions'`;
  return c.json({ minimum_versions: rows[0]?.value || { customer: 1, rider: 1 } });
});
api.get('/v1/fares', async c => c.json(await db(c.env)`select vehicle_type,base,per_km,per_min,minimum from fare_config order by vehicle_type`));
api.get('/v1/places/search', async c => {
  const q = (c.req.query('q') || '').trim();
  if (q.length < 3 || q.length > 120) return error('Type at least three letters.', 'invalid_query');
  if (!await consumeLimit(c.env, `places:${ip(c.req.raw)}`, 30, 60)) return error('Please try again shortly.', 'rate_limited', 429);
  return c.json({ places: await searchPlaces(c.env, q) });
});
api.post('/v1/fare/estimate', async c => {
  const input = await body<{ pickup: unknown; drop: unknown; vehicle: Vehicle }>(c.req.raw);
  if (!validPoint(input.pickup) || !validPoint(input.drop) || !['Bike','Auto','Cab'].includes(input.vehicle)) return error('Choose a pickup, destination and vehicle.', 'invalid_trip');
  const direct = haversineKm(input.pickup,input.drop);
  if (direct < 0.3) return error('Choose a destination at least 300 metres away.', 'too_close');
  const route=await routeEstimate(c.env,input.pickup,input.drop,input.vehicle);
  const {km,minutes}=route;
  const [config] = await db(c.env)`select base,per_km,per_min,minimum from fare_config where vehicle_type=${input.vehicle}::vehicle_type`;
  return c.json({ km, minutes, rupees: fare({ base:Number(config.base),per_km:Number(config.per_km),per_min:Number(config.per_min),minimum:Number(config.minimum) },km,minutes), route_source:route.source, polyline:route.polyline||null });
});

api.post('/v1/assistant/parse', async c => {
  const user = await requireRole(c.env,c.req.raw,['customer']); if (isResponse(user)) return user;
  if (!await consumeLimit(c.env,`assistant:${user.id}`,20,60)) return error('The assistant limit has been reached. Please book on the map.', 'assistant_limit',429);
  const input = await body<{ text?: string }>(c.req.raw);
  if (!input.text || input.text.length > 600) return error('Say or type a short trip request.', 'invalid_text');
  const result = await assistantIntent(c.env,input.text);
  if (!result || result.confidence < 0.55) return c.json({ fallback:'manual', message:'I could not understand. Please type or pick on the map.' });
  await db(c.env)`insert into assistant_logs(user_id,language,transcript_text,intent,confidence) values
    (${user.id}::uuid,${result.language},${scrubAssistantText(input.text)},${result.intent},${result.confidence})`;
  return c.json({ ...result, requires_confirmation:true });
});
api.post('/v1/assistant/transcribe', async c => {
  const user = await requireRole(c.env,c.req.raw,['customer']); if (isResponse(user)) return user;
  if (!await consumeLimit(c.env,`assistant-audio:${user.id}`,20,60)) return error('The assistant limit has been reached.', 'assistant_limit',429);
  const form = await c.req.formData(); const audio = form.get('audio');
  if (!(audio instanceof File) || audio.size > 1_000_000) return error('Record up to 15 seconds.', 'invalid_audio');
  const text = await transcribe(c.env,audio);
  return text ? c.json({ text }) : error('Voice is unavailable. Please type or choose on the map.', 'voice_unavailable',503);
});

api.post('/v1/trips', async c => {
  const user = await requireRole(c.env,c.req.raw,['customer']); if (isResponse(user)) return user;
  const input = await body<{ pickup: unknown; drop: unknown; vehicle: Vehicle; confirmed?: boolean; via_assistant?: boolean }>(c.req.raw);
  if (!input.confirmed) return error('Confirm the trip on screen before booking.', 'confirmation_required');
  if (!validPoint(input.pickup) || !validPoint(input.drop) || !['Bike','Auto','Cab'].includes(input.vehicle)) return error('Choose a pickup, destination and vehicle.', 'invalid_trip');
  const direct = haversineKm(input.pickup,input.drop);
  if (direct < 0.3) return error('Choose a destination at least 300 metres away.', 'too_close');
  const route=await routeEstimate(c.env,input.pickup,input.drop,input.vehicle);
  const sql=db(c.env),km=route.km,minutes=route.minutes;
  const [config] = await sql`select base,per_km,per_min,minimum from fare_config where vehicle_type=${input.vehicle}::vehicle_type`;
  const amount=fare({base:Number(config.base),per_km:Number(config.per_km),per_min:Number(config.per_min),minimum:Number(config.minimum)},km,minutes);
  const pin=randomDigits(4),pinHash=await hmac(c.env.SESSION_SECRET,pin);
  try {
    const [trip]=await sql`insert into trips(customer_id,vehicle_type,pickup_lat,pickup_lng,pickup_text,drop_lat,drop_lng,drop_text,estimated_km,estimated_min,estimate_rupees,pin_hash,via_assistant)
      values(${user.id}::uuid,${input.vehicle}::vehicle_type,${input.pickup.lat},${input.pickup.lng},${input.pickup.text.trim()},${input.drop.lat},${input.drop.lng},${input.drop.text.trim()},${km},${minutes},${amount},${pinHash},${!!input.via_assistant})
      returning id,status,estimate_rupees,estimated_km,estimated_min`;
    await advanceMatch(c.env,trip.id);
    const room=c.env.TRIP_ROOM.get(c.env.TRIP_ROOM.idFromName(trip.id));
    await room.fetch('https://room.internal/schedule',{method:'POST',body:JSON.stringify({tripId:trip.id})});
    return c.json({ trip, pin },201);
  } catch (e) {
    if (String(e).includes('customer_one_active_trip')) return error('You already have an active trip.', 'active_trip',409);
    throw e;
  }
});

api.get('/v1/trips/active', async c => {
  const user=await requireRole(c.env,c.req.raw,['customer','rider']);if(isResponse(user))return user;
  const rows=user.role==='customer'
    ? await db(c.env)`select id,status,vehicle_type,pickup_text,drop_text,estimate_rupees,rider_id from trips where customer_id=${user.id}::uuid and status in ('searching','accepted','arrived','in_progress') limit 1`
    : await db(c.env)`select id,status,vehicle_type,pickup_text,drop_text,estimate_rupees,customer_id from trips where rider_id=${user.id}::uuid and status in ('accepted','arrived','in_progress') limit 1`;
  return c.json({ trip:rows[0]||null });
});
api.get('/v1/trips/history', async c => {
  const user=await requireRole(c.env,c.req.raw,['customer','rider']);if(isResponse(user))return user;
  const rows=user.role==='customer'
    ? await db(c.env)`select id,status,vehicle_type,pickup_text,drop_text,estimate_rupees,final_rupees,created_at,completed_at from trips where customer_id=${user.id}::uuid order by created_at desc limit 50`
    : await db(c.env)`select id,status,vehicle_type,pickup_text,drop_text,estimate_rupees,final_rupees,created_at,completed_at from trips where rider_id=${user.id}::uuid order by created_at desc limit 50`;
  return c.json({ trips:rows });
});
api.get('/v1/trips/:id', async c => {
  const user=await requireRole(c.env,c.req.raw,['customer','rider','super_admin','support_agent']);if(isResponse(user))return user;
  const id=c.req.param('id');if(!uuidOk(id))return error('Trip not found.','not_found',404);
  const [trip]=await db(c.env)`select t.id,t.customer_id,t.rider_id,t.status,t.vehicle_type,t.pickup_lat,t.pickup_lng,t.pickup_text,t.drop_lat,t.drop_lng,t.drop_text,
    t.estimated_km,t.estimated_min,t.estimate_rupees,t.final_rupees,t.created_at,t.accepted_at,t.arrived_at,t.started_at,t.completed_at,
    u.name as rider_name,rp.vehicle_number,rp.rating_avg from trips t left join users u on u.id=t.rider_id left join rider_profiles rp on rp.user_id=t.rider_id where t.id=${id}::uuid`;
  if(!trip || (user.role==='customer'&&trip.customer_id!==user.id) || (user.role==='rider'&&trip.rider_id!==user.id))return error('Trip not found.','not_found',404);
  const [location]=await db(c.env)`select lat,lng,heading,recorded_at from trip_locations where trip_id=${id}::uuid order by recorded_at desc limit 1`;
  return c.json({ trip, location:location||null });
});
api.get('/v1/trips/:id/route', async c => {
  const user=await requireRole(c.env,c.req.raw,['rider']);if(isResponse(user))return user;
  const id=c.req.param('id');if(!uuidOk(id))return error('Trip not found.','not_found',404);
  const [trip]=await db(c.env)`select rider_id,status,vehicle_type,pickup_lat,pickup_lng,drop_lat,drop_lng from trips where id=${id}::uuid`;
  if(!trip||trip.rider_id!==user.id||!['accepted','arrived','in_progress'].includes(trip.status))return error('Trip not found.','not_found',404);
  const origin={lat:Number(c.req.query('lat')),lng:Number(c.req.query('lng'))};
  if(!validPoint({...origin,text:'Current location'}))return error('Location is unavailable.','invalid_location');
  const target=trip.status==='in_progress'
    ? {lat:Number(trip.drop_lat),lng:Number(trip.drop_lng)}
    : {lat:Number(trip.pickup_lat),lng:Number(trip.pickup_lng)};
  return c.json({...(await routeEstimate(c.env,origin,target,trip.vehicle_type as Vehicle)),target});
});
api.get('/v1/trips/:id/live', async c => {
  const user=await requireRole(c.env,c.req.raw,['customer','rider','super_admin','support_agent']);if(isResponse(user))return user;
  const id=c.req.param('id');if(!uuidOk(id))return error('Trip not found.','not_found',404);
  const [trip]=await db(c.env)`select customer_id,rider_id from trips where id=${id}::uuid`;
  if(!trip || (!['super_admin','support_agent'].includes(user.role)&&![trip.customer_id,trip.rider_id].includes(user.id)))return error('Trip not found.','not_found',404);
  if(c.req.header('Upgrade')!=='websocket')return error('WebSocket required.','websocket_required',426);
  return c.env.TRIP_ROOM.get(c.env.TRIP_ROOM.idFromName(id)).fetch(c.req.raw);
});
api.post('/v1/trips/:id/cancel', async c => {
  const user=await requireRole(c.env,c.req.raw,['customer','rider']);if(isResponse(user))return user;
  const id=c.req.param('id'),input=await body<{ reason?: string }>(c.req.raw);
  if(!uuidOk(id)||!input.reason?.trim())return error('Select a cancellation reason.','reason_required');
  const sql=db(c.env);
  const changed=user.role==='customer'
    ? await sql`update trips set status='cancelled',cancelled_by=${user.id}::uuid,cancel_reason=${input.reason.slice(0,240)} where id=${id}::uuid and customer_id=${user.id}::uuid and status in ('searching','accepted','arrived') returning id`
    : await sql`update trips set status='cancelled',cancelled_by=${user.id}::uuid,cancel_reason=${input.reason.slice(0,240)} where id=${id}::uuid and rider_id=${user.id}::uuid and status in ('accepted','arrived') returning id`;
  if(!changed.length)return error('This trip cannot be cancelled here.','invalid_state',409);
  await broadcast(c.env,id,{status:'cancelled'});return c.json({ok:true});
});

api.get('/v1/rider/offers', async c => {
  const user=await requireRole(c.env,c.req.raw,['rider']);if(isResponse(user))return user;
  return c.json({offers:await db(c.env)`select o.id,o.trip_id,o.expires_at,t.pickup_text,t.drop_text,t.estimated_km,t.estimate_rupees
    from trip_offers o join trips t on t.id=o.trip_id where o.rider_id=${user.id}::uuid and o.responded_at is null and o.expires_at>now() and t.status='searching' order by o.offered_at desc`});
});
api.post('/v1/rider/offers/:id/accept', async c => {
  const user=await requireRole(c.env,c.req.raw,['rider']);if(isResponse(user))return user;
  const id=c.req.param('id');if(!uuidOk(id))return error('Offer not found.','not_found',404);
  const [result]=await db(c.env)`select accept_trip_offer(${id}::uuid,${user.id}::uuid) as trip_id`;
  if(!result?.trip_id)return error('Another rider got this trip or the offer expired.','offer_expired',409);
  await broadcast(c.env,result.trip_id,{status:'accepted',rider_id:user.id});return c.json({trip_id:result.trip_id});
});
api.post('/v1/rider/offers/:id/decline', async c => {
  const user=await requireRole(c.env,c.req.raw,['rider']);if(isResponse(user))return user;
  const id=c.req.param('id');if(!uuidOk(id))return error('Offer not found.','not_found',404);
  const sql=db(c.env);
  const [offer]=await sql`update trip_offers set response='declined',responded_at=now() where id=${id}::uuid and rider_id=${user.id}::uuid and responded_at is null returning trip_id`;
  if(!offer)return error('Offer expired.','offer_expired',409);
  await sql`update rider_profiles set decline_streak=decline_streak+1,is_online=case when decline_streak+1>=3 then false else is_online end where user_id=${user.id}::uuid`;
  await advanceMatch(c.env,offer.trip_id);return c.json({ok:true});
});
api.post('/v1/trips/:id/arrived',async c=>{
  const user=await requireRole(c.env,c.req.raw,['rider']);if(isResponse(user))return user;
  const id=c.req.param('id');if(!uuidOk(id))return error('Trip not found.','not_found',404);
  const rows=await db(c.env)`update trips set status='arrived',arrived_at=now() where id=${id}::uuid and rider_id=${user.id}::uuid and status='accepted' returning id`;
  if(!rows.length)return error('Trip is not ready for arrival.','invalid_state',409);
  await broadcast(c.env,id,{status:'arrived'});return c.json({ok:true});
});
api.post('/v1/trips/:id/start',async c=>{
  const user=await requireRole(c.env,c.req.raw,['rider']);if(isResponse(user))return user;
  const id=c.req.param('id'),input=await body<{pin?:string}>(c.req.raw);
  if(!uuidOk(id)||!/^\d{4}$/.test(input.pin||''))return error('Enter the four-digit PIN.','invalid_pin');
  const sql=db(c.env);
  const [trip]=await sql`select pin_hash,pin_locked,wrong_pin_attempts from trips where id=${id}::uuid and rider_id=${user.id}::uuid and status='arrived'`;
  if(!trip)return error('Trip is not ready to start.','invalid_state',409);
  if(trip.pin_locked)return error('PIN entry is locked. The customer may cancel for free.','pin_locked',423);
  if(await hmac(c.env.SESSION_SECRET,input.pin!)!==trip.pin_hash){
    const [wrong]=await sql`select record_wrong_pin(${id}::uuid,${user.id}::uuid) as attempts`;
    return c.json({error:'Wrong PIN.',code:'wrong_pin',attempts_left:Math.max(0,5-Number(wrong?.attempts||5))},400);
  }
  const rows=await sql`update trips set status='in_progress',started_at=now() where id=${id}::uuid and rider_id=${user.id}::uuid and status='arrived' and not pin_locked returning id`;
  if(!rows.length)return error('Trip is not ready to start.','invalid_state',409);
  await broadcast(c.env,id,{status:'in_progress'});return c.json({ok:true});
});
api.post('/v1/trips/:id/complete',async c=>{
  const user=await requireRole(c.env,c.req.raw,['rider']);if(isResponse(user))return user;
  const id=c.req.param('id'),input=await body<{final_km?:number}>(c.req.raw);
  if(!uuidOk(id))return error('Trip not found.','not_found',404);
  const sql=db(c.env);
  const [trip]=await sql`select t.estimated_km,t.estimate_rupees,t.started_at,t.vehicle_type,f.base,f.per_km,f.per_min,f.minimum
    from trips t join fare_config f on f.vehicle_type=t.vehicle_type where t.id=${id}::uuid and t.rider_id=${user.id}::uuid and t.status='in_progress'`;
  if(!trip)return error('Trip is not in progress.','invalid_state',409);
  const km=Number.isFinite(input.final_km)&&Number(input.final_km)>0?Math.min(Number(input.final_km),Number(trip.estimated_km)*1.5):Number(trip.estimated_km);
  const minutes=Math.max(1,Math.round((Date.now()-new Date(trip.started_at).getTime())/60_000));
  const amount=Math.min(fare({base:Number(trip.base),per_km:Number(trip.per_km),per_min:Number(trip.per_min),minimum:Number(trip.minimum)},km,minutes),Math.round(Number(trip.estimate_rupees)*1.5));
  const rows=await sql`update trips set status='completed',completed_at=now(),final_km=${km},duration_min=${minutes},final_rupees=${amount}
    where id=${id}::uuid and rider_id=${user.id}::uuid and status='in_progress' returning id,final_rupees`;
  if(!rows.length)return error('Trip already ended.','invalid_state',409);
  await broadcast(c.env,id,{status:'completed',final_rupees:amount});return c.json({trip:rows[0],payment:'cash_or_direct_upi'});
});
api.post('/v1/trips/:id/location',async c=>{
  const user=await requireRole(c.env,c.req.raw,['rider']);if(isResponse(user))return user;
  const id=c.req.param('id'),input=await body<{lat?:number;lng?:number;heading?:number}>(c.req.raw);
  if(!uuidOk(id)||!Number.isFinite(input.lat)||!Number.isFinite(input.lng)||Math.abs(input.lat!)>90||Math.abs(input.lng!)>180)return error('Location unavailable.','invalid_location');
  const sql=db(c.env);
  const [trip]=await sql`select status from trips where id=${id}::uuid and rider_id=${user.id}::uuid and status in ('accepted','arrived','in_progress')`;
  if(!trip)return error('Trip not active.','invalid_state',409);
  await sql`insert into trip_locations(trip_id,lat,lng,heading) values(${id}::uuid,${input.lat!},${input.lng!},${Math.round(input.heading||0)})`;
  await sql`update rider_profiles set last_lat=${input.lat!},last_lng=${input.lng!},last_seen_at=now() where user_id=${user.id}::uuid`;
  await broadcast(c.env,id,{status:trip.status,location:{lat:input.lat,lng:input.lng,heading:input.heading||0}});return c.json({ok:true});
});

api.get('/v1/profile',async c=>{
  const user=await requireRole(c.env,c.req.raw,['customer','rider']);if(isResponse(user))return user;
  const [profile]=await db(c.env)`select id,email,phone,name,language,theme,role from users where id=${user.id}::uuid`;
  return c.json({profile});
});
api.patch('/v1/profile',async c=>{
  const user=await requireRole(c.env,c.req.raw,['customer','rider']);if(isResponse(user))return user;
  const input=await body<{name?:string;phone?:string;language?:string;theme?:string;push_token?:string}>(c.req.raw);
  const name=typeof input.name==='string'?input.name.trim().slice(0,80):null;
  const phone=typeof input.phone==='string'?input.phone.trim().slice(0,20):null;
  const lang=['en','hi'].includes(input.language||'')?input.language:null;
  const theme=['dark','light','system'].includes(input.theme||'')?input.theme:null;
  const token=typeof input.push_token==='string'?input.push_token.slice(0,512):null;
  const [profile]=await db(c.env)`update users set name=coalesce(${name},name),phone=coalesce(${phone},phone),
    language=coalesce(${lang},language),theme=coalesce(${theme},theme),push_token=coalesce(${token},push_token)
    where id=${user.id}::uuid returning id,email,phone,name,language,theme,role`;
  return c.json({profile});
});
api.delete('/v1/profile',async c=>{
  const user=await requireRole(c.env,c.req.raw,['customer','rider']);if(isResponse(user))return user;
  const sql=db(c.env);
  const active=await sql`select id from trips where (customer_id=${user.id}::uuid or rider_id=${user.id}::uuid)
    and status in ('searching','accepted','arrived','in_progress') limit 1`;
  if(active.length)return error('Finish your active trip before deleting your account.','active_trip',409);
  await sql`update users set email='deleted+'||id||'@haan.invalid',phone=null,name=null,push_token=null,deleted_at=now() where id=${user.id}::uuid`;
  await sql`update sessions set revoked_at=now() where user_id=${user.id}::uuid and revoked_at is null`;
  await sql`update trips set customer_id=null where customer_id=${user.id}::uuid`;
  await sql`update trips set rider_id=null where rider_id=${user.id}::uuid`;
  return c.json({ok:true});
});
api.get('/v1/places/saved',async c=>{
  const user=await requireRole(c.env,c.req.raw,['customer']);if(isResponse(user))return user;
  return c.json({places:await db(c.env)`select id,label,lat,lng,text from saved_places where user_id=${user.id}::uuid order by created_at desc`});
});
api.post('/v1/places/saved',async c=>{
  const user=await requireRole(c.env,c.req.raw,['customer']);if(isResponse(user))return user;
  const input=await body<{label?:string;lat?:number;lng?:number;text?:string}>(c.req.raw);
  const label=input.label?.trim();
  if(!label||!validPoint(input))return error('Choose a place and label.','invalid_place');
  const sql=db(c.env);
  const [count]=await sql`select count(*)::int as n from saved_places where user_id=${user.id}::uuid`;
  if(Number(count.n)>=10)return error('You can save up to 10 places.','saved_limit',409);
  const [place]=await sql`insert into saved_places(user_id,label,lat,lng,text) values(${user.id}::uuid,${label.slice(0,40)},${input.lat!},${input.lng!},${input.text!.slice(0,240)}) returning id,label,lat,lng,text`;
  return c.json({place},201);
});
api.delete('/v1/places/saved/:id',async c=>{
  const user=await requireRole(c.env,c.req.raw,['customer']);if(isResponse(user))return user;
  const id=c.req.param('id');if(!uuidOk(id))return error('Place not found.','not_found',404);
  await db(c.env)`delete from saved_places where id=${id}::uuid and user_id=${user.id}::uuid`;return c.json({ok:true});
});
api.post('/v1/trips/:id/rating',async c=>{
  const user=await requireRole(c.env,c.req.raw,['customer','rider']);if(isResponse(user))return user;
  const id=c.req.param('id'),input=await body<{stars?:number;comment?:string}>(c.req.raw);
  if(!uuidOk(id)||!Number.isInteger(input.stars)||input.stars!<1||input.stars!>5)return error('Choose one to five stars.','invalid_rating');
  const sql=db(c.env);
  const [trip]=await sql`select customer_id,rider_id from trips where id=${id}::uuid and status='completed'`;
  if(!trip||![trip.customer_id,trip.rider_id].includes(user.id))return error('Trip not found.','not_found',404);
  const to=user.id===trip.customer_id?trip.rider_id:trip.customer_id;
  if(!to)return error('This trip cannot be rated.','unavailable',409);
  const result=await sql`insert into ratings(trip_id,from_user,to_user,stars,comment) values(${id}::uuid,${user.id}::uuid,${to}::uuid,${input.stars!},${(input.comment||'').slice(0,500)}) on conflict do nothing returning id`;
  if(!result.length)return error('You already rated this trip.','already_rated',409);
  return c.json({ok:true});
});
api.get('/v1/tickets',async c=>{
  const user=await requireRole(c.env,c.req.raw,['customer','rider']);if(isResponse(user))return user;
  return c.json({tickets:await db(c.env)`select id,subject,status,trip_id,created_at from tickets where user_id=${user.id}::uuid order by created_at desc limit 50`});
});
api.post('/v1/tickets',async c=>{
  const user=await requireRole(c.env,c.req.raw,['customer','rider']);if(isResponse(user))return user;
  const input=await body<{subject?:string;message?:string;trip_id?:string}>(c.req.raw);
  if(!input.subject?.trim()||!input.message?.trim()||input.message.length>2000)return error('Add a subject and message under 2,000 characters.','invalid_ticket');
  const sql=db(c.env);
  if(input.trip_id){
    if(!uuidOk(input.trip_id))return error('Trip not found.','not_found',404);
    const trip=await sql`select id from trips where id=${input.trip_id}::uuid and (customer_id=${user.id}::uuid or rider_id=${user.id}::uuid)`;
    if(!trip.length)return error('Trip not found.','not_found',404);
  }
  const [ticket]=await sql`insert into tickets(user_id,trip_id,subject) values(${user.id}::uuid,${input.trip_id||null}::uuid,${input.subject.slice(0,120)}) returning id,status`;
  await sql`insert into ticket_messages(ticket_id,author_id,body) values(${ticket.id}::uuid,${user.id}::uuid,${input.message})`;
  return c.json({ticket},201);
});
api.get('/v1/tickets/:id',async c=>{
  const user=await requireRole(c.env,c.req.raw,['customer','rider','super_admin','support_agent']);if(isResponse(user))return user;
  const id=c.req.param('id');if(!uuidOk(id))return error('Ticket not found.','not_found',404);
  const [ticket]=await db(c.env)`select id,user_id,trip_id,subject,status,created_at from tickets where id=${id}::uuid`;
  if(!ticket||(!['super_admin','support_agent'].includes(user.role)&&ticket.user_id!==user.id))return error('Ticket not found.','not_found',404);
  const messages=await db(c.env)`select author_id,body,created_at from ticket_messages where ticket_id=${id}::uuid order by created_at`;
  return c.json({ticket,messages});
});
api.post('/v1/tickets/:id/messages',async c=>{
  const user=await requireRole(c.env,c.req.raw,['customer','rider','super_admin','support_agent']);if(isResponse(user))return user;
  const id=c.req.param('id'),input=await body<{body?:string}>(c.req.raw);
  if(!uuidOk(id)||!input.body?.trim()||input.body.length>2000)return error('Write a message under 2,000 characters.','invalid_message');
  const sql=db(c.env),[ticket]=await sql`select user_id from tickets where id=${id}::uuid`;
  if(!ticket||(!['super_admin','support_agent'].includes(user.role)&&ticket.user_id!==user.id))return error('Ticket not found.','not_found',404);
  await sql`insert into ticket_messages(ticket_id,author_id,body) values(${id}::uuid,${user.id}::uuid,${input.body})`;
  if(['super_admin','support_agent'].includes(user.role))await audit(c.env,user,'ticket_reply',id,{},c.req.raw);
  return c.json({ok:true});
});

api.get('/v1/rider/profile',async c=>{
  const user=await requireRole(c.env,c.req.raw,['rider']);if(isResponse(user))return user;
  const [profile]=await db(c.env)`select vehicle_type,vehicle_number,upi_id,verification_status,rejection_reason,is_online,rating_avg,
    licence_key is not null as licence_uploaded,rc_key is not null as rc_uploaded,selfie_key is not null as selfie_uploaded
    from rider_profiles where user_id=${user.id}::uuid`;
  return c.json({profile:profile||null});
});
api.patch('/v1/rider/profile',async c=>{
  const user=await requireRole(c.env,c.req.raw,['rider']);if(isResponse(user))return user;
  const input=await body<{vehicle_type?:Vehicle;vehicle_number?:string;upi_id?:string}>(c.req.raw);
  if(!['Bike','Auto','Cab'].includes(input.vehicle_type||'')||!input.vehicle_number?.trim())return error('Add a vehicle type and number.','invalid_vehicle');
  const [profile]=await db(c.env)`insert into rider_profiles(user_id,vehicle_type,vehicle_number,upi_id)
    values(${user.id}::uuid,${input.vehicle_type}::vehicle_type,${input.vehicle_number.trim().slice(0,24)},${(input.upi_id||'').slice(0,100)})
    on conflict(user_id) do update set vehicle_type=excluded.vehicle_type,vehicle_number=excluded.vehicle_number,upi_id=excluded.upi_id,
      verification_status='pending',rejection_reason=null,is_online=false returning vehicle_type,vehicle_number,verification_status`;
  return c.json({profile});
});
api.post('/v1/rider/documents/:kind',async c=>{
  const user=await requireRole(c.env,c.req.raw,['rider']);if(isResponse(user))return user;
  const kind=c.req.param('kind');if(!['licence','rc','selfie'].includes(kind))return error('Unknown document.','invalid_document');
  const contentType=c.req.header('Content-Type')||'';
  if(!['image/jpeg','image/png','image/webp'].includes(contentType))return error('Upload a JPEG, PNG or WebP image.','invalid_file_type');
  const bytes=await c.req.arrayBuffer();
  if(bytes.byteLength===0||bytes.byteLength>500_000)return error('Each document must be under 500 KB.','file_too_large',413);
  const key=`riders/${user.id}/${kind}/${crypto.randomUUID()}`;
  await c.env.DOCUMENTS.put(key,bytes,{metadata:{contentType}});
  const sql=db(c.env);
  await sql`insert into rider_profiles(user_id) values(${user.id}::uuid) on conflict do nothing`;
  if(kind==='licence')await sql`update rider_profiles set licence_key=${key},verification_status='pending',is_online=false where user_id=${user.id}::uuid`;
  if(kind==='rc')await sql`update rider_profiles set rc_key=${key},verification_status='pending',is_online=false where user_id=${user.id}::uuid`;
  if(kind==='selfie')await sql`update rider_profiles set selfie_key=${key},verification_status='pending',is_online=false where user_id=${user.id}::uuid`;
  return c.json({ok:true});
});
api.post('/v1/rider/online',async c=>{
  const user=await requireRole(c.env,c.req.raw,['rider']);if(isResponse(user))return user;
  const input=await body<{online?:boolean;lat?:number;lng?:number}>(c.req.raw);
  if(typeof input.online!=='boolean')return error('Choose online or offline.','invalid_state');
  if(input.online&&(!Number.isFinite(input.lat)||!Number.isFinite(input.lng)))return error('Turn on GPS before going online.','gps_required');
  const sql=db(c.env);
  const rows=await sql`update rider_profiles set is_online=${input.online},last_lat=case when ${input.online} then ${input.lat||null} else last_lat end,
    last_lng=case when ${input.online} then ${input.lng||null} else last_lng end,last_seen_at=case when ${input.online} then now() else last_seen_at end
    where user_id=${user.id}::uuid and verification_status='approved' returning is_online`;
  if(!rows.length)return error('Wait for rider approval before going online.','not_approved',403);
  return c.json({online:rows[0].is_online});
});
api.post('/v1/rider/heartbeat',async c=>{
  const user=await requireRole(c.env,c.req.raw,['rider']);if(isResponse(user))return user;
  const input=await body<{lat?:number;lng?:number}>(c.req.raw);
  if(!Number.isFinite(input.lat)||!Number.isFinite(input.lng))return error('Location unavailable.','invalid_location');
  await db(c.env)`update rider_profiles set last_lat=${input.lat!},last_lng=${input.lng!},last_seen_at=now() where user_id=${user.id}::uuid and is_online`;
  return c.json({ok:true});
});
api.get('/v1/rider/earnings',async c=>{
  const user=await requireRole(c.env,c.req.raw,['rider']);if(isResponse(user))return user;
  const [totals]=await db(c.env)`select coalesce(sum(final_rupees) filter(where completed_at>=date_trunc('day',now())),0)::int as today,
    coalesce(sum(final_rupees) filter(where completed_at>=date_trunc('week',now())),0)::int as week,
    count(*) filter(where completed_at>=date_trunc('day',now()))::int as trips_today
    from trips where rider_id=${user.id}::uuid and status='completed'`;
  return c.json({earnings:totals});
});

api.post('/v1/admin/login',async c=>{
  const input=await body<{email?:string;password?:string;totp?:string}>(c.req.raw);
  const email=input.email?.trim().toLowerCase();
  if(!emailOk(email)||!input.password||!input.totp)return error('Enter email, password and authenticator code.','missing_credentials');
  const loginKey=`admin-login:${ip(c.req.raw)}`;
  const bucket=new Date(Math.floor(Date.now()/900_000)*900_000).toISOString();
  const sql=db(c.env);
  const [failed]=await sql`select count from request_limits where key=${loginKey} and bucket=${bucket}::timestamptz`;
  if(Number(failed?.count||0)>=5)return error('Too many attempts. Try again in 15 minutes.','login_locked',429);
  const [row]=await sql`select u.id,u.role,u.email,u.is_blocked,ac.password_hash,ac.totp_ciphertext
    from users u join admin_credentials ac on ac.user_id=u.id where u.email=${email} and u.deleted_at is null`;
  if(!row||!['super_admin','support_agent'].includes(row.role)||row.is_blocked||!await verifyPassword(input.password,row.password_hash)){
    await consumeLimit(c.env,loginKey,5,15);return error('Email, password or code is incorrect.','wrong_credentials',401);
  }
  const secret=await decryptTotp(c.env.ADMIN_TOTP_KEY,row.totp_ciphertext);
  if(!await verifyTotp(secret,input.totp)){await consumeLimit(c.env,loginKey,5,15);return error('Email, password or code is incorrect.','wrong_credentials',401);}
  await sql`insert into admin_activity(user_id,last_seen_at) values(${row.id}::uuid,now()) on conflict(user_id) do update set last_seen_at=now()`;
  const user={id:row.id,role:row.role,email:row.email,is_blocked:false} as Principal;
  await audit(c.env,user,'login','admin',{},c.req.raw);
  return c.json(await issueTokens(c.env,user,'web admin'));
});
api.post('/v1/admin/admins',async c=>{
  const admin=await requireRole(c.env,c.req.raw,['super_admin']);if(isResponse(admin))return admin;
  const input=await body<{email?:string;role?:string}>(c.req.raw);
  const email=input.email?.trim().toLowerCase();
  if(!emailOk(email)||!['support_agent','super_admin'].includes(input.role||''))return error('Enter an email and admin role.','invalid_admin');
  const sql=db(c.env);
  const [existing]=await sql`select id from users where email=${email}`;
  if(existing)return error('This email already has an account.','email_used',409);
  const password=randomToken(),secret=newTotpSecret(),encrypted=await encryptTotp(c.env.ADMIN_TOTP_KEY,secret);
  const [created]=await sql`insert into users(email,role) values(${email},${input.role}::user_role) returning id`;
  await sql`insert into admin_credentials(user_id,password_hash,totp_ciphertext) values(${created.id}::uuid,${await passwordHash(password)},${encrypted})`;
  await audit(c.env,admin,'create_admin',created.id,{email,role:input.role},c.req.raw);
  const setup=totpSetupKey(secret);
  return c.json({id:created.id,email,role:input.role,temporary_password:password,authenticator_key:setup,authenticator_uri:`otpauth://totp/Haan:${encodeURIComponent(email)}?secret=${setup}&issuer=Haan&algorithm=SHA1&digits=6&period=30`},201);
});
api.get('/v1/admin/dashboard',async c=>{
  const user=await requireRole(c.env,c.req.raw,['super_admin','support_agent']);if(isResponse(user))return user;
  const sql=db(c.env);
  const [trips]=await sql`select count(*) filter(where status in ('searching','accepted','arrived','in_progress'))::int as active,
    count(*) filter(where created_at>=date_trunc('day',now()))::int as today from trips`;
  const [riders]=await sql`select count(*) filter(where verification_status='pending')::int as pending,
    count(*) filter(where is_online)::int as online from rider_profiles`;
  const [tickets]=await sql`select count(*) filter(where status<>'resolved')::int as open from tickets`;
  return c.json({trips,riders,tickets});
});
api.get('/v1/admin/riders',async c=>{
  const user=await requireRole(c.env,c.req.raw,['super_admin','support_agent']);if(isResponse(user))return user;
  const status=c.req.query('status')||'pending';
  if(!['pending','approved','rejected'].includes(status))return error('Unknown status.','invalid_status');
  const rows=await db(c.env)`select rp.user_id,u.name,u.email,rp.vehicle_type,rp.vehicle_number,rp.verification_status,rp.rejection_reason,
    rp.created_at from rider_profiles rp join users u on u.id=rp.user_id where rp.verification_status=${status}::verification_status order by rp.created_at limit 100`;
  return c.json({riders:rows});
});
api.get('/v1/admin/riders/:id',async c=>{
  const user=await requireRole(c.env,c.req.raw,['super_admin','support_agent']);if(isResponse(user))return user;
  const id=c.req.param('id');if(!uuidOk(id))return error('Rider not found.','not_found',404);
  const [rider]=await db(c.env)`select rp.*,u.email,u.name,u.phone from rider_profiles rp join users u on u.id=rp.user_id where rp.user_id=${id}::uuid`;
  if(!rider)return error('Rider not found.','not_found',404);
  const expires=Date.now()+5*60_000;
  const docs:Record<string,string>={};
  for(const kind of ['licence','rc','selfie'])if(rider[`${kind}_key`]){
    const sig=await hmac(c.env.SESSION_SECRET,`${id}:${kind}:${expires}`);
    docs[kind]=`/v1/admin/riders/${id}/documents/${kind}?expires=${expires}&sig=${sig}`;
  }
  delete rider.licence_key;delete rider.rc_key;delete rider.selfie_key;
  return c.json({rider,documents:docs});
});
api.get('/v1/admin/riders/:id/documents/:kind',async c=>{
  const user=await requireRole(c.env,c.req.raw,['super_admin','support_agent']);if(isResponse(user))return user;
  const id=c.req.param('id'),kind=c.req.param('kind'),expires=Number(c.req.query('expires')),sig=c.req.query('sig');
  if(!uuidOk(id)||!['licence','rc','selfie'].includes(kind)||!Number.isFinite(expires)||expires<Date.now()||expires>Date.now()+5*60_000
    ||sig!==await hmac(c.env.SESSION_SECRET,`${id}:${kind}:${expires}`))return error('Document link expired. Open the rider again.','document_expired',403);
  const [rider]=await db(c.env)`select licence_key,rc_key,selfie_key from rider_profiles where user_id=${id}::uuid`;
  const key=rider?.[`${kind}_key`];if(!key)return error('Document not found.','not_found',404);
  const object=await c.env.DOCUMENTS.getWithMetadata<{contentType:string}>(key,'arrayBuffer');
  if(!object.value)return error('Document not found.','not_found',404);
  await audit(c.env,user,'document_view',id,{kind},c.req.raw);
  return new Response(object.value,{headers:{'Content-Type':object.metadata?.contentType||'image/jpeg','Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff'}});
});
api.post('/v1/admin/riders/:id/verify',async c=>{
  const user=await requireRole(c.env,c.req.raw,['super_admin','support_agent']);if(isResponse(user))return user;
  const id=c.req.param('id'),input=await body<{decision?:string;reason?:string}>(c.req.raw);
  if(!uuidOk(id)||!['approved','rejected'].includes(input.decision||''))return error('Choose approve or reject.','invalid_decision');
  if(input.decision==='rejected'&&!input.reason?.trim())return error('Add a rejection reason.','reason_required');
  const sql=db(c.env);
  const [rider]=await sql`update rider_profiles set verification_status=${input.decision}::verification_status,
    rejection_reason=${input.decision==='rejected'?(input.reason||'').slice(0,300):null},is_online=false
    where user_id=${id}::uuid and licence_key is not null and rc_key is not null and selfie_key is not null
    returning user_id`;
  if(!rider)return error('All three documents are required.','documents_missing',409);
  await audit(c.env,user,'rider_verify',id,{decision:input.decision,reason:input.reason||null},c.req.raw);
  const [recipient]=await sql`select email from users where id=${id}::uuid`;
  if(recipient)c.executionCtx.waitUntil(sendEmail(c.env,recipient.email,'Haan rider verification',input.decision==='approved'?'Your rider account is approved.':`Your rider documents need changes: ${input.reason}`));
  c.executionCtx.waitUntil(sendPush(c.env,id,'Rider verification',input.decision==='approved'?'Your account is approved. You can go online.':`Please update your documents: ${input.reason}`,{kind:'verification'}));
  return c.json({ok:true});
});
api.get('/v1/admin/trips',async c=>{
  const user=await requireRole(c.env,c.req.raw,['super_admin','support_agent']);if(isResponse(user))return user;
  const q=(c.req.query('q')||'').trim();
  const rows=await db(c.env)`select t.id,t.status,t.vehicle_type,t.pickup_text,t.drop_text,t.estimate_rupees,t.final_rupees,t.created_at,
    cu.email as customer_email,ru.email as rider_email,rp.vehicle_number
    from trips t left join users cu on cu.id=t.customer_id left join users ru on ru.id=t.rider_id
    left join rider_profiles rp on rp.user_id=t.rider_id
    where ${q}='' or t.id::text ilike ${`%${q}%`} or cu.email ilike ${`%${q}%`} or ru.email ilike ${`%${q}%`} or rp.vehicle_number ilike ${`%${q}%`}
    order by t.created_at desc limit 100`;
  return c.json({trips:rows});
});
api.post('/v1/admin/trips/:id/cancel',async c=>{
  const user=await requireRole(c.env,c.req.raw,['super_admin','support_agent']);if(isResponse(user))return user;
  const id=c.req.param('id'),input=await body<{reason?:string}>(c.req.raw);
  if(!uuidOk(id)||!input.reason?.trim())return error('Add a cancellation reason.','reason_required');
  const rows=await db(c.env)`update trips set status='cancelled',cancelled_by=${user.id}::uuid,cancel_reason=${input.reason.slice(0,240)}
    where id=${id}::uuid and status in ('searching','accepted','arrived','in_progress') returning id`;
  if(!rows.length)return error('Trip is already ended.','invalid_state',409);
  await audit(c.env,user,'force_cancel',id,{reason:input.reason},c.req.raw);
  await broadcast(c.env,id,{status:'cancelled'});return c.json({ok:true});
});
api.get('/v1/admin/users',async c=>{
  const user=await requireRole(c.env,c.req.raw,['super_admin','support_agent']);if(isResponse(user))return user;
  const q=(c.req.query('q')||'').trim();
  const users=await db(c.env)`select id,email,phone,name,role,is_blocked,created_at from users
    where ${q}='' or email ilike ${`%${q}%`} or phone ilike ${`%${q}%`} or id::text ilike ${`%${q}%`}
    order by created_at desc limit 100`;
  return c.json({users});
});
api.post('/v1/admin/users/:id/block',async c=>{
  const user=await requireRole(c.env,c.req.raw,['super_admin','support_agent']);if(isResponse(user))return user;
  const id=c.req.param('id'),input=await body<{blocked?:boolean;reason?:string}>(c.req.raw);
  if(!uuidOk(id)||typeof input.blocked!=='boolean'||!input.reason?.trim())return error('Choose an action and add a reason.','invalid_action');
  const rows=await db(c.env)`update users set is_blocked=${input.blocked} where id=${id}::uuid and role in ('customer','rider') returning id`;
  if(!rows.length)return error('User not found.','not_found',404);
  await audit(c.env,user,input.blocked?'block_user':'unblock_user',id,{reason:input.reason},c.req.raw);
  return c.json({ok:true});
});
api.post('/v1/admin/notes',async c=>{
  const user=await requireRole(c.env,c.req.raw,['super_admin','support_agent']);if(isResponse(user))return user;
  const input=await body<{entity_type?:string;entity_id?:string;body?:string}>(c.req.raw);
  if(!['trip','user','rider','ticket'].includes(input.entity_type||'')||!uuidOk(input.entity_id)||!input.body?.trim()||input.body.length>2000)
    return error('Choose an item and write a note under 2,000 characters.','invalid_note');
  const [note]=await db(c.env)`insert into admin_notes(admin_id,entity_type,entity_id,body) values(${user.id}::uuid,${input.entity_type!},${input.entity_id}::uuid,${input.body}) returning id,created_at`;
  await audit(c.env,user,'add_note',input.entity_id,{entity_type:input.entity_type,note_id:note.id},c.req.raw);
  return c.json({note},201);
});
api.get('/v1/admin/notes/:type/:id',async c=>{
  const user=await requireRole(c.env,c.req.raw,['super_admin','support_agent']);if(isResponse(user))return user;
  const id=c.req.param('id'),type=c.req.param('type');if(!uuidOk(id)||!['trip','user','rider','ticket'].includes(type))return error('Item not found.','not_found',404);
  return c.json({notes:await db(c.env)`select n.id,n.body,n.created_at,u.name as admin_name from admin_notes n join users u on u.id=n.admin_id
    where n.entity_type=${type} and n.entity_id=${id}::uuid order by n.created_at desc`});
});
api.get('/v1/admin/tickets',async c=>{
  const user=await requireRole(c.env,c.req.raw,['super_admin','support_agent']);if(isResponse(user))return user;
  return c.json({tickets:await db(c.env)`select t.id,t.subject,t.status,t.created_at,u.email from tickets t left join users u on u.id=t.user_id order by t.created_at desc limit 100`});
});
api.patch('/v1/admin/tickets/:id',async c=>{
  const user=await requireRole(c.env,c.req.raw,['super_admin','support_agent']);if(isResponse(user))return user;
  const id=c.req.param('id'),input=await body<{status?:string}>(c.req.raw);
  if(!uuidOk(id)||!['open','in_progress','resolved'].includes(input.status||''))return error('Choose a ticket status.','invalid_status');
  const rows=await db(c.env)`update tickets set status=${input.status}::ticket_status where id=${id}::uuid returning id`;
  if(!rows.length)return error('Ticket not found.','not_found',404);
  await audit(c.env,user,'ticket_status',id,{status:input.status},c.req.raw);return c.json({ok:true});
});
api.get('/v1/admin/fares',async c=>{
  const user=await requireRole(c.env,c.req.raw,['super_admin','support_agent']);if(isResponse(user))return user;
  return c.json({fares:await db(c.env)`select vehicle_type,base,per_km,per_min,minimum,updated_at from fare_config order by vehicle_type`});
});
api.patch('/v1/admin/fares/:vehicle',async c=>{
  const user=await requireRole(c.env,c.req.raw,['super_admin']);if(isResponse(user))return user;
  const vehicle=c.req.param('vehicle') as Vehicle,input=await body<{base?:number;per_km?:number;per_min?:number;minimum?:number;reason?:string}>(c.req.raw);
  if(!['Bike','Auto','Cab'].includes(vehicle)||!input.reason?.trim()||[input.base,input.per_km,input.per_min,input.minimum].some(v=>!Number.isFinite(v)||v!<0||v!>1000))
    return error('Enter valid fare numbers and a reason.','invalid_fare');
  const [fareRow]=await db(c.env)`update fare_config set base=${input.base!},per_km=${input.per_km!},per_min=${input.per_min!},minimum=${input.minimum!},updated_by=${user.id}::uuid
    where vehicle_type=${vehicle}::vehicle_type returning vehicle_type,base,per_km,per_min,minimum`;
  await audit(c.env,user,'fare_update',vehicle,{fare:fareRow,reason:input.reason},c.req.raw);
  return c.json({fare:fareRow});
});
api.get('/v1/admin/audit',async c=>{
  const user=await requireRole(c.env,c.req.raw,['super_admin']);if(isResponse(user))return user;
  return c.json({entries:await db(c.env)`select l.id,l.action,l.entity,l.details,l.ip,l.created_at,u.email as admin_email
    from admin_audit_log l left join users u on u.id=l.admin_id order by l.created_at desc limit 200`});
});
api.get('/v1/admin/quotas',async c=>{
  const user=await requireRole(c.env,c.req.raw,['super_admin','support_agent']);if(isResponse(user))return user;
  const used=await db(c.env)`select service,count from quota_usage where usage_date=current_date`;
  return c.json({used,caps:{ola:Number(c.env.OLA_DAILY_FREE_CAP),gemini:Number(c.env.GEMINI_DAILY_FREE_CAP),groq:Number(c.env.GROQ_DAILY_FREE_CAP),brevo:Number(c.env.BREVO_DAILY_FREE_CAP)}});
});

api.onError((err,c)=>{console.error('api_error',err.name,err.message);return c.json({error:'Something went wrong. Please try again.',code:'server_error'},500)});
export default {
  fetch:api.fetch,
  async scheduled(event:ScheduledEvent,env:Env,ctx:ExecutionContext){
    const sql=db(env);
    if(event.cron==='* * * * *'){
      const trips=await sql`select id from trips where status='searching' and search_deadline<now() limit 100`;
      for(const trip of trips)ctx.waitUntil(advanceMatch(env,trip.id));
    }else{
      ctx.waitUntil(sql`delete from otp_codes where created_at<now()-interval '24 hours'`);
      ctx.waitUntil(sql`delete from trip_locations where recorded_at<now()-interval '30 days'`);
      ctx.waitUntil(sql`delete from assistant_logs where created_at<now()-interval '30 days'`);
      ctx.waitUntil(sql`delete from sessions where expires_at<now()-interval '1 day'`);
      ctx.waitUntil(sql`delete from request_limits where bucket<now()-interval '2 days'`);
    }
  }
};
