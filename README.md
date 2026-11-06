# Nosmai × Tencent RTC Livestreaming

Flutter livestreaming with Nosmai camera effects (beauty, makeup, AR masks,
backgrounds, colour and cloud filters) published through Tencent RTC (TRTC).

This repository contains:

- **[`packages/nosmai_tencent_live`](packages/nosmai_tencent_live/)**: the
  Flutter plugin. Add it to any Flutter app to livestream Nosmai effects with
  **no Android or iOS code in the app**.
- **The example app** (repository root): a dashboard of Nosmai features, a
  host screen with Start Live, and a viewer screen. It uses only the plugin's
  Dart API. `MainActivity`, `AppDelegate`, Gradle and the Podfile are stock
  Flutter templates.

## Integrating into your own app

See the plugin guide: **[packages/nosmai_tencent_live/README.md](packages/nosmai_tencent_live/README.md)**.

In short:

```yaml
dependencies:
  nosmai_tencent_live:
    git:
      url: https://github.com/HashirYamin-dev/nosmai_tencent_livestreaming.git
      path: packages/nosmai_tencent_live
```

```dart
await NosmaiTencentLive.initialize(
    androidLicenseKey: androidKey, iosLicenseKey: iosKey);
// Show NosmaiCameraPreview(), apply effects via NosmaiTencentLive.effects
final live = NosmaiLiveBroadcaster(
    credentials: NosmaiLiveCredentials(sdkAppId: id, userId: 'host_1', userSig: sig),
    room: const NosmaiLiveRoom(1001));
await live.start();
```

The only platform change is the camera and microphone usage strings in iOS
`Info.plist`.

## Project layout

```
packages/nosmai_tencent_live/   The plugin (Dart API + Android Java + iOS Obj-C)
lib/
  main.dart                     Example app entry, QA credential loading
  nosmai_dashboard.dart         Feature tiles, room ID, Watch Live
  nosmai_studio.dart            Nosmai preview + effect panels + Start Live
  viewer_page.dart              Viewer screen (NosmaiLiveViewerView)
  app_credentials.dart          QA credential model / validation
config/*.example.json           Templates for local Tencent QA credentials
configure.sh, tools/            Local QA UserSig generator and helpers
run.sh, run_android_only.sh     Device launch helpers
```

## Running the example app

### 1. Requirements

Flutter, the Android SDK, and Xcode with CocoaPods. Use physical phones; the
Nosmai SDK does not run in simulators.

```bash
flutter doctor -v
flutter devices
```

### 2. Clone and install

```bash
git clone https://github.com/HashirYamin-dev/nosmai_tencent_livestreaming.git
cd nosmai_tencent_livestreaming
python3 tools/bootstrap_local_qa.py   # creates ignored placeholder config files
flutter pub get
```

### 3. Tencent QA credentials

```bash
bash configure.sh
```

Enter your **SDKAppID** and **SDKSecretKey** when prompted. The script writes
private `config/host.json` and `config/viewer.json` with distinct `host_001`
and `viewer_001` UserSigs. Both phones must use the same SDKAppID and room
with different user IDs. Rerun the script when the UserSigs expire. Production
apps must create UserSigs on a server. The secret key never belongs in an app.

### 4. Nosmai license

Nosmai keys are bound to the app identifier: Android `com.nosmai.effect`,
iOS `com.vativeApps.NosmaiAR` in this example. Either put a key in the ignored
`lib/nosmai_license_local.dart`, or pass one per platform:

```bash
--dart-define=NOSMAI_ANDROID_LICENSE_KEY=...   # Android build
--dart-define=NOSMAI_IOS_LICENSE_KEY=...       # iOS build
```

### 5. Run

```bash
bash run.sh host   HOST_DEVICE_ID      # phone that broadcasts
bash run.sh viewer VIEWER_DEVICE_ID    # phone that watches
```

On the host, open a feature (e.g. **AR Effects**), choose an effect, then tap
**Start Live**. On the viewer, tap **Watch Live** with the same room ID.
Optional quality preset: `--dart-define=LIVE_QUALITY=low|standard|hd`.

For Xcode runs, open `ios/Runner.xcworkspace` (not the `.xcodeproj`).

## Status

- Plugin and example app: unit and widget tests pass (`flutter test` in both
  the root and `packages/nosmai_tencent_live`).
- A brand-new `flutter create` app with only the plugin added builds for
  Android (debug and release) and iOS, with no native edits.
- **Android → Android** (plugin): verified on real phones (Samsung A52s and
  OnePlus CPH2515) in debug and release (R8) builds, with effects visible on
  the viewer. The host uses Nosmai's documented shared-texture protocol
  (`stats.transport == texture`), with an I420 fallback.
- **iOS → iOS** (plugin): verified on real phones in debug and release builds
  (iPhone 8 → iPhone X, iOS 16.7), with effects visible on the viewer. iOS
  always uses the pixel-buffer path (`stats.transport == pixelBuffer`).
- **iOS → Android**: demonstrated on 23 Oct 2026 with the earlier in-app bridge,
  which used the same pixel-buffer route (360×640, 15 FPS, ~500 kbps). Not yet
  re-tested with the plugin, and Android → iOS has not been tested.
- Not yet tested: long sessions, reconnects, different networks, device heat
  and audio/video sync. Test these on your target phones before release.

## Security

Never commit `config/*.json`, `lib/nosmai_license_local.dart`, `.env` files,
signing material or logs containing UserSigs. Check `git status` and
`git diff --cached` before pushing. Rotate any credential that was exposed.

## License

Tencent RTC and Nosmai are governed by their own licenses and service terms.
