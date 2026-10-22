-- Keeps concurrent matching attempts from offering one trip to two riders.
create unique index if not exists one_open_offer_per_trip on trip_offers(trip_id) where responded_at is null;
