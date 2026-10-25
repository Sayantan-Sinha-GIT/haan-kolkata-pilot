import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from 'jose';

const firebaseKeys = createRemoteJWKSet(new URL(
  'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com',
));

export async function verifyGoogleFirebaseToken(
  token: string, projectId: string, keys: JWTVerifyGetKey = firebaseKeys,
): Promise<{ email: string; uid: string } | null> {
  if (!projectId || token.length > 8192 || token.split('.').length !== 3) return null;
  try {
    const { payload, protectedHeader } = await jwtVerify(token, keys, {
      issuer: `https://securetoken.google.com/${projectId}`,
      audience: projectId,
      algorithms: ['RS256'],
    });
    const now = Math.floor(Date.now() / 1000);
    const provider = payload.firebase as { sign_in_provider?: unknown } | undefined;
    const email = typeof payload.email === 'string' ? payload.email.trim().toLowerCase() : '';
    if (protectedHeader.alg !== 'RS256' || !protectedHeader.kid ||
      !payload.sub || payload.sub.length > 128 || !email || payload.email_verified !== true ||
      provider?.sign_in_provider !== 'google.com' ||
      typeof payload.iat !== 'number' || payload.iat > now ||
      typeof payload.auth_time !== 'number' || payload.auth_time > now) return null;
    return { email, uid: payload.sub };
  } catch { return null; }
}
