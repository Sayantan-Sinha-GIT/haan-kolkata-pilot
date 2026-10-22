-- Applied to the production and development Neon branches on 2026-10-22.
alter table users add column if not exists emergency_phone text;
