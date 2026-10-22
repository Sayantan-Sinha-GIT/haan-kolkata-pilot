# Haan rider app

Flutter Android app for OTP, vehicle and document onboarding, verification, online presence, timed offers, PIN-based trip start, navigation, earnings, history, support and EN/HI settings. Going online starts a persistent foreground notification and sends location updates; going offline or signing out stops it. The app asks for location permission before enabling online mode.

Build with `flutter pub get` and `flutter build apk --split-per-abi --release --dart-define=API_BASE_URL=https://YOUR-WORKER --dart-define=DOWNLOAD_URL=https://YOUR-DRIVE-LINK` plus Firebase public config defines. Release signing must use the same backed-up keystore for every version. `android/app/build.gradle.kts` must never ship with debug signing.

The API accepts documents only as JPEG, PNG or WebP under 500 KB. This app compresses uploads to JPEG before sending. Documents are stored privately in Workers KV and opened only by an admin with a five-minute signed link.
