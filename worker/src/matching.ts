import { db } from './db';
import { haversineKm } from './rules';
import { broadcast } from './services';
import type { Env } from './types';

export async function advanceMatch(env: Env, tripId: string): Promise<boolean> {
  const sql = db(env);
  const [trip] = await sql`select id,status,vehicle_type,pickup_lat,pickup_lng,drop_lat,drop_lng,created_at,search_deadline,offer_count
    from trips where id=${tripId}::uuid`;
  if (!trip || trip.status !== 'searching') return false;
  const expired = await sql`update trip_offers set response='timeout',responded_at=now()
    where trip_id=${tripId}::uuid and responded_at is null and expires_at<=now() returning rider_id`;
  for (const offer of expired) {
    await sql`update rider_profiles set decline_streak=decline_streak+1,
      is_online=case when decline_streak+1>=3 then false else is_online end where user_id=${offer.rider_id}::uuid`;
  }
  const pending = await sql`select id from trip_offers where trip_id=${tripId}::uuid and responded_at is null and expires_at>now() limit 1`;
  if (pending.length) return true;
  if (new Date(trip.search_deadline).getTime() <= Date.now() || Number(trip.offer_count) >= 5) {
    await sql`update trips set status='no_riders_found' where id=${tripId}::uuid and status='searching'`;
    await broadcast(env, tripId, { status: 'no_riders_found' });
    return false;
  }
  const elapsed = Date.now() - new Date(trip.created_at).getTime();
  const radius = elapsed >= 20_000 ? 5 : 2;
  const candidates = await sql`select rp.user_id,rp.last_lat,rp.last_lng,rp.destination_filter_lat,rp.destination_filter_lng,
    6371*2*asin(sqrt(least(1,power(sin(radians(rp.last_lat-${Number(trip.pickup_lat)})/2),2)
    +cos(radians(${Number(trip.pickup_lat)}))*cos(radians(rp.last_lat))
    *power(sin(radians(rp.last_lng-${Number(trip.pickup_lng)})/2),2)))) as km
    from rider_profiles rp join users u on u.id=rp.user_id
    where rp.is_online and rp.verification_status='approved' and rp.vehicle_type=${trip.vehicle_type}::vehicle_type
      and rp.last_seen_at>now()-interval '90 seconds' and not u.is_blocked and u.phone is not null
      and rp.vehicle_number is not null and rp.vehicle_make is not null and rp.vehicle_model is not null
      and rp.vehicle_color is not null and rp.vehicle_year is not null and rp.licence_number is not null
      and rp.licence_key is not null and rp.rc_key is not null and rp.selfie_key is not null
      and rp.insurance_key is not null and rp.insurance_expiry>=current_date
      and (rp.vehicle_type='Bike' or (rp.permit_key is not null and rp.permit_expiry>=current_date))
      and not exists(select 1 from trip_offers o where o.trip_id=${tripId}::uuid and o.rider_id=rp.user_id)
      and not exists(select 1 from trips t where t.rider_id=rp.user_id and t.status in ('accepted','arrived','in_progress'))
    order by km limit 8`;
  const candidate = candidates.find(r => {
    if(Number(r.km)>radius)return false;
    if(r.destination_filter_lat==null||r.destination_filter_lng==null)return true;
    const destination={lat:Number(r.destination_filter_lat),lng:Number(r.destination_filter_lng)};
    const before=haversineKm({lat:Number(r.last_lat),lng:Number(r.last_lng)},destination);
    const after=haversineKm({lat:Number(trip.drop_lat),lng:Number(trip.drop_lng)},destination);
    return after<=before-Math.min(0.5,before*0.02);
  });
  if (!candidate) return true;
  const offers = await sql`insert into trip_offers(trip_id,rider_id) values(${tripId}::uuid,${candidate.user_id}::uuid)
    on conflict do nothing returning id`;
  if (!offers.length) return true;
  await sql`update trips set offer_count=offer_count+1 where id=${tripId}::uuid and status='searching'`;
  await broadcast(env, tripId, { status: 'searching', rider_offer: candidate.user_id });
  return true;
}
