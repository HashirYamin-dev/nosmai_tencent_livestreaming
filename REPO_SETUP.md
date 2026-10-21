# Tencent + Nosmai Flutter — repository handoff

## Current state
Android proof of concept: Nosmai GPU processed frames were displayed on a
second phone through Tencent TRTC using the experimental V12 GPU trial.
That trial ran at **5 FPS** and is **not production-ready**: EGL/producer-sync
ownership, texture lifetime and 720p/30 FPS performance remain unverified.
iOS filtered-video bridge is not implemented.

## First checkout
1. Install Flutter, Android SDK and Android Studio matching the project.
2. `python3 tools/bootstrap_local_qa.py` — creates dummy local files to allow
   project asset resolution. Does not add real secrets.
3. `bash configure.sh` to generate **local** Tencent QA credentials using your
   own SDKAppID and SDKSecretKey (only after reviewing script). Never commit them.
4. Set `lib/nosmai_license_local.dart` to a licensed value for your Android
   application ID (the example file contains an empty placeholder).
5. `flutter pub get` then `flutter analyze lib test` and `flutter run -d DEVICE_ID`.
6. For experimental GPU V12 tests, see current native bridge and its limitations.

## Important tracked dependencies
- Keep `pubspec_overrides.yaml` if the current project resolves
  `tencent_rtc_sdk` from `third_party/tencent_rtc_sdk`.
- Keep that `third_party/tencent_rtc_sdk` plugin source (except its unused
  `example/` sample app). Deleting it can break `flutter pub get`.

## Security
The ignored `config/host.json`, `config/viewer.json`, and
`lib/nosmai_license_local.dart` are LOCAL ONLY. Do not upload them or previously
shared license patch ZIPs. Test UserSigs embedded in app assets are not
production authentication. For production use a backend signer and secure
vendor-approved license delivery. If secrets were previously committed, remove
from Git history and rotate them; `.gitignore` is not history cleanup.
