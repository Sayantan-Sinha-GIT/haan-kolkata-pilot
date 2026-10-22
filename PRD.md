# Product Requirements Document: Ride-Hailing Platform

## 0. What changed

- **Your tool choices are now the spec:** Flutter (two Android apps), OpenStreetMap + Ola Maps, Neon, Firebase for notifications, Cloudflare hosting, Brevo for login/OTP, Gemini + Groq for the assistant, APKs on your personal Drive. The earlier "no tech stack / Vercel / OpenStreetMap only" lines are replaced by these in section 15.
- **Paid or card-gated → fixed:**
  - **Brevo's free plan sends email, not SMS.** Login OTP is therefore email OTP (default). Phone OTP can be added later by swapping one provider.
  - **Ola Maps** moved to prepaid credits on 1 Sep 2026. Free-tier use needs no balance, so: never add credits, cap usage at 80% of the free allowance, cache everything, fall back to OpenStreetMap when the cap is hit (default).
  - **Firebase is used for push notifications only.** Its file storage needs a billing card, and so does Cloudflare R2. Rider document photos go to Cloudflare Workers KV (default; builder confirms it needs no card).
  - **No payment gateway.** Pay cash or UPI straight to the rider.
- **Vague → defined:** "Uber-style smooth" is now a look, a signature moment and a motion level. Fares, matching, PIN, cancellation and low-data mode have numbers. The assistant has limits.
- **Missing → added:** empty, error, slow-network and wrong-input behaviour; GPS off, rider vanishes, double accept, quota exhausted, expired OTP.
- **Risky → fixed:** a secret URL like `/4632/admin` only hides a page, so admin also needs password + 2FA + audit log. The free Gemini tier may learn from inputs, so no personal data reaches it. Operating a real ride service in India needs licences and insurance, so v1 is a pilot or demo.
- **Untestable → testable:** section 16 is pass/fail.

## 1. Summary

An Uber/Rapido-style ride-hailing platform for India:

1. **Website:** feature explainer with app download links and QR codes. No logins.
2. **Customer app** (Flutter, Android): book, track, pay the rider, rate.
3. **Rider app** (Flutter, Android): go online, accept, navigate, complete trips.
4. **Admin panel** (web, secret URL): rider verification, trip monitoring, customer support.
5. **Shared backend** and a **multilingual AI booking assistant** (voice and text; Hindi, English, Hinglish) for customers who are not comfortable with English or with app screens.

**Terms (use everywhere):** *Customer* books. *Rider* drives. *Trip* is one booking from request to completion or cancellation.

## 2. Problem

Ride apps assume English literacy, fast data and comfort with forms. Many Indian commuters think in landmarks ("Sadar bazaar le chalo"), prefer Hindi or speech, and use budget phones on weak networks. Riders need a light app that survives in the background. Operators need to verify riders and resolve complaints.

## 3. Users and roles

| Role | Needs | Can do |
|---|---|---|
| Customer (general) | Fast booking, accurate fare, safety | Book, track, rate, raise tickets |
| Customer (low-literacy / non-English) | Voice booking, Hindi, big buttons, landmarks | Same, via assistant |
| Rider | Simple accept/decline, earnings, low data and battery | Go online, accept, complete trips |
| Admin `super_admin` | Full control | Everything, incl. fares and creating admins |
| Admin `support_agent` | Resolve issues | All except fare config and creating admins |
| Website visitor | Understand, download | Read, download. No account |

## 4. Goals and non-goals

**Goals:** book in under 60 seconds (or by Hindi voice with confirmation); cinematic, map-first UI that stays usable for low-literacy users; dark and light modes; English and Hindi; everything on free tiers; buildable end to end by one builder from this document.

**Non-goals (v1):** Play Store or App Store release, iOS; in-app payment gateway; logins on the website; surge pricing, pooling, scheduled rides, parcels; in-app chat or masked calling (phone dialer instead); languages beyond Hindi and English.

## 5. Features

| ID | Feature | Priority | Key rule |
|---|---|---|---|
| F1 | Email OTP login (Brevo) | Must | 6 digits, 10-min expiry, 5 attempts, 30-s resend cooldown |
| F2 | English/Hindi and Light/Dark/System | Must | Instant switch, saved on device and profile |
| F3 | Map, live GPS, permission explainers | Must | Works with GPS off via manual pickup |
| F4 | Destination search, recents, saved Home/Work | Must | Ola Maps for Indian landmarks; cached |
| F5 | Fare estimate: Bike, Auto, Cab | Must | Formula in section 9 |
| F6 | Book, cancel with reason, rebook | Must | Status machine in section 8 |
| F7 | Matching, one rider at a time | Must | 15 s per offer, max 5, 90 s total |
| F8 | Live tracking and status banner | Must | Smooth marker with heading |
| F9 | 4-digit trip PIN | Must | No PIN, no start |
| F10 | Push notification on every trip change (Firebase) | Must | Works in background |
| F11 | **AI booking assistant** | Must | Limits in section 10 |
| F12 | Rider onboarding and documents | Must | Licence, RC, selfie; each under 500 KB |
| F13 | Rider verification status | Must | Pending / Approved / Rejected with reason |
| F14 | Rider online/offline, foreground location | Must | Persistent notification while online |
| F15 | Incoming request screen | Must | Full screen, sound, vibration, 15-s timer |
| F16 | Rider navigation to pickup and drop | Must | In-app route; "open in maps app" fallback |
| F17 | Admin login at secret URL | Must | Password + TOTP, 30-min idle timeout |
| F18 | Rider verification queue | Must | Approve/reject sends push and email |
| F19 | Users, trips, block, force-cancel, notes | Must | All audit-logged |
| F20 | Support tickets | Must | Open / In progress / Resolved |
| F21 | Website: landing, downloads with QR, install guide EN/HI, privacy, terms, contact | Must | No login; admin never linked |
| F22 | Trip history and receipts | Should | Cached offline |
| F23 | Ratings both ways | Should | 1-5 stars, optional comment |
| F24 | SOS: share live trip link, 112 shortcut | Should | Prompts for emergency contact if missing |
| F25 | Rider earnings | Should | Today/week, cash collected |
| F26 | Low-data mode (rider) | Should | Location every 5 s moving, 15 s idle, batch on poor network |
| F27 | Editable fare config | Should | No redeploy; `super_admin` only |
| F28 | Admin dashboard and quota counters | Should | Ola, Gemini, Groq, email, storage usage; alert at 80% |
| F29 | Force-update screen | Should | Needed because there is no Play Store |
| F30 | Account deletion | Should | Trips anonymised |
| F31 | Rider's UPI QR at trip end | Nice | Display only |
| F32 | More Indian languages | Nice | Prompt and string change only |

## 6. Main user flows

**6.1 Customer books a ride**
1. First launch: pick language, enter email, enter OTP, set name.
2. Home: full-screen map and "Where to?" sheet. Pickup defaults to GPS and is editable.
3. Search or tap the map. Pick Bike, Auto or Cab; see fare, distance, ETA.
4. Tap **Book**; a radar pulse plays while searching.
5. Rider accepts: name, vehicle number, rating, ETA, PIN, call, cancel.
6. Track rider to pickup, then to drop. At trip end: fare summary, pay cash or UPI to rider, rate.
7. Trip appears in history with receipt.

**6.2 AI-assisted booking**
1. Tap the prominent mic. Speak or type: "Mujhe station jaana hai."
2. Assistant extracts pickup, destination, vehicle. If unclear it asks one short question in the same language ("Howrah ya Sealdah?") with up to 3 tappable options.
3. It reads back aloud and in large text: destination, vehicle, fare, with big **Haan / Nahi** buttons.
4. Only after **Haan** does normal booking (6.1 step 4) begin.

**6.3 Rider completes a trip**
1. Sign up, fill profile, upload documents. Status: Pending.
2. After approval: **Go Online**. Offer shows pickup distance, trip distance, fare, 15-s countdown, Accept/Decline.
3. Navigate to pickup, tap **Arrived**, enter the customer's PIN to **Start**, navigate, **End trip**, collect payment, rate customer.
4. Earnings screen shows the day.

**6.4 Admin support**
1. Open the secret URL; log in with password and TOTP. Search by trip ID, email, phone, vehicle number.
2. Open a trip: timeline, route, fare breakdown, assistant transcript summary. Add note, force-cancel, block/unblock, approve/reject documents, answer tickets.

**6.5 Edge cases (all flows)**

| Situation | Required behaviour |
|---|---|
| Empty (no trips, places, tickets, pending riders) | Illustrated empty state with one next action |
| Slow network | Skeleton loaders, never a blank screen; database wake-up (~2 s) hidden by skeletons |
| No network | Retry banner; cached history readable; booking disabled with reason |
| Wrong or expired OTP | Inline message with attempts left; "Resend" |
| Wrong PIN | Shake; 5 wrong tries lock Start; customer may cancel free |
| Destination not found | Suggest nearby landmarks; allow dropping a map pin |
| Pickup equals drop, or under 300 m | Block with message |
| Customer already has an active trip | Show it; block a second booking |
| GPS off or permission denied | Explainer; customer can pick manually; rider cannot go online |
| No rider found in 90 s | Message, "Try again" and "Try another vehicle" |
| Rider app dies mid-trip | Customer sees "Rider connection lost"; admin alerted after 5 min |
| Customer cancels after acceptance | Free within 2 min; later only a recorded note |
| Ola, AI or email quota reached | Friendly message; maps fall back to OpenStreetMap; assistant falls back to manual flow |
| Rider rejected | Reason shown; can fix and resubmit |
| App version too old | Blocking update screen with download link |

## 7. Pages and screens

| Surface | Screens |
|---|---|
| Customer app | Language, email, OTP, name, home map, destination search, vehicle choice, finding rider, rider assigned (PIN), live trip, summary and rating, assistant (mic, confirm), history, receipt, saved places, help and tickets, profile (emergency contact, delete), settings, update required |
| Rider app | Email, OTP, profile, documents, verification status, home (online toggle), incoming request, to pickup, PIN entry, to drop, end trip and collect, earnings, history, help, settings, update required |
| Website | One long landing page (hero, how it works, features, for riders, downloads with QR, FAQ, footer) plus install guide, privacy, terms, contact. EN/HI and theme toggles |
| Admin | Login + TOTP, dashboard, rider queue and detail, users, trips and detail, tickets, fare config, audit log, quota counters |

## 8. Data

Every table: UUID id, created_at, updated_at.

| Table | Key fields | Rules |
|---|---|---|
| users | role, email (unique), phone, name, language, theme, push_token, is_blocked, deleted_at | Phone collected, not verified in v1 |
| rider_profiles | user, vehicle_type, vehicle_number, document keys, verification_status, rejection_reason, is_online, last location, rating_avg | Only Approved riders go online; documents readable by admins only via short-lived links |
| otp_codes | email, code_hash, expires_at, attempts, consumed_at | Hashed; deleted after 24 h |
| sessions | user, refresh_token_hash, device, expires_at, revoked_at | Access 15 min, refresh 30 days, rotated |
| trips | customer, rider, status, vehicle_type, pickup/drop (lat, lng, text), est and final distance, duration, fare, pin_hash, timestamps, cancelled_by, cancel_reason, via_assistant | Transitions checked server-side only |
| trip_offers | trip, rider, offered_at, responded_at, response | accepted / declined / timeout |
| trip_locations | trip, lat, lng, recorded_at | Sampled; purged after 30 days |
| ratings | trip, from, to, stars, comment | One per direction per trip |
| saved_places | user, label, lat, lng, text | Max 10 per user |
| fare_config | vehicle_type, base, per_km, per_min, minimum, updated_by | `super_admin` edits |
| tickets, ticket_messages | user, trip (optional), subject, status, messages | Max 2,000 characters per message |
| admin_audit_log | admin, action, entity, details, ip | Append-only |
| assistant_logs | user, language, transcript text, intent, confidence | Text only, never audio; purged after 30 days |

**Trip status:** `searching` → `accepted` → `arrived` → `in_progress` → `completed`. Exits: `cancelled`, `no_riders_found`. Nothing else. Index trips by customer and rider, and riders by online status and location. Keep rows lean: Neon's free storage is small.

## 9. Rules that must never break

1. **Fare:** `max(minimum, base + per_km × km + per_min × min)`, rounded to the rupee. Final fare never exceeds estimate × 1.5 unless an admin overrides with a note. Defaults, all editable: Bike ₹20 / ₹6 per km / ₹0.5 per min / min ₹30; Auto ₹30 / ₹10 / ₹1 / min ₹40; Cab ₹50 / ₹14 / ₹1.5 / min ₹80 (default).
2. **One rider wins:** accepting is one atomic update; two riders can never hold the same trip.
3. **Matching:** 2 km radius, widening to 5 km after 20 s; 15 s per rider; max 5 offers; 90 s total. Three declines/timeouts in a row set a rider offline.
4. **PIN:** 4 digits, hashed, new per trip, never shown to the rider.
5. **Authorization:** customers see only their trips; riders only assigned trips; every admin call checks role. Support agents cannot change fares or admins.
6. **Admin security:** the path (example `/4632/admin`) is a setting, not security. Also required: hashed password, TOTP, 5 login attempts per 15 min per IP, noindex, never linked, every action audit-logged.
7. **Secrets:** only in backend secrets; never in an app, the website or the repo. `.env.example` provided.
8. **Privacy:** location points and AI transcripts purged after 30 days; account deletion works; privacy policy discloses all of it.
9. **No money moves through the product.** Cash or direct UPI to the rider only.
10. **Rate limits:** OTP (per email and IP), assistant (20 calls/hour/user), login.
11. **Active trip blocks account deletion** until it ends.
12. **Never add credits or a card** to any service; usage stops at the free cap and degrades gracefully.

## 10. AI features

**Pipeline (backend only; apps never hold AI keys):** record up to 15 s or take typed text → speech-to-text with Groq → Gemini returns structured output (intent, pickup, destination, vehicle, language, needs_clarification, confidence) → place lookup via Ola Maps → confirmation read aloud with the phone's built-in text-to-speech → booking only after **Haan**.

**Limits and fallbacks**
- Gemini fails or is rate-limited → Groq's language model with the same prompt. Both fail, or confidence is low → "Sorry, I couldn't understand. Please type or pick on the map" in the user's language, then the manual flow opens.
- Cache common phrase-to-place results per city. Global quota counter; friendly message when exhausted.

**The assistant must never**
- Book, cancel or pay without explicit on-screen confirmation.
- Do anything beyond these intents: `book_ride`, `cancel_ride`, `check_status`, `help`, `unknown`.
- Obey instructions hidden in speech or text (prompt injection is ignored).
- Receive or reveal phone numbers, full names, exact home addresses or other users' data; it has no database access.
- Give medical, legal or financial advice or chat off-topic ("I can only help with rides").
- Keep audio. Transcripts are text, stored 30 days, disclosed in the privacy policy.

Hindi, English and Hinglish are required.

## 11. Look and feel

- **Mood:** cinematic, kinetic, nocturnal, tactile, editorial.
- **Feels like:** spacex.com, apple.com iPhone product pages, nothing.tech.
- **Motion intensity: 10 (cinematic)** on the website, both apps and admin. Professional AND cinematic. Respect the device's reduced-motion setting.
- **Display font** must have real character (never a plain default sans), paired with a clean body font with full Devanagari support. The builder picks exact colours and fonts from the references above.
- **Dark first**, light mode fully tuned; dark map style in dark mode.
- A **living background** behind every page (slow city-night map, drifting route lines, soft light trails). No area is just text on a flat colour.
- **Real pictures on every page:** app screenshots, device mockups, free-licence photos of Indian streets and rides, with credits kept in one file.
- **Apps:** map-first, bottom sheets with spring physics, marker gliding with heading, route line drawing in, shared-element transitions, press micro-interactions, Lottie for success and empty states. Customer and Rider apps use different accent colours. Touch targets at least 48 dp; strong icons for low-literacy users.
- **Rider offer screen:** motion must never delay or hide Accept/Decline.

## 12. Signature moment

**The one moment (website hero, reused in the customer app's first run):** a phone shows the assistant. The visitor taps one of three sample phrases ("Mujhe station jaana hai", "Sadar bazaar le chalo", "Take me to the airport"). A sound wave becomes text, a pin drops on a night-city map, the route draws, the fare appears, **Haan** pulses, and a rider marker glides toward the pickup. Under 8 seconds; works without sound.

**Scroll moments, first screen to footer**
1. **First screen:** the night map wakes up; route lines draw as you scroll; the headline settles over the moving background.
2. **Speak:** the phone pins in place and steps through voice-to-booking as you scroll.
3. **Follow:** a rider marker travels along a route running down the page, tied to scroll position.
4. **Safe:** four PIN digits flip in one by one; SOS and safety features slide over photos.
5. **Footer:** the route ends at the two download blocks; the marker "arrives" at the QR codes while city lights drift in parallax behind the footer.

## 13. Platforms and devices

- Apps: Android 8+, mid-range phones; APK under about 25 MB per ABI (split per ABI, arm64 offered); cold start under 3 s; release APKs signed with one fixed key, backed up.
- Website and admin: responsive in current Chrome, Edge, Safari, Firefox; admin designed for desktop.
- No iOS. APKs live on your personal Drive; links and QR codes come from one `links.json` so they change without code edits. The install guide (English and Hindi, with screenshots) explains "unknown sources" and Drive's scan warning on large files.

## 14. Languages and accessibility

- English and Hindi everywhere, no hardcoded strings; natural Hindi, not word-for-word; dates, numbers and ₹ per locale.
- Text scaling, AA contrast, screen-reader labels, status never by colour alone, voice input and read-aloud in the assistant, large buttons.

## 15. Constraints

- Free tiers only. No credit card anywhere.
- The owner is not technical; the builder sets up and deploys everything.
- Code on GitHub (Sayantan-Sinha-GIT). Websites and backend hosted on Cloudflare.
- AI features, if any: Gemini API free tier, Groq as fallback. Maps, if any: OpenStreetMap for map display, Ola Maps for Indian landmark search and routing.
- Payments, if any: test mode only.

**Chosen tools:** Flutter for both apps (shared package for theme, models, API client); Cloudflare Pages for website and admin; Cloudflare Workers for the API, with Durable Objects for live trip updates (polling every 3-5 s as fallback); Neon Postgres; Firebase Cloud Messaging for push only; Brevo for email OTP and email alerts; Cloudflare Workers KV for rider document photos (default); Drive for APKs.

Also: cache map and search results and respect OpenStreetMap tile rules and attribution; never use the public routing demo server; apps never call AI, email or Ola directly; Cloudflare Cron handles expiring requests, stale sessions, OTP cleanup, data purges; separate dev and prod environments (Neon branches); seed data (test customers, riders, fares), a README per package and `.env.example` included; v1 is a pilot or demo (licences, insurance and data-protection law need a lawyer before real commercial use).

## 16. Success criteria

| # | Check | Pass when |
|---|---|---|
| 1 | Install | A fresh phone installs both apps from the website via the guide |
| 2 | Booking speed | A new customer books within 60 s of first sign-in |
| 3 | Voice booking | 8 of 10 Hindi, English and Hinglish test phrases give the right summary; zero bookings without Haan |
| 4 | Full trip | Two phones complete request → accept → PIN → end → rating |
| 5 | Tracking | Rider marker moves without visible jumps on a normal connection |
| 6 | One winner | 10 simultaneous accepts: exactly one succeeds |
| 7 | Background offers | A rider with the app in background receives and answers an offer |
| 8 | Admin | Locks after 5 wrong passwords; TOTP required; every action in the audit log |
| 9 | Languages and themes | Both languages and both themes on every screen; no untranslated text or unreadable contrast |
| 10 | Failure handling | With network off or any quota hit, every screen shows a message, never a blank or crash |
| 11 | Secrets | Zero keys in an APK, the website or the public repo |
| 12 | Website | No login anywhere; both QR codes open the right Drive download; Lighthouse performance 90+ on mobile |
| 13 | Visuals | Every page has a living background and real pictures; signature moment and all 5 scroll moments work |
| 14 | Cost | No service asked for a card or credits |

## 17. Open questions

| Question | Answer |
|---|---|
| Launch city? | Kolkata (default); landmark examples follow it |
| Phone OTP? | Email now; provider swappable later (default) |
| Rider document storage? | Workers KV, private, short-lived links (default) |
| What if Ola's free cap runs out? | Fall back to OpenStreetMap search and straight-line fare distance × 1.3 (default) |
| Calling rider or customer? | Phone dialer (default) |
| Cancellation fee? | Recorded note only; no collection in v1 (default) |
| Rider's UPI details? | Rider's own UPI ID, shown only (default) |
| Who runs support? | The owner as `super_admin`; extra agents optional (default) |
| Product name and logo? | Working name "Ride-Hailing Platform"; builder proposes one name and a simple logo (default) |
| Admin URL? | `/4632/admin` as the default value of a setting the owner can change (default) |
