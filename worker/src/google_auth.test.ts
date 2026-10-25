import { describe, expect, it } from 'vitest';
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from 'jose';
import { verifyGoogleFirebaseToken } from './google_auth';

describe('Google Firebase token verification', () => {
  it('requires a signed, verified Google token for the right project', async () => {
    const {publicKey,privateKey}=await generateKeyPair('RS256');
    const keys=createLocalJWKSet({keys:[{...await exportJWK(publicKey),kid:'test-key',alg:'RS256'}]});
    const now=Math.floor(Date.now()/1000);
    const make=(claims:Record<string,unknown>)=>new SignJWT({
      email:'person@example.com',email_verified:true,auth_time:now,
      firebase:{sign_in_provider:'google.com'},...claims,
    }).setProtectedHeader({alg:'RS256',kid:'test-key'})
      .setSubject('firebase-user').setIssuer('https://securetoken.google.com/haan-test')
      .setAudience('haan-test').setIssuedAt(now).setExpirationTime(now+3600).sign(privateKey);
    expect(await verifyGoogleFirebaseToken(await make({}),'haan-test',keys))
      .toEqual({email:'person@example.com',uid:'firebase-user'});
    expect(await verifyGoogleFirebaseToken(await make({email_verified:false}),'haan-test',keys)).toBeNull();
    expect(await verifyGoogleFirebaseToken(await make({firebase:{sign_in_provider:'password'}}),'haan-test',keys)).toBeNull();
    expect(await verifyGoogleFirebaseToken(await make({}),'other-project',keys)).toBeNull();
    const other=await generateKeyPair('RS256');
    const forged=await new SignJWT({email:'person@example.com',email_verified:true,auth_time:now,
      firebase:{sign_in_provider:'google.com'}}).setProtectedHeader({alg:'RS256',kid:'test-key'})
      .setSubject('firebase-user').setIssuer('https://securetoken.google.com/haan-test')
      .setAudience('haan-test').setIssuedAt(now).setExpirationTime(now+3600).sign(other.privateKey);
    expect(await verifyGoogleFirebaseToken(forged,'haan-test',keys)).toBeNull();
  });
});
