import { createPrivateKey, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';

const file = new URL('../secrets/provider-keys.env', import.meta.url);
const entries = Object.fromEntries(readFileSync(file, 'utf8').split(/\r?\n/)
  .filter(line => line.trim() && !line.trim().startsWith('#'))
  .map(line => {
    const index = line.indexOf('=');
    if (index < 1) throw new Error('Invalid provider environment line');
    return [line.slice(0, index).trim(), line.slice(index + 1).trim()];
  }));
const names = ['BREVO_API_KEY', 'OLA_MAPS_API_KEY', 'GEMINI_API_KEY', 'GROQ_API_KEY'];
for (const name of names) {
  if (!entries[name] || /^(your_|replace|paste|<|\.\.\.|TODO)/i.test(entries[name])) throw new Error(`${name}: missing or placeholder`);
  if (/\s/.test(entries[name])) throw new Error(`${name}: contains whitespace`);
}

async function probe(name, makeRequest, check = async response => ({ ok: response.ok })) {
  try {
    const response = await makeRequest();
    const result = await check(response);
    console.log(JSON.stringify({ provider: name, http: response.status, ...result }));
    return response.ok && result.ok !== false;
  } catch (error) {
    console.log(JSON.stringify({ provider: name, error: error.name || 'Error' }));
    return false;
  }
}

const results = [];
results.push(await probe('brevo-account', () => fetch('https://api.brevo.com/v3/account', {
  headers: { 'api-key': entries.BREVO_API_KEY }, signal: AbortSignal.timeout(12000),
})));
results.push(await probe('brevo-sender', () => fetch('https://api.brevo.com/v3/senders', {
  headers: { 'api-key': entries.BREVO_API_KEY }, signal: AbortSignal.timeout(12000),
}), async response => {
  if (!response.ok) return { ok: false };
  const data = await response.json();
  const sender = data.senders?.find(x => x.email?.toLowerCase() === 'srimantasutapa123@gmail.com');
  return { ok: Boolean(sender?.active), present: Boolean(sender), active: Boolean(sender?.active) };
}));
results.push(await probe('ola-autocomplete', () => {
  const url = new URL('https://api.olamaps.io/places/v1/autocomplete');
  url.searchParams.set('input', 'Howrah Railway Station');
  url.searchParams.set('location', '22.5726,88.3639');
  url.searchParams.set('api_key', entries.OLA_MAPS_API_KEY);
  return fetch(url, { headers: { 'X-Request-Id': crypto.randomUUID() }, signal: AbortSignal.timeout(12000) });
}, async response => {
  if (!response.ok) return { ok: false };
  const data = await response.json();
  return { ok: Array.isArray(data.predictions) && data.predictions.length > 0, predictions: data.predictions?.length || 0 };
}));
results.push(await probe('gemini-models', () => fetch('https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000', {
  headers: { 'x-goog-api-key': entries.GEMINI_API_KEY }, signal: AbortSignal.timeout(12000),
}), async response => {
  if (!response.ok) return { ok: false };
  const data = await response.json();
  const models = data.models?.filter(x => x.supportedGenerationMethods?.includes('generateContent')).map(x => x.name.replace(/^models\//, '')) || [];
  return { ok: models.length > 0, models: models.filter(x => /flash/i.test(x)).slice(0, 12) };
}));
results.push(await probe('groq-models', () => fetch('https://api.groq.com/openai/v1/models', {
  headers: { Authorization: `Bearer ${entries.GROQ_API_KEY}` }, signal: AbortSignal.timeout(12000),
}), async response => {
  if (!response.ok) return { ok: false };
  const data = await response.json();
  const models = data.data?.map(x => x.id) || [];
  return { ok: models.length > 0, chat: models.filter(x => /llama|qwen|gemma|gpt-oss/i.test(x)).slice(0, 12), speech: models.filter(x => /whisper/i.test(x)) };
}));

const service = JSON.parse(readFileSync(new URL('../secrets/firebase-service-account.json', import.meta.url), 'utf8'));
if (service.type !== 'service_account' || service.project_id !== 'haan-kolkata-pilot-2026') throw new Error('Firebase project/type mismatch');
const encoded = value => Buffer.from(JSON.stringify(value)).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const claim = `${encoded({ alg: 'RS256', typ: 'JWT' })}.${encoded({ iss: service.client_email, scope: 'https://www.googleapis.com/auth/firebase.messaging', aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600 })}`;
const signature = sign('RSA-SHA256', Buffer.from(claim), createPrivateKey(service.private_key)).toString('base64url');
results.push(await probe('firebase-oauth', () => fetch('https://oauth2.googleapis.com/token', {
  method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${claim}.${signature}` }),
  signal: AbortSignal.timeout(12000),
}), async response => {
  if (!response.ok) return { ok: false };
  const data = await response.json();
  return { ok: Boolean(data.access_token), tokenIssued: Boolean(data.access_token) };
}));

if (process.argv.includes('--active')) {
  const system = 'Extract a Kolkata ride request as JSON with keys intent, pickup, destination, vehicle, language, needs_clarification, confidence. Use book_ride for bookings, vehicle Bike/Auto/Cab/null, and language en/hi/hinglish. Never invent a missing pickup or destination.';
  results.push(await probe('brevo-send', () => fetch('https://api.brevo.com/v3/smtp/email', {
    method: 'POST', headers: { 'api-key': entries.BREVO_API_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ sender: { name: 'Haan', email: 'srimantasutapa123@gmail.com' }, to: [{ email: 'srimantasutapa123@gmail.com' }], subject: 'Haan email integration check', textContent: 'Haan email delivery is being tested. No action is needed.' }),
    signal: AbortSignal.timeout(12000),
  })));
  results.push(await probe('ola-directions', () => {
    const url = new URL('https://api.olamaps.io/routing/v1/directions/basic');
    url.searchParams.set('origin', '22.5726,88.3639');
    url.searchParams.set('destination', '22.5839,88.3425');
    url.searchParams.set('mode', 'driving');
    url.searchParams.set('api_key', entries.OLA_MAPS_API_KEY);
    return fetch(url, { method: 'POST', headers: { 'X-Request-Id': crypto.randomUUID() }, signal: AbortSignal.timeout(12000) });
  }, async response => {
    if (!response.ok) return { ok: false };
    const data = await response.json();
    return { ok: Boolean(data.routes?.[0]?.legs?.[0]?.distance), routes: data.routes?.length || 0 };
  }));
  results.push(await probe('gemini-generate', () => fetch('https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-lite-latest:generateContent', {
    method: 'POST', headers: { 'x-goog-api-key': entries.GEMINI_API_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ systemInstruction: { parts: [{ text: system }] }, contents: [{ parts: [{ text: 'Take me from Howrah Station to Victoria Memorial by auto.' }] }], generationConfig: { temperature: 0, responseMimeType: 'application/json' } }),
    signal: AbortSignal.timeout(20000),
  }), async response => {
    if (!response.ok) return { ok: false };
    const data = await response.json();
    const result = JSON.parse(data.candidates?.[0]?.content?.parts?.[0]?.text || '{}');
    return { ok: result.intent === 'book_ride' && Boolean(result.destination), intent: result.intent, destinationPresent: Boolean(result.destination) };
  }));
  results.push(await probe('groq-chat', () => fetch('https://api.groq.com/openai/v1/chat/completions', {
    method: 'POST', headers: { Authorization: `Bearer ${entries.GROQ_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: 'openai/gpt-oss-20b', temperature: 0, response_format: { type: 'json_object' }, messages: [{ role: 'system', content: system }, { role: 'user', content: 'Mujhe Sealdah se Howrah auto se jaana hai.' }] }),
    signal: AbortSignal.timeout(20000),
  }), async response => {
    if (!response.ok) return { ok: false };
    const data = await response.json();
    const result = JSON.parse(data.choices?.[0]?.message?.content || '{}');
    return { ok: result.intent === 'book_ride' && Boolean(result.destination), intent: result.intent, destinationPresent: Boolean(result.destination) };
  }));
}

if (results.some(result => !result)) process.exitCode = 1;
