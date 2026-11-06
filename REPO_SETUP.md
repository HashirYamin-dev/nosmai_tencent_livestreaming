# Repository handoff

## Current state

- `packages/nosmai_tencent_live` is the integration. It is a Flutter plugin, and
  apps use only its Dart API.
- The root app is its example. It has no native bridge code: `MainActivity`,
  `AppDelegate`, Gradle and the Podfile are stock templates.
- iOS: processed `CVPixelBuffer` forwarding, demonstrated iPhone → Android on
  real devices.
- Android: shared-texture forwarding using Nosmai's wait/complete protocol,
  with automatic I420 fallback. Needs real-device verification.

## First checkout

1. Install Flutter, the Android SDK and Xcode with CocoaPods.
2. `python3 tools/bootstrap_local_qa.py` creates ignored placeholder config
   files. It adds no real secrets.
3. `bash configure.sh` generates **local** Tencent QA credentials from your
   SDKAppID and SDKSecretKey. Never commit them.
4. Put a licensed Nosmai key in `lib/nosmai_license_local.dart`, or pass
   `--dart-define=NOSMAI_ANDROID_LICENSE_KEY=...` /
   `--dart-define=NOSMAI_IOS_LICENSE_KEY=...`.
5. `flutter pub get`, then `flutter analyze lib test`, `flutter test`, and
   `flutter test` inside `packages/nosmai_tencent_live`.
6. `bash run.sh host DEVICE_ID` and `bash run.sh viewer DEVICE_ID`.

## Dependencies

The plugin pins `nosmai_effects_sdk` 2.0.x and `tencent_rtc_sdk` 13.5.x from
pub.dev. A forked Tencent SDK or `pubspec_overrides.yaml` is no longer needed:
the plugin's Android build raises the Tencent module's compileSdk and aligns
vectordrawable itself.

## Security

The ignored `config/host.json`, `config/viewer.json` and
`lib/nosmai_license_local.dart` are local only. Test UserSigs in app assets are
not production authentication. Use a backend signer and secure license
delivery for production. If secrets were ever committed, remove them from
history and rotate them. `.gitignore` does not clean history.
