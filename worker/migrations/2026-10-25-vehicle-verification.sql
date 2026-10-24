-- Additive migration for existing Haan production and development branches.
alter table rider_profiles
  add column if not exists vehicle_make text,
  add column if not exists vehicle_model text,
  add column if not exists vehicle_color text,
  add column if not exists vehicle_year smallint,
  add column if not exists licence_number text,
  add column if not exists insurance_expiry date,
  add column if not exists permit_expiry date,
  add column if not exists insurance_key text,
  add column if not exists permit_key text;

alter table trips add column if not exists pickup_note text;
