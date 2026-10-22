# Haan provider setup

The Haan website, API, database, and admin are deployed. The four keys below are still needed for email sign-in, Ola place search/routing, and the voice assistant. Use the existing accounts, but create **new credentials named Haan**. Keep the accounts on their free plans and decline any request to add billing or a card.

Put each new key in the matching blank line of the ignored local file `secrets/provider-keys.env`. Save the file and tell the builder when it is ready. Do not send keys through chat or commit that file.

1. **Brevo:** Open [API key settings](https://app.brevo.com/settings/keys/api), create a new API key named `Haan Worker`, and copy it once into `BREVO_API_KEY`. In [Senders](https://app.brevo.com/senders), add `srimantasutapa123@gmail.com` as the sender and complete the verification email. This is the sender for OTP mail.
2. **Ola Maps:** Open the [Krutrim Cloud Maps console](https://cloud.olakrutrim.com/console/maps), choose **Credentials → New Credentials**, name it `Haan Worker`, and copy its API key into `OLA_MAPS_API_KEY`. Use the free/default plan; stop if it asks for billing.
3. **Gemini:** Open [Google AI Studio API keys](https://aistudio.google.com/api-keys), create a fresh key for a Haan project, and copy it into `GEMINI_API_KEY`. Leave the project on the free tier.
4. **Groq:** Open [GroqCloud API keys](https://console.groq.com/keys), create a key named `Haan Worker`, and copy it into `GROQ_API_KEY`.

The builder will install these as Cloudflare Worker secrets, choose currently available free models, set conservative daily caps, and run end-to-end checks. Firebase Cloud Messaging setup follows once the dedicated/new versus existing project choice is confirmed. Signed APKs and Drive links follow successful Linux builds.
