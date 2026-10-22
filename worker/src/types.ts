export interface Env {
  DATABASE_URL: string;
  SESSION_SECRET: string;
  ADMIN_TOTP_KEY: string;
  BREVO_API_KEY?: string;
  BREVO_SENDER_EMAIL?: string;
  OLA_MAPS_API_KEY?: string;
  GEMINI_API_KEY?: string;
  GEMINI_MODEL?: string;
  GROQ_API_KEY?: string;
  GROQ_CHAT_MODEL?: string;
  GROQ_STT_MODEL?: string;
  FIREBASE_PROJECT_ID?: string;
  FIREBASE_CLIENT_EMAIL?: string;
  FIREBASE_PRIVATE_KEY?: string;
  APP_ORIGIN: string;
  OLA_DAILY_FREE_CAP: string;
  GEMINI_DAILY_FREE_CAP: string;
  GROQ_DAILY_FREE_CAP: string;
  BREVO_DAILY_FREE_CAP: string;
  DOCUMENTS: KVNamespace;
  TRIP_ROOM: DurableObjectNamespace;
}

export type Role = 'customer' | 'rider' | 'super_admin' | 'support_agent';
export type Principal = { id: string; role: Role; email: string; is_blocked: boolean };
export type App = { Bindings: Env; Variables: { user: Principal } };

