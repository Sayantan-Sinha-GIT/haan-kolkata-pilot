import { readFileSync } from 'node:fs';
const row = readFileSync(new URL('../secrets/provider-keys.env', import.meta.url), 'utf8').split(/\r?\n/).find(x => x.startsWith('GEMINI_API_KEY='));
if (!row) throw new Error('Gemini key missing');
const key = row.slice('GEMINI_API_KEY='.length).trim();
const model = process.argv[2] || 'gemini-flash-lite-latest';
const start = Date.now();
try {
  const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`, {
    method: 'POST', headers: { 'x-goog-api-key': key, 'Content-Type': 'application/json' },
    body: JSON.stringify({ contents: [{ parts: [{ text: 'Return only this JSON object: {"ok":true}' }] }], generationConfig: { responseMimeType: 'application/json', temperature: 0, maxOutputTokens: 100 } }),
    signal: AbortSignal.timeout(45000),
  });
  const data = await response.json();
  console.log(JSON.stringify({ model, http: response.status, ms: Date.now() - start, result: data.candidates?.[0]?.content?.parts?.[0]?.text?.slice(0, 100) || null, errorCode: data.error?.status || null }));
  if (!response.ok) process.exitCode = 1;
} catch (error) {
  console.log(JSON.stringify({ model, ms: Date.now() - start, error: error.name || 'Error' }));
  process.exitCode = 1;
}
