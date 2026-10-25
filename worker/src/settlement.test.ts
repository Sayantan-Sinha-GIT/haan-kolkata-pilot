import { describe, expect, it } from 'vitest';
import { settlementForFare } from './settlement';

describe('20% final-fare settlement', () => {
  it('splits an unpromoted fare exactly', () => {
    expect(settlementForFare(100,100)).toEqual({
      platformFee:20,riderEarnings:80,promotionTopup:0,netDueToPlatform:20,
    });
  });
  it('uses customer final fare for commission and preserves rider earnings', () => {
    expect(settlementForFare(100,80)).toEqual({
      platformFee:16,riderEarnings:80,promotionTopup:16,netDueToPlatform:0,
    });
    expect(settlementForFare(100,50)).toEqual({
      platformFee:10,riderEarnings:80,promotionTopup:40,netDueToPlatform:-30,
    });
  });
  it('keeps rounded rupee totals consistent', () => {
    for(let gross=1;gross<500;gross++)for(let due=1;due<=gross;due++){
      const s=settlementForFare(gross,due);
      expect(s.platformFee+s.riderEarnings-s.promotionTopup).toBe(due);
      expect(s.netDueToPlatform).toBe(due-s.riderEarnings);
    }
  });
  it('rejects impossible fares', () => {
    expect(()=>settlementForFare(100,101)).toThrow();
    expect(()=>settlementForFare(100,0)).toThrow();
  });
});
