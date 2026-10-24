import { createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { neon } from '@neondatabase/serverless';
const vars=Object.fromEntries(readFileSync(new URL('../worker/.dev.vars',import.meta.url),'utf8').split(/\r?\n/).filter(x=>/^[A-Z_]+=/.test(x)).map(x=>[x.slice(0,x.indexOf('=')),x.slice(x.indexOf('=')+1)]));
if(new URL(vars.DATABASE_URL).hostname!=='ep-bold-sea-b3lygotf-pooler.c-4.ap-southeast-1.aws.neon.tech')throw new Error('Development database host mismatch');
const sql=neon(vars.DATABASE_URL);
const [user]=await sql`select id,role from users where email='customer.demo@haan.invalid' and deleted_at is null`;
if(!user)throw new Error('Development fixture missing');
const payload=Buffer.from(JSON.stringify({sub:user.id,role:user.role,exp:Math.floor(Date.now()/1000)+900})).toString('base64url');
const token=`${payload}.${createHmac('sha256',vars.SESSION_SECRET).update(payload).digest('hex')}`;
const cases=[
  ['Book a bike from Park Street to Esplanade','Bike','Esplanade'],
  ['Take me from Howrah Station to Victoria Memorial by auto','Auto','Victoria'],
  ['Mujhe Sealdah se New Market cab se jaana hai','Cab','New Market'],
  ['Shyambazar se College Street auto chahiye','Auto','College Street'],
  ['Please get me a bike from Gariahat to Ruby Crossing','Bike','Ruby'],
  ['Dum Dum se Howrah car mein jaana hai','Cab','Howrah'],
  ['I need a cab from Salt Lake to Kolkata Airport','Cab','Airport'],
  ['Mujhe Behala se Jadavpur bike se le chalo','Bike','Jadavpur'],
  ['Book an auto from Kalighat to Park Street','Auto','Park Street'],
  ['From Ballygunge to Esplanade by taxi','Cab','Esplanade'],
];
const results=await Promise.all(cases.map(async ([text,vehicle,destination],index)=>{
  try{
    const response=await fetch('http://127.0.0.1:8787/v1/assistant/parse',{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify({text}),signal:AbortSignal.timeout(30000)});
    const data=await response.json();
    const pass=response.ok&&data.intent==='book_ride'&&data.vehicle===vehicle&&String(data.destination).toLowerCase().includes(destination.toLowerCase())&&data.requires_confirmation===true;
    return {case:index+1,pass,http:response.status,intent:data.intent||null,vehicle:data.vehicle||null,destinationMatched:String(data.destination).toLowerCase().includes(destination.toLowerCase()),code:data.code||null};
  }catch(error){return {case:index+1,pass:false,error:error.name};}
}));
for(const result of results)console.log(JSON.stringify(result));
const count=results.filter(x=>x.pass).length;
console.log(`Assistant summary: ${count}/10 correct`);
if(count<8)process.exitCode=1;
