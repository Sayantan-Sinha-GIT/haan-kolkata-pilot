import { haversineKm, validPoint, type Vehicle } from './rules';
import { routeEstimate } from './services';
import type { Env } from './types';

export type Point = {lat:number;lng:number;text:string};
export type RideMode = 'standard'|'shared_preview'|'intercity';
export type RideOptions = {
  pickup:Point;drop:Point;stops:Point[];vehicle:Vehicle;mode:RideMode;
  guestName:string|null;guestPhone:string|null;promoCode:string|null;
};

export function parseRideOptions(input:Record<string,unknown>):{options:RideOptions}|{error:string}{
  if(!validPoint(input.pickup)||!validPoint(input.drop)||!['Bike','Auto','Cab'].includes(String(input.vehicle)))
    return {error:'Choose a pickup, destination and vehicle.'};
  const vehicle=input.vehicle as Vehicle;
  const mode=(input.mode??'standard') as RideMode;
  if(!['standard','shared_preview','intercity'].includes(mode))return {error:'Choose a valid ride mode.'};
  if(mode!=='standard'&&vehicle!=='Cab')return {error:'Shared preview and intercity rides use Cabs.'};
  const rawStops=input.stops??[];
  if(!Array.isArray(rawStops)||rawStops.length>2||!rawStops.every(validPoint))return {error:'Choose up to two valid stops.'};
  const stops=rawStops as Point[];
  const points=[input.pickup,...stops,input.drop] as Point[];
  if(points.some((p,i)=>i>0&&haversineKm(points[i-1],p)<0.3))
    return {error:'Keep each stop at least 300 metres from the previous point.'};
  const direct=haversineKm(input.pickup,input.drop);
  if(mode==='intercity'&&(direct<20||direct>500))return {error:'Intercity preview supports 20–500 km Cab rides.'};
  if(input.guest!==undefined&&input.guest!==null&&typeof input.guest!=='object')return {error:'Enter the guest passenger’s name and mobile number.'};
  const guest=input.guest as Record<string,unknown>|null|undefined;
  const guestName=guest?String(guest.name??'').trim():null;
  const guestPhone=guest?String(guest.phone??'').replace(/[\s()-]/g,'').trim():null;
  if(guest&&(!guestName||guestName.length<2||guestName.length>80||!/^(?:\+?91)?[6-9]\d{9}$/.test(guestPhone||'')))
    return {error:'Enter a guest name and valid Indian mobile number.'};
  const promoCode=input.promo_code==null?null:String(input.promo_code).trim().toUpperCase();
  if(promoCode&&!/^[A-Z0-9_-]{4,20}$/.test(promoCode))return {error:'Check the promotion code.'};
  return {options:{pickup:input.pickup,drop:input.drop,stops,vehicle,mode,guestName,guestPhone,promoCode}};
}

export async function routeRide(env:Env,options:RideOptions){
  const points=[options.pickup,...options.stops,options.drop];
  let km=0,minutes=0,source='ola',polyline:string|undefined;
  for(let i=1;i<points.length;i++){
    const leg=await routeEstimate(env,points[i-1],points[i],options.vehicle);
    km+=leg.km;minutes+=leg.minutes;
    if(leg.source!=='ola')source=points.length===2?leg.source:'mixed_or_fallback';
    if(points.length===2)polyline=leg.polyline;
  }
  return {km:Math.round(km*100)/100,minutes,source,polyline:polyline||null};
}

export function promotionDiscount(fareRupees:number,type:'flat'|'percent',amount:number,maxDiscount:number):number{
  const raw=type==='flat'?amount:Math.round(fareRupees*amount/100);
  return Math.min(Math.max(0,raw),maxDiscount,Math.max(0,fareRupees-1));
}
