# Nosmai × Tencent RTC Livestreaming

A Flutter livestreaming application that combines **Nosmai camera effects** with **Tencent RTC (TRTC)** for real-time broadcasting and viewing on mobile devices.

The application provides a feature-based dashboard for beauty, makeup, cloud filters, and AR effects. On Android, a native Kotlin bridge connects Nosmai's processed GPU textures to Tencent's custom video input, allowing remote viewers to receive the effects applied by the broadcaster.

> **Development status:** Android GPU-based filtered livestreaming has been demonstrated between two devices. The native GPU path is experimental and currently validated at approximately **5 FPS**, with a **540 × 960** video stream observed on the viewer. The full **720p at 30 FPS** target, producer synchronization, texture lifetime, and long-running stability are not yet verified. Filtered livestreaming through the native bridge is **not implemented for iOS**.

## Features

- **Start Live / Watch Live:** Join a numeric Tencent RTC room as an anchor or audience member.
- **Nosmai camera:** Preview camera output with supported beauty and visual effects.
- **Cloud Filters:** Browse and apply available cloud-hosted filters.
- **Beauty & Makeup:** Control supported skin enhancements and makeup settings.
- **AR Effects:** Apply supported face effects and masks.
- **Backgrounds and Color Studio:** Access background and color adjustment options supported by the license and SDK.
- **Streaming controls:** Manage the microphone, camera orientation, and livestream session.
- **Android GPU video bridge:** Submit processed GPU textures through Tencent's native custom-video API.

Effect availability depends on the Nosmai license, downloaded assets, and device capabilities.

## Architecture

```text
                          Flutter dashboard
                                  |
                         Select a camera feature
                                  |
                      Nosmai camera (Android SDK)
                                  |
                      Beauty / filters / AR effects
                                  |
                        Processed GPU texture
                                  |
                     Native Kotlin video bridge
                                  |
                     GPU texture copy and handoff
                                  |
                   Tencent sendCustomVideoData()
                                  |
                   Tencent encoder + RTC network
                                  |
                     Viewer: decode and render
```

The host microphone is captured by Tencent RTC separately from the Nosmai video path. The viewer requires only Tencent RTC to receive and display the processed stream; Nosmai processing takes place on the broadcaster's device.

The application also supports a **Tencent-only** livestream route that uses Tencent's normal camera capture without Nosmai effects.

## Technology and dependencies

| Component | Version / implementation |
| --- | --- |
| Flutter | Dart 3.6+ / Flutter 3.27+ project constraints |
| Nosmai Flutter | `nosmai_effects_sdk: 2.0.2` |
| Nosmai Android | `com.nosmai:nosmai-sdk:3.0.7@aar` |
| Tencent Flutter | `tencent_rtc_sdk: 13.5.2` |
| Android video bridge | Kotlin + OpenGL ES + Tencent custom texture input |
| Viewer | Flutter `TRTCCloudVideoView` |

The project uses a locally maintained Tencent Flutter SDK dependency in `third_party/tencent_rtc_sdk`, selected through `pubspec_overrides.yaml`. **Keep both** when cloning or modifying the project.

The Nosmai Android AAR is resolved through Gradle; it is not copied into `android/app/libs`.

## Project layout

```text
lib/
  main.dart                     App entry point and Tencent UI
  nosmai_dashboard.dart         Feature dashboard and navigation
  nosmai_studio.dart            Nosmai camera preview and effect controls
  nosmai_tencent_bridge.dart    Flutter-to-native bridge controls
  live_session.dart             Tencent RTC session and media handling
  app_credentials.dart          Tencent identity and room configuration

android/app/src/main/kotlin/com/vativeapps/tencent_flutter_live/
  MainActivity.kt               Native channel registration
  NosmaiTencentBridge.kt        Android GPU custom-video implementation

third_party/tencent_rtc_sdk/     Project-local Tencent Flutter SDK
configure.sh                    Tencent credential configuration
REPO_SETUP.md                   Additional setup information
```

## Getting started

### 1. Prerequisites

Install Flutter, an Android SDK/toolchain, and the required Android build tools. Use a real Android device with USB debugging enabled for camera and livestream functionality.

```bash
flutter doctor -v
flutter devices
```

### 2. Clone and install dependencies

```bash
git clone https://github.com/HashirYamin-dev/nosmai_tencent_livestreaming.git
cd nosmai_tencent_livestreaming
flutter pub get
```

### 3. Configure credentials locally

Create a local Nosmai license file from the provided placeholder:

```bash
cp lib/nosmai_license_local.example.dart lib/nosmai_license_local.dart
```

Set `nosmaiLocalLicenseKey` in that **local** file to an authorized Nosmai license for your Android application ID.

Configure Tencent RTC using your application's **SDKAppID** and **SDKSecretKey**:

```bash
bash configure.sh
```

This creates `config/host.json` and `config/viewer.json` with separate User IDs and UserSigs. Use the **same SDKAppID** and numeric room ID on both devices, but **different User IDs** for host and viewer. Refresh expired UserSigs before rebuilding.

Do not commit the license, SDK secret, or generated UserSig files. They are excluded by `.gitignore`.

### 4. Run the application

For the Android GPU bridge currently included in this repository, launch the host with the bridge's explicit development flag:

```bash
flutter run -d HOST_DEVICE_ID --dart-define=NOSMAI_TYPED_CALLBACK_TEST=true
```

Launch the viewer on a different Android device:

```bash
flutter run -d VIEWER_DEVICE_ID
```

Run builds sequentially from the same checkout to avoid overlapping Flutter/Gradle build operations. In the app, select the host's Nosmai feature and **Start Live**, then select **Watch Live** with the same numeric room ID on the viewer.

**Note:** The Android native bridge's active publishing mode and FPS limit are configured in `NosmaiTencentBridge.kt`. The current experimental GPU integration includes development-only behavior. Do not assume that setting the Flutter flag alone enables a production-ready stream.

## Android GPU video pipeline

1. Nosmai captures camera frames and applies the selected effects on the host.
2. `NosmaiSDK.TextureFrameCallback` exposes the processed texture identifier and frame metadata to Kotlin.
3. The native bridge works with OpenGL ES textures, preparing an app-owned texture for Tencent.
4. The bridge submits frames with `TRTC_VIDEO_BUFFER_TYPE_TEXTURE` and Tencent's `sendCustomVideoData()`.
5. Tencent encodes and transmits the video through the RTC room.
6. The viewer's Tencent SDK receives, decodes, and renders the video.

The GPU route avoids the earlier CPU `YUV420 → ByteArray → I420` frame-transfer path. It is **GPU-to-GPU copy**, not verified zero-copy. The Nosmai producer's opaque synchronization handle and the completion of Tencent's texture consumption still require a documented, reliable ownership protocol.

## Current limitations

- **Performance:** The demonstrated Nosmai GPU handoff ran at approximately 5 FPS; smooth 720p/30 FPS delivery is still a target, not an achieved result.
- **Resolution:** The host processed 720 × 1280 GPU textures, while the viewer was observed receiving 540 × 960 in the current configuration.
- **Synchronization:** Producer-fence semantics and texture reuse/completion timing have not been fully established. Extended operation can be unstable.
- **Platform support:** Android filtered-video publishing is implemented experimentally; the equivalent native iOS Nosmai-to-Tencent bridge remains to be developed.
- **Authentication:** Local configuration is intended for development. Production services should generate UserSigs securely on a backend and provide access control and token renewal.

## Security

The repository intentionally excludes:

- `lib/nosmai_license_local.dart`
- `config/host.json` and `config/viewer.json`
- Android signing keys and machine-local build configuration

Never commit SDK signing secrets, license keys, live UserSigs, or other credentials. Use a backend signer and vendor-approved credential handling for deployed applications.

## Useful commands

```bash
flutter pub get
flutter analyze lib test
flutter test
flutter devices
```

Android host logs for the GPU bridge can be inspected with:

```bash
adb -s HOST_DEVICE_ID logcat -d -s NosmaiTrtcGpuV12:I '*:S'
```

## References

- [Tencent RTC Flutter SDK](https://pub.dev/packages/tencent_rtc_sdk)
- [Tencent TRTC Flutter repository](https://github.com/Tencent-RTC/TRTC_Flutter)
- [Tencent RTC documentation](https://trtc.io/document/64203?platform=flutter&product=rtcengine)
- [Nosmai Flutter SDK](https://pub.dev/packages/nosmai_effects_sdk)

## License

This repository contains third-party SDK integrations. Tencent and Nosmai SDKs remain subject to their respective licenses, service terms, and usage requirements.
