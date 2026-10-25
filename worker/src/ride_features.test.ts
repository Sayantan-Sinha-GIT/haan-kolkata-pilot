import {describe,it,expect,vi} from 'vitest';
vi.mock('./services',()=>({routeEstimate:vi.fn()}));
import {parseRideOptions,promotionDiscount} from './ride_features';

const pickup={lat:22.5726,lng:88.3639,text:'Esplanade'};
const drop={lat:22.5839,lng:88.3425,text:'Victoria Memorial'};

describe('prototype ride options',()=>{
  it('accepts two ordered stops and a guest passenger',()=>{
    const first={lat:22.576,lng:88.358,text:'Park Street'};
    const second={lat:22.58,lng:88.351,text:'Maidan'};
    const parsed=parseRideOptions({pickup,drop,vehicle:'Cab',stops:[first,second],
      guest:{name:'Guest Rider',phone:'9876543210'},promo_code:'kolkata50'});
    expect('options' in parsed).toBe(true);
    if('options' in parsed){expect(parsed.options.stops).toHaveLength(2);expect(parsed.options.guestPhone).toBe('9876543210');expect(parsed.options.promoCode).toBe('KOLKATA50');}
  });
  it('rejects duplicate stops, extra stops and bad guest numbers',()=>{
    expect('error' in parseRideOptions({pickup,drop,vehicle:'Cab',stops:[pickup]})).toBe(true);
    expect('error' in parseRideOptions({pickup,drop,vehicle:'Cab',stops:[drop,drop,drop]})).toBe(true);
    expect('error' in parseRideOptions({pickup,drop,vehicle:'Cab',guest:{name:'Friend',phone:'1234'}})).toBe(true);
  });
  it('keeps preview modes on Cab and intercity distances bounded',()=>{
    expect('error' in parseRideOptions({pickup,drop,vehicle:'Bike',mode:'shared_preview'})).toBe(true);
    expect('error' in parseRideOptions({pickup,drop,vehicle:'Cab',mode:'intercity'})).toBe(true);
    expect('options' in parseRideOptions({pickup,drop:{lat:22.9,lng:88.3,text:'Barrackpore'},vehicle:'Cab',mode:'intercity'})).toBe(true);
  });
  it('caps promotional discounts and keeps a payable rupee',()=>{
    expect(promotionDiscount(300,'percent',20,100)).toBe(60);
    expect(promotionDiscount(300,'flat',500,200)).toBe(200);
    expect(promotionDiscount(30,'flat',100,100)).toBe(29);
  });
});
