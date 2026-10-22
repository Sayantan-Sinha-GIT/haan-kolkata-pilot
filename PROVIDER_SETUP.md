# Haan provider setup

The Haan website, API, database, and admin are deployed. The four keys below are still needed for email sign-in, Ola place search/routing, and the voice assistant. Use the existing accounts, but create **new credentials named Haan**. Keep the accounts on their free plans and decline any request to add billing or a card.

Put each new key in the matching blank line of the ignored local file `secrets/provider-keys.env`. Save the file and tell the builder when it is ready. Do not send keys through chat or commit that file.

1. **Brevo:** In your account menu open **Settings → SMTP & API → API Keys & MCP**, choose **Generate a new API key**, complete Brevo's identity check, name it `Haan Worker`, choose its expiry, and click **Generate**. Copy the API key shown once into `BREVO_API_KEY` (do not turn on the separate MCP key option). Then open **Settings → Senders, Domains, IPs → Senders**, choose **Add a sender**, use From name `Haan` and From email `srimantasutapa123@gmail.com`, save, and enter the six-digit verification code sent to that inbox. This is the sender for OTP mail. A free Gmail sender may be rewritten by Brevo for deliverability; we will verify a real OTP email before launch.
2. **Ola Maps:** Open the [Krutrim Cloud Maps console](https://cloud.olakrutrim.com/console/maps), choose **Credentials → New Credentials**, name it `Haan Worker`, and copy its API key into `OLA_MAPS_API_KEY`. Use the free/default plan; stop if it asks for billing.
3. **Gemini:** Open [Google AI Studio API keys](https://aistudio.google.com/api-keys), create a fresh key for a Haan project, and copy it into `GEMINI_API_KEY`. Leave the project on the free tier.
4. **Groq:** Open [GroqCloud API keys](https://console.groq.com/keys), create a key named `Haan Worker`, and copy it into `GROQ_API_KEY`.

5. **Firebase Cloud Messaging:** The dedicated Spark project is already created: `haan-kolkata-pilot-2026`. Open its [Service accounts page](https://console.firebase.google.com/project/haan-kolkata-pilot-2026/settings/serviceaccounts/adminsdk), click **Generate new private key**, then **Generate key**. Move the downloaded JSON file into this repository's ignored `secrets` folder and name it `firebase-service-account.json`. Never paste its contents into chat or commit it. Confirm the JSON's `project_id` is `haan-kolkata-pilot-2026`. Also check that [Cloud Messaging API](https://console.firebase.google.com/project/haan-kolkata-pilot-2026/settings/cloudmessaging) is enabled.

The builder will install these as Cloudflare Worker secrets, choose currently available free models, set conservative daily caps, and run end-to-end checks. Signed APKs and Drive links follow successful Linux builds.
