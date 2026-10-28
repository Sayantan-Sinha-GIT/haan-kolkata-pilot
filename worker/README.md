# Haan Worker API

The Hono Worker owns OTP, sessions, trip rules, matching, fares, assistant calls, place search/routing, rider documents, admin actions and maintenance cron. Neon Postgres stores transactional data; a SQLite-backed Durable Object fans out live trip events and advances timed matching; Workers KV stores rider images. The free plan uses hard daily caps with 80% cutoffs for paid-capable external providers.

Run `npm ci`, `npm run check`, and `npm test`. Run `npx wrangler deploy --dry-run` to check bundling. The deployed pilot's KV namespace, `APP_ORIGIN`, and provider caps are recorded in `wrangler.jsonc`; Worker credentials remain in Cloudflare secrets. Apply new SQL files from `migrations/` to the intended Neon branch before deploying code that needs them. `schema.sql` is for a fresh database and is not idempotent. `seed.dev.sql` is only for development.

The admin bootstrap script needs `DATABASE_URL` and `HAAN_ADMIN_EMAIL` in its process environment. It writes its one-time password, authenticator setup key, and `ADMIN_TOTP_KEY` to an ignored `secrets/admin-onboarding.txt`. Move those credentials to a private password manager and remove the file after setup. Run it once for the owner; the admin console can then create support agents.
