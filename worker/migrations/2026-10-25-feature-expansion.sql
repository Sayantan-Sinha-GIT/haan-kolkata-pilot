-- Prototype ride options and operator controls. Apply to development and production.
create table if not exists promotions (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z0-9_-]{4,20}$'),
  title text not null check (length(title) between 3 and 100),
  discount_type text not null check (discount_type in ('flat','percent')),
  amount integer not null check (amount between 1 and 1000),
  max_discount integer not null default 200 check (max_discount between 1 and 1000),
  max_redemptions integer not null default 100 check (max_redemptions between 1 and 10000),
  starts_at timestamptz not null,
  ends_at timestamptz not null check (ends_at > starts_at),
  active boolean not null default false,
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists promotions_active_window on promotions(active,starts_at,ends_at);

alter table trips add column if not exists service_mode text not null default 'standard'
  check (service_mode in ('standard','shared_preview','intercity'));
alter table trips add column if not exists stops jsonb not null default '[]'::jsonb
  check (jsonb_typeof(stops) = 'array' and jsonb_array_length(stops) <= 2);
alter table trips add column if not exists next_stop_index smallint not null default 0
  check (next_stop_index between 0 and 2);
alter table trips add column if not exists guest_name text;
alter table trips add column if not exists guest_phone text;
alter table trips add column if not exists promotion_id uuid references promotions(id);
alter table trips add column if not exists promo_discount_rupees integer not null default 0
  check (promo_discount_rupees between 0 and 1000);
alter table trips add column if not exists customer_estimate_rupees integer;
alter table trips add column if not exists customer_final_rupees integer;

create table if not exists promo_redemptions (
  id uuid primary key default gen_random_uuid(),
  promotion_id uuid not null references promotions(id),
  trip_id uuid not null unique references trips(id),
  discount_rupees integer not null check (discount_rupees > 0),
  subsidy_status text not null default 'pending' check (subsidy_status in ('pending','settled')),
  settled_by uuid references users(id),
  settled_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists promo_redemptions_promo on promo_redemptions(promotion_id,created_at);

create table if not exists scheduled_rides (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references users(id),
  request jsonb not null,
  scheduled_for timestamptz not null,
  estimate_rupees integer not null,
  estimated_km numeric(9,2) not null,
  estimated_min numeric(9,2) not null,
  pin_hash text not null,
  status text not null default 'scheduled' check (status in ('scheduled','activated','cancelled','expired')),
  trip_id uuid unique references trips(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists scheduled_rides_due on scheduled_rides(status,scheduled_for);
create index if not exists scheduled_rides_customer on scheduled_rides(customer_id,scheduled_for desc);

alter table rider_profiles add column if not exists destination_filter_lat double precision;
alter table rider_profiles add column if not exists destination_filter_lng double precision;
alter table rider_profiles add column if not exists destination_filter_text text;

alter table tickets add column if not exists priority text not null default 'normal'
  check (priority in ('normal','high','urgent'));
alter table tickets add column if not exists category text not null default 'general'
  check (category in ('general','safety','payment','driver','trip','account'));
alter table tickets add column if not exists assigned_to uuid references users(id);
alter table tickets add column if not exists resolution text;

