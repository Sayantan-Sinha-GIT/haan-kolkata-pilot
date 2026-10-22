-- Development branch only. These are inert fixtures and do not bypass OTP.
insert into users(email,role,name,language) values
  ('customer.demo@haan.invalid','customer','Demo customer','en'),
  ('customer.hindi@haan.invalid','customer','हिन्दी डेमो','hi'),
  ('rider.demo@haan.invalid','rider','Demo rider','en')
on conflict(email) do nothing;
insert into rider_profiles(user_id,vehicle_type,vehicle_number,verification_status,is_online,last_lat,last_lng)
select id,'Bike','WB 01 AB 1234','approved',false,22.5726,88.3639 from users where email='rider.demo@haan.invalid'
on conflict(user_id) do nothing;
