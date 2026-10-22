# Haan · Kolkata pilot

Haan is a ride booking pilot with a public website, two Flutter Android apps, a private operations console, and a Cloudflare Worker API. The customer confirms a fare before booking. An approved rider accepts one timed offer, arrives, enters the customer's PIN, completes the trip, and receives cash or direct UPI. The product does not process payments.

The site and apps are **pilot software**. Real commercial operation needs local licensing, insurance, and legal review first.

## Workspace

| Path | Purpose |
| --- | --- |
| `web/` | EN/HI public site, legal/install pages, and `/4632/admin/` console |
| `apps/customer/` | Flutter customer app |
| `apps/rider/` | Flutter rider app and foreground location service |
| `apps/haan_core/` | Shared API, secure sessions, language, theme, map and push setup |
| `worker/` | Hono Worker, Durable Object, KV documents, Neon SQL schema |

## Current infrastructure

The [public site](https://haan-kolkata-pilot.pages.dev/) and [Worker API](https://haan-api.srimantasutapa123.workers.dev/health) are deployed. The `haan-kolkata-pilot` Neon project has a `production` branch with the schema and a `development` branch with inert test users. The owner super admin is provisioned; credentials remain in the ignored `secrets/admin-onboarding.txt` until enrolled in an authenticator. No live OTP, AI, push, APK download, or public pilot launch should be claimed until the related provider keys and links are configured and tested. `web/links.json` intentionally leaves both downloads unavailable until signed APKs exist on Drive. See [PROVIDER_SETUP.md](PROVIDER_SETUP.md) for the new key setup.

## Local checks

```sh
npm ci
npm run check
npm test --workspace worker
cd apps/customer && flutter pub get && flutter analyze --no-fatal-infos
cd ../rider && flutter pub get && flutter analyze --no-fatal-infos
```

The website is static: serve `web/` with any local HTTP server. Set `web/config.json` to the deployed Worker URL for the admin console. Set real HTTPS Drive URLs in `web/links.json`; the page generates its QR codes from those exact values.

## Secrets and build values

Copy `.env.example` to a private location. Set Worker secrets with `wrangler secret put` or the Cloudflare dashboard. Never commit credentials, the release keystore, or an admin setup key. `SESSION_SECRET` should be at least 32 random bytes, `ADMIN_TOTP_KEY` is a base64url encoded 32-byte AES key, and `DATABASE_URL` is a Neon pooled connection string. The bootstrap script in `worker/scripts/bootstrap-admin.mjs` creates a super admin with a random password and authenticator setup key after the schema is installed.

Build values are passed to Flutter using `--dart-define`: `API_BASE_URL`, `DOWNLOAD_URL`, `FIREBASE_PROJECT_ID`, `FIREBASE_APP_ID`, `FIREBASE_SENDER_ID`, and `FIREBASE_API_KEY`. Firebase app identifiers are public client configuration; the Firebase service account private key belongs only in the Worker secret. The apps contain no Brevo, Ola, Gemini, Groq, database, or Firebase service account secret.

## Deploy order

1. Set up the Neon `production` and `development` branches and run `worker/schema.sql` once on production. Seed only development with `worker/seed.dev.sql`.
2. Create a classic Workers KV namespace for private rider photos; place its ID in `worker/wrangler.jsonc`. Keep documents under 500 KB.
3. Configure nonzero free-tier quotas and Worker secrets, then deploy the Worker and verify `/health` and the fare endpoint. The quotas stop provider calls at 80% of the configured daily allowance. Database, session, and admin TOTP secrets are already set in the deployed Worker.
4. Set `APP_ORIGIN` to the exact Cloudflare Pages origin. Configure the same Worker URL in `web/config.json`.
5. Enroll the already-created super admin in an authenticator and verify the `/4632/admin/` console. A live TOTP login and dashboard request have passed. The path is only obscurity; backend password, TOTP, role checks, 30-minute idle timeout and audit log enforce security.
6. Build both apps with one fixed release signing key. Back the key up securely. Upload signed arm64 APKs to a personal Drive with public download links, then update `web/links.json` and recheck both QR codes.
7. Deploy `web/` to Cloudflare Pages. Check a fresh Android 8+ device, two-phone trip, Hindi/English flows, weak/offline behavior and Lighthouse before inviting pilot users.

## Design credits

The public design starts from `my-design/haan-home.html` supplied with the brief. Photo attribution is in `web/PHOTO_CREDITS.md`. The route motion and animated sample phrase are examples; a real trip only begins after on-screen confirmation.
