-- Keep promotion capacity in one row so competing bookings reserve it atomically.
alter table promotions add column if not exists claimed_count integer not null default 0
  check (claimed_count >= 0);

update promotions p set claimed_count=greatest(p.claimed_count,(
  select count(*)::int from promo_redemptions pr join trips t on t.id=pr.trip_id
  where pr.promotion_id=p.id and t.status not in ('cancelled','no_riders_found')
));

create or replace function release_promo_claim() returns trigger language plpgsql as $$
begin
  if old.promotion_id is not null and old.status not in ('cancelled','no_riders_found')
    and new.status in ('cancelled','no_riders_found') then
    update promotions set claimed_count=greatest(0,claimed_count-1)
      where id=old.promotion_id;
  end if;
  return new;
end
$$;
drop trigger if exists trip_release_promo_claim on trips;
create trigger trip_release_promo_claim after update of status on trips
  for each row execute function release_promo_claim();
