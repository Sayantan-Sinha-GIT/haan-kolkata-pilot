import {createHmac,randomUUID} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {neon} from '@neondatabase/serverless';
const vars=Object.fromEntries(readFileSync(new URL('../worker/.dev.vars',import.meta.url),'utf8')
  .split(/\r?\n/).filter(x=>/^[A-Z_]+=/.test(x)).map(x=>[x.slice(0,x.indexOf('=')),x.slice(x.indexOf('=')+1)]));
if(new URL(vars.DATABASE_URL).hostname!=='ep-bold-sea-b3lygotf-pooler.c-4.ap-southeast-1.aws.neon.tech')throw Error('Dev only');
const sql=neon(vars.DATABASE_URL),code='RACE'+randomUUID().slice(0,8).toUpperCase();
const [promo]=await sql`insert into promotions(code,title,discount_type,amount,max_discount,max_redemptions,starts_at,ends_at,active)
  values(${code},'Race QA','flat',10,10,1,now()-interval '1 minute',now()+interval '1 hour',true) returning id`;
const customers=[];
for(let i=0;i<2;i++)customers.push((await sql`insert into users(email,role,name)
  values(${'qa-race-'+randomUUID()+'@haan.invalid'},'customer','Promo race QA') returning id,role`)[0]);
const token=u=>{const p=Buffer.from(JSON.stringify({sub:u.id,role:u.role,exp:Math.floor(Date.now()/1000)+900})).toString('base64url');
  return p+'.'+createHmac('sha256',vars.SESSION_SECRET).update(p).digest('hex')};
const body=JSON.stringify({pickup:{lat:22.5726,lng:88.3639,text:'Esplanade'},
  drop:{lat:22.5944,lng:88.37,text:'Sealdah'},vehicle:'Bike',promo_code:code,confirmed:true});
const results=await Promise.all(customers.map(async u=>{
  const r=await fetch('http://127.0.0.1:8787/v1/trips',{method:'POST',
    headers:{Authorization:'Bearer '+token(u),'Content-Type':'application/json'},body});
  return {status:r.status,data:await r.json()};
}));
if(results.filter(r=>r.status===201).length!==1||
  results.filter(r=>r.status===409&&r.data.code==='invalid_promotion').length!==1)
  throw Error('Expected exactly one successful booking and one capped booking: '+JSON.stringify(results));
const [count]=await sql`select count(*)::int as n from promo_redemptions where promotion_id=${promo.id}::uuid`;
if(count.n!==1)throw Error('One-use promotion has '+count.n+' redemptions');
for(const r of results)if(r.data.trip?.id)await sql`update trips set status='cancelled',cancel_reason='Race QA cleanup'
  where id=${r.data.trip.id}::uuid and status='searching'`;
const [released]=await sql`select claimed_count from promotions where id=${promo.id}::uuid`;
if(released.claimed_count!==0)throw Error('Cancellation did not release the promotion claim');
console.log('PASS concurrent promotion cap and cancellation release');
