import { readFileSync, writeFileSync } from 'node:fs';
const provider=Object.fromEntries(readFileSync(new URL('../secrets/provider-keys.env',import.meta.url),'utf8').split(/\r?\n/)
  .filter(line=>/^[A-Z_]+=/.test(line)).map(line=>[line.slice(0,line.indexOf('=')),line.slice(line.indexOf('=')+1).trim()]));
for(const name of ['BREVO_API_KEY','OLA_MAPS_API_KEY','GEMINI_API_KEY','GROQ_API_KEY'])if(!provider[name])throw new Error(`${name} missing`);
const firebase=JSON.parse(readFileSync(new URL('../secrets/firebase-service-account.json',import.meta.url),'utf8'));
if(firebase.project_id!=='haan-kolkata-pilot-2026'||firebase.type!=='service_account')throw new Error('Unexpected Firebase project');
const values={
  BREVO_API_KEY:provider.BREVO_API_KEY,
  BREVO_SENDER_EMAIL:'srimantasutapa123@gmail.com',
  OLA_MAPS_API_KEY:provider.OLA_MAPS_API_KEY,
  GEMINI_API_KEY:provider.GEMINI_API_KEY,
  GEMINI_MODEL:'gemini-flash-lite-latest',
  GROQ_API_KEY:provider.GROQ_API_KEY,
  GROQ_CHAT_MODEL:'openai/gpt-oss-20b',
  GROQ_STT_MODEL:'whisper-large-v3-turbo',
  FIREBASE_PROJECT_ID:firebase.project_id,
  FIREBASE_CLIENT_EMAIL:firebase.client_email,
  FIREBASE_PRIVATE_KEY:firebase.private_key,
};
writeFileSync(new URL('../secrets/worker-provider-secrets.json',import.meta.url),JSON.stringify(values),{mode:0o600});
console.log(`Prepared ${Object.keys(values).length} Worker secrets in an ignored local file.`);
