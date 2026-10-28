-- Customer-led offer increase. Existing rides begin with no increase.
alter table trips add column if not exists match_started_at timestamptz not null default now();
alter table trips add column if not exists match_round integer not null default 0;
alter table trips add column if not exists customer_fare_bump_rupees integer not null default 0
  check(customer_fare_bump_rupees between 0 and 200);
alter table trips add column if not exists fare_bump_count smallint not null default 0
  check(fare_bump_count between 0 and 3);
