import { describe, expect, it } from 'vitest';
import { fare, haversineKm, scrubAssistantText, validPoint } from './rules';
import { decryptTotp, encryptTotp, hmac, totp, totpSetupKey } from './crypto';

describe('non-negotiable trip rules',()=>{
  it('rounds fares to rupees and respects the minimum',()=>{
    const bike={base:20,per_km:6,per_min:.5,minimum:30};
    expect(fare(bike,1,2)).toBe(30);
    expect(fare(bike,4.2,12)).toBe(51);
  });
  it('rejects invalid and too-close points before a booking',()=>{
    expect(validPoint({lat:22.57,lng:88.36,text:'Howrah'})).toBe(true);
    expect(validPoint({lat:221,lng:88.36,text:'Howrah'})).toBe(false);
    expect(haversineKm({lat:22.5726,lng:88.3639},{lat:22.573,lng:88.364})).toBeLessThan(.3);
  });
  it('scrubs phone and email before AI receives a phrase',()=>{
    expect(scrubAssistantText('Call 9876543210 or x@y.com for Sealdah')).toBe('Call [phone] or [email] for Sealdah');
  });
});

describe('admin and PIN cryptography',()=>{
  it('generates standard TOTP setup keys and encrypts them at rest',async()=>{
    const bytes=new TextEncoder().encode('12345678901234567890');
    const secret=btoa(String.fromCharCode(...bytes)).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
    expect(totpSetupKey(secret)).toBe('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
    expect(await totp(secret,59_000)).toBe('287082');
    const raw=crypto.getRandomValues(new Uint8Array(32));
    const encoded=btoa(String.fromCharCode(...raw)).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
    const ciphertext=await encryptTotp(encoded,secret);
    expect(ciphertext).not.toContain(secret);
    expect(await decryptTotp(encoded,ciphertext)).toBe(secret);
  });
  it('never uses the plain PIN as its stored verifier',async()=>{
    expect(await hmac('test-secret','1234')).not.toContain('1234');
  });
});
