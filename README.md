# Haan · Kolkata pilot

Haan is a ride booking pilot with a public website, two Flutter Android apps, a private operations console, and a Cloudflare Worker API. The customer confirms a fare before booking and can add a pickup note. An approved driver accepts one timed offer, opens Google Maps directions to the pickup, arrives, asks the boarding customer for a four-digit PIN, then opens Google Maps directions to the drop. Both apps show the live trip; the customer sees the driver's photo, vehicle details, plate and call button. Both parties can share the live trip, call 112, and reach support. The driver can mark a no-show five minutes after arrival. At trip end, the customer can pay cash or scan the driver's direct UPI QR when a valid handle is registered. The product does not process or verify payments.

The site and apps are **pilot software**. Real commercial operation needs local licensing, insurance, and legal review first.
The pilot covers request, match, pickup navigation, plate check, boarding PIN, ordered stops, drop navigation, direct payment handoff, rating and support. [PRD.md](PRD.md) records the expanded prototype features and their operational limits.

## Workspace

| Path | Purpose |
| --- | --- |
| `web/` | EN/HI public site, legal/install pages, and `/4632/admin/` console |
| `apps/customer/` | Flutter customer app |
| `apps/rider/` | Flutter rider app and foreground location service |
| `apps/haan_core/` | Shared API, secure sessions, language, theme, map and push setup |
| `worker/` | Hono Worker, Durable Object, KV documents, Neon SQL schema |

## Current infrastructure

The [public site](https://haan-kolkata-pilot.pages.dev/) and [Worker API](https://haan-api.srimantasutapa123.workers.dev/health) are deployed. The `haan-kolkata-pilot` Neon project has `production` and `development` branches. The owner super admin is provisioned at `/4632/admin/login/` with password, authenticator code, idle expiry, role checks and audit; credentials remain in ignored `secrets/admin-onboarding.txt`. Driver registration requires a plate, make/model/colour/year, licence number, expiry dates and document uploads; changing a plate or licence requires renewed review. The expanded prototype adds scheduled requests, two stops, guest bookings, Cab shared/intercity previews, destination filtering, promotions and manual operator subsidy tracking, support triage, and three rider self-cancellations per Kolkata day. Shared mode does not yet match co-passengers, scheduled rides do not reserve a driver, and intercity pricing excludes tolls and return charges. Brevo, Ola Maps, Gemini, Groq and Firebase credentials are configured on the Worker. Real two-device notification delivery still needs a physical-device check before inviting pilot users. See [PROGRESS.md](PROGRESS.md) for current test results.

## Local checks

```sh
npm ci
npm run check
npm test --workspace worker
cd apps/customer && flutter pub get && flutter analyze --no-fatal-infos
cd ../rider && flutter pub get && flutter analyze --no-fatal-infos
```

The website is static: serve `web/` with any local HTTP server. Set `web/config.json` to the deployed Worker URL for the admin console. `web/links.json` points to versioned APK assets in `web/downloads/` (ignored by Git); the page generates its QR codes from those exact URLs. Replace the links with personal Drive URLs after uploading the APKs and the release signing key backup there.

## Secrets and build values

Copy `.env.example` to a private location. Set Worker secrets with `wrangler secret put` or the Cloudflare dashboard. Never commit credentials, the release keystore, or an admin setup key. `SESSION_SECRET` should be at least 32 random bytes, `ADMIN_TOTP_KEY` is a base64url encoded 32-byte AES key, and `DATABASE_URL` is a Neon pooled connection string. The bootstrap script in `worker/scripts/bootstrap-admin.mjs` creates a super admin with a random password and authenticator setup key after the schema is installed.

Build values are passed to Flutter using `--dart-define`: `API_BASE_URL`, `DOWNLOAD_URL`, `FIREBASE_PROJECT_ID`, `FIREBASE_APP_ID`, `FIREBASE_SENDER_ID`, and `FIREBASE_API_KEY`. Firebase app identifiers are public client configuration; the Firebase service account private key belongs only in the Worker secret. The apps contain no Brevo, Ola, Gemini, Groq, database, or Firebase service account secret.

## Deploy order

1. Set up the Neon `production` and `development` branches and run `worker/schema.sql` once on production. Seed only development with `worker/seed.dev.sql`.
2. Create a classic Workers KV namespace for private rider photos; place its ID in `worker/wrangler.jsonc`. Keep documents under 500 KB.
3. Configure nonzero free-tier quotas and Worker secrets, then deploy the Worker and verify `/health` and the fare endpoint. The quotas stop provider calls at 80% of the configured daily allowance. Database, session, and admin TOTP secrets are already set in the deployed Worker.
4. Set `APP_ORIGIN` to the exact Cloudflare Pages origin. Configure the same Worker URL in `web/config.json`.
5. Enroll the already-created super admin in an authenticator and verify the `/4632/admin/` console. A live TOTP login and dashboard request have passed. The path is only obscurity; backend password, TOTP, role checks, 30-minute idle timeout and audit log enforce security.
6. Build and emulator-test both apps with one fixed release signing key. Back the key up securely. Upload signed arm64 APKs to a personal Drive with public download links, then update `web/links.json` and recheck both QR codes. Pages can host verified APKs temporarily until Drive is connected.
7. Deploy `web/` to Cloudflare Pages. Check a fresh Android 8+ device, two-phone trip, Hindi/English flows, weak/offline behavior and Lighthouse before inviting pilot users.

## Design credits

The public design starts from `my-design/haan-home.html` supplied with the brief. Photo attribution is in `web/PHOTO_CREDITS.md`. The route motion and animated sample phrase are examples; a real trip only begins after on-screen confirmation.
