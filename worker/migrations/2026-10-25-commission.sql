create table if not exists trip_settlements (
  trip_id uuid primary key references trips(id),
  customer_due_rupees integer not null check (customer_due_rupees > 0),
  platform_fee_rupees integer not null check (platform_fee_rupees >= 0),
  rider_earnings_rupees integer not null check (rider_earnings_rupees >= 0),
  promotion_topup_rupees integer not null check (promotion_topup_rupees >= 0),
  net_due_to_platform_rupees integer not null,
  status text not null default 'pending' check (status in ('pending','settled')),
  settled_by uuid references users(id),
  settled_at timestamptz,
  settlement_note text,
  created_at timestamptz not null default now(),
  check (customer_due_rupees = platform_fee_rupees + rider_earnings_rupees - promotion_topup_rupees),
  check (net_due_to_platform_rupees = customer_due_rupees - rider_earnings_rupees)
);
create index if not exists trip_settlements_status_created on trip_settlements(status,created_at desc);

-- Historical completed trips get an expected ledger without claiming payment was received.
insert into trip_settlements(trip_id,customer_due_rupees,platform_fee_rupees,
  rider_earnings_rupees,promotion_topup_rupees,net_due_to_platform_rupees)
select id,due,round(due*0.2)::int,gross-round(gross*0.2)::int,
  (gross-round(gross*0.2)::int)-(due-round(due*0.2)::int),
  due-(gross-round(gross*0.2)::int)
from (
  select id,final_rupees as gross,coalesce(customer_final_rupees,final_rupees) as due
  from trips where status='completed' and final_rupees>0
) completed
on conflict (trip_id) do nothing;
