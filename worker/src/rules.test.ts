import { describe, expect, it } from 'vitest';
import { fare, haversineKm, normalizeVehicleNumber, scrubAssistantText, validCoordinates, validFutureDate, validImageBytes, validPoint, validUpiId } from './rules';
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
    expect(validPoint({lat:Number.NaN,lng:88.36,text:'Howrah'})).toBe(false);
    expect(haversineKm({lat:22.5726,lng:88.3639},{lat:22.573,lng:88.364})).toBeLessThan(.3);
  });
  it('rejects out-of-range rider coordinates and keeps zero valid',()=>{
    expect(validCoordinates(22.5726,88.3639)).toBe(true);
    expect(validCoordinates(0,0)).toBe(true);
    expect(validCoordinates(100,88.36)).toBe(false);
    expect(validCoordinates(22.57,181)).toBe(false);
    expect(validCoordinates('22.57',88.36)).toBe(false);
  });
  it('scrubs phone and email before AI receives a phrase',()=>{
    expect(scrubAssistantText('Call 9876543210 or x@y.com for Sealdah')).toBe('Call [phone] or [email] for Sealdah');
  });
  it('normalizes Indian plates and rejects malformed registration details',()=>{
    expect(normalizeVehicleNumber('wb 12 ab 1234')).toBe('WB12AB1234');
    expect(normalizeVehicleNumber('24 BH 1234 AA')).toBe('24BH1234AA');
    expect(normalizeVehicleNumber('not-a-plate')).toBeNull();
    expect(validFutureDate('2027-01-31','2026-10-25')).toBe(true);
    expect(validFutureDate('2026-02-30','2026-10-25')).toBe(false);
    expect(validFutureDate('2025-01-01','2026-10-25')).toBe(false);
  });
  it('rejects a document whose claimed image type does not match its bytes',()=>{
    const jpeg=Uint8Array.from([0xff,0xd8,1,2,3,4,5,6,7,8,0xff,0xd9]).buffer;
    expect(validImageBytes(jpeg,'image/jpeg')).toBe(true);
    expect(validImageBytes(jpeg,'image/png')).toBe(false);
    expect(validImageBytes(new TextEncoder().encode('not a real jpeg').buffer,'image/jpeg')).toBe(false);
  });
  it('accepts UPI handles without unsafe payment characters',()=>{
    expect(validUpiId('driver.123@upi')).toBe(true);
    expect(validUpiId('bad handle@upi')).toBe(false);
    expect(validUpiId('driver@upi&am=1')).toBe(false);
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
