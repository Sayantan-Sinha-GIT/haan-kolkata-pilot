import { db } from './db';
import type { Env } from './types';

const encode=(value:Uint8Array|string)=>btoa(String.fromCharCode(...(typeof value==='string'?new TextEncoder().encode(value):value))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
let cached:{token:string;until:number}|undefined;
async function firebaseToken(env:Env):Promise<string|null>{
  if(!env.FIREBASE_PROJECT_ID||!env.FIREBASE_CLIENT_EMAIL||!env.FIREBASE_PRIVATE_KEY)return null;
  if(cached&&cached.until>Date.now()+60_000)return cached.token;
  const pem=env.FIREBASE_PRIVATE_KEY.replace(/\\n/g,'\n').replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g,'');
  const binary=Uint8Array.from(atob(pem),c=>c.charCodeAt(0));
  const key=await crypto.subtle.importKey('pkcs8',binary,{name:'RSASSA-PKCS1-v1_5',hash:'SHA-256'},false,['sign']);
  const now=Math.floor(Date.now()/1000);
  const unsigned=`${encode(JSON.stringify({alg:'RS256',typ:'JWT'}))}.${encode(JSON.stringify({iss:env.FIREBASE_CLIENT_EMAIL,scope:'https://www.googleapis.com/auth/firebase.messaging',aud:'https://oauth2.googleapis.com/token',iat:now,exp:now+3600}))}`;
  const signature=encode(new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5',key,new TextEncoder().encode(unsigned))));
  const response=await fetch('https://oauth2.googleapis.com/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'urn:ietf:params:oauth:grant-type:jwt-bearer',assertion:`${unsigned}.${signature}`})});
  if(!response.ok)return null;
  const data=await response.json() as {access_token:string;expires_in:number};
  cached={token:data.access_token,until:Date.now()+data.expires_in*1000};return cached.token;
}
export async function sendPush(env:Env,userId:string,title:string,body:string,data:Record<string,string>={}):Promise<boolean>{
  const [row]=await db(env)`select push_token from users where id=${userId}::uuid and deleted_at is null and not is_blocked`;
  if(!row?.push_token)return false;
  const token=await firebaseToken(env);if(!token)return false;
  const response=await fetch(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(env.FIREBASE_PROJECT_ID!)}/messages:send`,{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify({message:{token:row.push_token,notification:{title,body},data:{...data,kind:data.kind||'trip'},android:{priority:'HIGH'}}})});
  if(response.status===404||response.status===400)await db(env)`update users set push_token=null where id=${userId}::uuid and push_token=${row.push_token}`;
  return response.ok;
}
const labels:Record<string,[string,string]>={searching:['Finding a rider','Your request is searching nearby'],accepted:['Rider assigned','Your rider is on the way'],arrived:['Rider arrived','Share your four-digit PIN to start'],in_progress:['Trip started','Your trip is underway'],completed:['Trip complete','Pay your rider directly'],cancelled:['Trip cancelled','Open Haan for details'],no_riders_found:['No rider found','Try another vehicle or try again']};
export async function pushTripStatus(env:Env,tripId:string,status:string,extraRiderId?:string):Promise<void>{
  if(status==='offer'&&extraRiderId){await sendPush(env,extraRiderId,'New trip request','You have 15 seconds to respond',{trip_id:tripId,status:'offer',kind:'offer'});return;}
  const [trip]=await db(env)`select customer_id,rider_id from trips where id=${tripId}::uuid`;
  if(!trip)return;
  const [title,body]=labels[status]||['Trip update','Open Haan for the latest status'];
  const recipients=[trip.customer_id,trip.rider_id].filter(Boolean) as string[];
  if(extraRiderId)recipients.push(extraRiderId);
  await Promise.allSettled([...new Set(recipients)].map(id=>sendPush(env,id,title,body,{trip_id:tripId,status})));
}
