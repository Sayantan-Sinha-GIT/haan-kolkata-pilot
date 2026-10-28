-- Customer-led offer increase. Existing rides begin with no increase.
alter table trips add column if not exists match_started_at timestamptz not null default now();
alter table trips add column if not exists match_round integer not null default 0;
alter table trips add column if not exists customer_fare_bump_rupees integer not null default 0
  check(customer_fare_bump_rupees between 0 and 200);
alter table trips add column if not exists fare_bump_count smallint not null default 0
  check(fare_bump_count between 0 and 3);
alter table trip_offers add column if not exists match_round integer not null default 0;

-- The trip row is rechecked after any concurrent fare restart. A previous
-- search round can never win even when its offer was visible to a concurrent
-- transaction before the restart removed it.
create or replace function accept_trip_offer(p_offer uuid,p_rider uuid) returns uuid language plpgsql as $$
declare v_trip uuid;
begin
  update trips t set rider_id=p_rider,status='accepted',accepted_at=now()
  from trip_offers o where o.id=p_offer and o.trip_id=t.id and o.rider_id=p_rider
    and o.responded_at is null and o.expires_at>now() and t.status='searching'
    and o.match_round=t.match_round
  returning t.id into v_trip;
  if v_trip is null then return null; end if;
  update trip_offers set response='accepted',responded_at=now() where id=p_offer;
  update rider_profiles set decline_streak=0 where user_id=p_rider;
  return v_trip;
end$$;
