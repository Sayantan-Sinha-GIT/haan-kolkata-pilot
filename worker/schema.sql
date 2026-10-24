create extension if not exists pgcrypto;

create type user_role as enum ('customer','rider','super_admin','support_agent');
create type trip_status as enum ('searching','accepted','arrived','in_progress','completed','cancelled','no_riders_found');
create type vehicle_type as enum ('Bike','Auto','Cab');
create type verification_status as enum ('pending','approved','rejected');
create type ticket_status as enum ('open','in_progress','resolved');

create table users (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  role user_role not null, email text not null unique, phone text, emergency_phone text, name text,
  language text not null default 'en' check(language in ('en','hi')),
  theme text not null default 'system' check(theme in ('dark','light','system')),
  push_token text, is_blocked boolean not null default false, deleted_at timestamptz
);
create table rider_profiles (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  user_id uuid not null unique references users(id), vehicle_type vehicle_type, vehicle_number text,
  vehicle_make text, vehicle_model text, vehicle_color text, vehicle_year smallint,
  licence_number text, insurance_expiry date, permit_expiry date,
  licence_key text, rc_key text, selfie_key text, insurance_key text, permit_key text, upi_id text,
  verification_status verification_status not null default 'pending', rejection_reason text,
  is_online boolean not null default false, last_lat double precision, last_lng double precision, last_seen_at timestamptz,
  decline_streak smallint not null default 0, rating_avg numeric(3,2) not null default 0
);
create index rider_online_location_idx on rider_profiles (verification_status,is_online,last_seen_at) where is_online;
create table otp_codes (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  email text not null, code_hash text not null, expires_at timestamptz not null, attempts smallint not null default 0,
  consumed_at timestamptz, sent_ip inet
);
create index otp_lookup_idx on otp_codes (email,created_at desc);
create table sessions (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  user_id uuid not null references users(id), refresh_token_hash text not null unique, device text,
  expires_at timestamptz not null, revoked_at timestamptz
);
create table admin_credentials (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  user_id uuid not null unique references users(id), password_hash text not null, totp_ciphertext text not null
);
create table admin_activity (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  user_id uuid not null unique references users(id), last_seen_at timestamptz not null default now()
);
create table fare_config (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  vehicle_type vehicle_type not null unique, base numeric(10,2) not null, per_km numeric(10,2) not null,
  per_min numeric(10,2) not null, minimum numeric(10,2) not null, updated_by uuid references users(id)
);
insert into fare_config(vehicle_type,base,per_km,per_min,minimum) values
  ('Bike',20,6,0.5,30),('Auto',30,10,1,40),('Cab',50,14,1.5,80);
create table trips (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  customer_id uuid references users(id), rider_id uuid references users(id), status trip_status not null default 'searching',
  vehicle_type vehicle_type not null, pickup_lat double precision not null, pickup_lng double precision not null,
  pickup_text text not null, pickup_note text, drop_lat double precision not null, drop_lng double precision not null, drop_text text not null,
  estimated_km numeric(9,2) not null, estimated_min numeric(9,2) not null, estimate_rupees integer not null,
  final_km numeric(9,2), duration_min numeric(9,2), final_rupees integer,
  pin_hash text not null, wrong_pin_attempts smallint not null default 0, pin_locked boolean not null default false,
  accepted_at timestamptz, arrived_at timestamptz, started_at timestamptz, completed_at timestamptz,
  cancelled_by uuid references users(id), cancel_reason text, via_assistant boolean not null default false,
  offer_count smallint not null default 0, search_deadline timestamptz not null default now()+interval '90 seconds',
  admin_fare_override_note text
);
create unique index customer_one_active_trip on trips(customer_id) where status in ('searching','accepted','arrived','in_progress');
create unique index rider_one_active_trip on trips(rider_id) where status in ('accepted','arrived','in_progress');
create index trips_customer_created on trips(customer_id,created_at desc);
create index trips_rider_created on trips(rider_id,created_at desc);
create table trip_offers (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  trip_id uuid not null references trips(id), rider_id uuid not null references users(id),
  offered_at timestamptz not null default now(), expires_at timestamptz not null default now()+interval '15 seconds',
  responded_at timestamptz, response text check(response in ('accepted','declined','timeout')),
  unique(trip_id,rider_id)
);
create index live_offers on trip_offers(trip_id,expires_at) where responded_at is null;
create unique index one_open_offer_per_trip on trip_offers(trip_id) where responded_at is null;
create table trip_locations (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  trip_id uuid not null references trips(id), lat double precision not null, lng double precision not null,
  heading smallint, recorded_at timestamptz not null default now()
);
create index trip_location_recent on trip_locations(trip_id,recorded_at desc);
create table ratings (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  trip_id uuid not null references trips(id), from_user uuid not null references users(id), to_user uuid not null references users(id),
  stars smallint not null check(stars between 1 and 5), comment text check(length(comment)<=500), unique(trip_id,from_user)
);
create table saved_places (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  user_id uuid not null references users(id), label text not null, lat double precision not null, lng double precision not null, text text not null
);
create table tickets (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  user_id uuid references users(id), trip_id uuid references trips(id), subject text not null, status ticket_status not null default 'open'
);
create table ticket_messages (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  ticket_id uuid not null references tickets(id), author_id uuid references users(id), body text not null check(length(body)<=2000)
);
create table admin_audit_log (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  admin_id uuid references users(id), action text not null, entity text not null, details jsonb not null default '{}', ip inet
);
create table admin_notes (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  admin_id uuid not null references users(id), entity_type text not null check(entity_type in ('trip','user','rider','ticket')),
  entity_id uuid not null, body text not null check(length(body)<=2000)
);
create table assistant_logs (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  user_id uuid references users(id), language text not null, transcript_text text not null, intent text not null, confidence numeric(4,3)
);
create table request_limits (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  key text not null, bucket timestamptz not null, count integer not null default 0, unique(key,bucket)
);
create table quota_usage (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  service text not null, usage_date date not null, count integer not null default 0, unique(service,usage_date)
);
create table app_config (
  id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  key text not null unique, value jsonb not null
);
insert into app_config(key,value) values ('minimum_versions','{"customer":1,"rider":1}'::jsonb);

create function touch_updated_at() returns trigger language plpgsql as $$begin new.updated_at=now(); return new; end$$;
do $$declare r record; begin for r in select table_name from information_schema.columns where table_schema='public' and column_name='updated_at' loop
  execute format('create trigger touch_updated_at before update on %I for each row execute function touch_updated_at()',r.table_name);
end loop; end$$;

-- One guarded statement chooses exactly one rider. The offer must still be live.
create function accept_trip_offer(p_offer uuid,p_rider uuid) returns uuid language plpgsql as $$
declare v_trip uuid;
begin
  update trips t set rider_id=p_rider,status='accepted',accepted_at=now()
  from trip_offers o where o.id=p_offer and o.trip_id=t.id and o.rider_id=p_rider
    and o.responded_at is null and o.expires_at>now() and t.status='searching'
  returning t.id into v_trip;
  if v_trip is null then return null; end if;
  update trip_offers set response='accepted',responded_at=now() where id=p_offer;
  update rider_profiles set decline_streak=0 where user_id=p_rider;
  return v_trip;
end$$;

create function record_wrong_pin(p_trip uuid,p_rider uuid) returns smallint language plpgsql as $$
declare v_count smallint;
begin
  update trips set wrong_pin_attempts=wrong_pin_attempts+1,pin_locked=(wrong_pin_attempts+1>=5)
    where id=p_trip and rider_id=p_rider and status='arrived' and not pin_locked
    returning wrong_pin_attempts into v_count;
  return v_count;
end$$;

create function enforce_trip_transition() returns trigger language plpgsql as $$
begin
  if new.status=old.status then return new; end if;
  if not ((old.status='searching' and new.status in ('accepted','cancelled','no_riders_found'))
    or (old.status='accepted' and new.status in ('arrived','cancelled'))
    or (old.status='arrived' and new.status in ('in_progress','cancelled'))
    or (old.status='in_progress' and new.status in ('completed','cancelled'))) then
    raise exception 'invalid_trip_transition';
  end if;
  if new.status='in_progress' and new.started_at is null then raise exception 'pin_required'; end if;
  if new.status='completed' and new.final_rupees>round(old.estimate_rupees*1.5) and nullif(new.admin_fare_override_note,'') is null then
    raise exception 'fare_cap_exceeded';
  end if;
  return new;
end$$;
create trigger trip_transition before update of status on trips for each row execute function enforce_trip_transition();
