# Haan customer app

Flutter Android app for email OTP, GPS/manual pickup, landmark search, fare comparison, explicit booking, live trip status, PIN display, direct payment summary, rating, history, saved places, support and EN/HI settings. The assistant supports typed requests and up to 15 seconds of recorded speech; audio is deleted locally after server transcription.

Build with `flutter pub get` and `flutter build apk --split-per-abi --release --dart-define=API_BASE_URL=https://YOUR-WORKER --dart-define=DOWNLOAD_URL=https://YOUR-DRIVE-LINK` plus Firebase public config defines. Release signing must use the same backed-up keystore for every version. `android/app/build.gradle.kts` must never ship with debug signing.

The public OSM tile server is attributed in the map. Ola geocoding and routing calls go through the Worker. The app contains no provider API keys.
