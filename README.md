# Tencent Live — Flutter Android/iOS QA app

Prepared 16 October 2026. Pinned Tencent Flutter package: **tencent_rtc_sdk 13.5.2**.

## 1. App ka flow

Home screen mein Room ID, **Start Live** aur **Watch Live** hain. Start Live host ke camera/microphone ko Tencent TRTC room mein publish karta hai. Watch Live audience role mein enter karta hai: viewer ka camera/microphone na request hota hai, na start hota hai. Host ka video available hone par viewer usse subscribe karta hai.

Host controls: microphone mute/unmute, camera off/on, front/rear flip, End Live with confirmation. Viewer controls: sound mute/unmute and Leave. The viewer waits when no host is present and can continue waiting for a host to return. Both builds show both buttons; `host` and `viewer` profiles determine the device's identity, not a permanent UI role.

The app is configured for a portrait **720 × 1280, 30 FPS encoder target**, 1600 kbps, and full-frame `fit` rendering. These are requested settings, not measured or guaranteed capture/transmission performance. The app preserves the full frame rather than zoom-cropping it; black bars can appear to preserve aspect ratio.

Keep the app in the foreground. Moving it into the background intentionally stops local capture / remote playback; returning resumes media. Screen-idle prevention is enabled while the foreground session is active. This is not a background-streaming implementation.

This is a single-selected-host viewer UI. Use one broadcasting phone per test room. If multiple anchors exist, the viewer selects the first discovered anchor, not a multi-host grid. There is no room browser, login backend, room password/ACL, viewer counter, chat, gifts, recording, beauty SDK, Nosmai bridge, RTMP URL or YouTube publishing.

## 2. Requirements and package pins

A configured Flutter development machine with Flutter **3.27+ / Dart 3.6+**, Python **3.9+**, and internet access for Flutter packages/native SDK downloads. Android Studio/Android SDK are required for Android. iOS requires a Mac, Xcode, CocoaPods and your own device-signing setup. Use two physical phones for the live camera test; this project generates only Android and iOS platform shells, not web/desktop targets.

Direct dependencies are pinned:

| Package | Version |
| --- | --- |
| tencent_rtc_sdk | 13.5.2 |
| permission_handler | 12.0.1 |
| wakelock_plus | 1.3.3 |
| flutter_lints | 5.0.0 |

`pubspec.lock` is generated on your computer by `flutter pub get`. Keep that generated lockfile with this application for subsequent reproducible builds. Transitive dependencies have not been resolved in the preparation environment.

```bash
flutter doctor -v
python3 --version
```

For an FVM-managed installation, a local `.fvm/flutter_sdk/bin/flutter` is detected by the run helpers. An explicit SDK path is also supported:

```bash
export FLUTTER_BIN="$HOME/fvm/versions/YOUR_VERSION/bin/flutter"
```

Replace `YOUR_VERSION` with your installed version/path. Use that same Flutter installation for setup and builds. When `FLUTTER_BIN` is set, use `"$FLUTTER_BIN" devices` instead of a different global Flutter binary.

## 3. Tencent console setup

The screenshot's **Live** trial page is the ready-made **TUILiveKit** product flow. This app implements its own simple UI on the lower-level **RTC Engine / TRTC SDK**, not TUILiveKit.

In Tencent console, open **RTC Engine** or **My Applications**. Create/select an application and ensure RTC Engine service is enabled for that SDKAppID. An application already created through the Live flow may also have RTC Engine available; inspect its product/service details instead of assuming a new purchase is needed. You do not need to integrate the Live UIKit for this source code.

From the application's details, obtain **SDKAppID** and **SDKSecretKey**. The account number in the console's upper-right corner is NOT the SDKAppID. SDKSecretKey is the application's SDK signing secret, not an unrelated Tencent Cloud API SecretId/SecretKey.

Check the account's active service, quota and billing rules in your console before leaving tests running. This project does not promise a particular free quota, trial duration or free unlimited streaming. It does not create an account or activate/purchase a plan on your behalf.

Official activation reference: https://trtc.io/document/73281

## 4. Installation from the source kit

From the extracted outer kit:

```bash
cd ~/Downloads
bash Tencent_Flutter_Live/install.sh "$HOME/Documents/PROJECTS/tencent_flutter_live"
cd "$HOME/Documents/PROJECTS/tencent_flutter_live"
```

The installer requires an empty/new destination and will not overwrite an existing project. It runs `flutter create --no-pub --platforms=android,ios`, restores the supplied app/dependency files, then configures the generated native shells. It runs `flutter pub get`, Flutter analysis and the included Dart tests. On macOS, it also runs `pod install --repo-update` when CocoaPods is available.

If a dependency download or local analysis/build prerequisite fails, the installer stops and prints that error. Do not repeatedly run the new-project installer over its now-nonempty destination. Resolve the reported prerequisite and continue inside the installed project:

```bash
flutter pub get
flutter analyze
flutter test
cd ios
pod install --repo-update
cd ..
```

Only run the `ios`/CocoaPods commands on a Mac. The native patch helper may be rerun inside this standalone app if initial configuration failed; it is idempotent for recognized generated templates:

```bash
python3 tools/patch_native.py
```

Do not run this helper on an unrelated app or rerun it after making custom native signing/configuration changes without reviewing those changes. It configures the bundle identifier and replaces this demo's Podfile and ProGuard rules.

## 5. Generate test credentials locally

```bash
bash configure.sh
```

Paste your application's SDKAppID, then its SDKSecretKey at the hidden prompt. No characters are echoed for the secret. The script makes no network requests and saves only:

- `config/host.json`, using user ID `host_001`.
- `config/viewer.json`, using user ID `viewer_001`.

Each file contains SDK_APP_ID, USER_ID, USER_SIG and TOKEN_EXPIRES_AT. UserSigs last **seven days from generation** by default; shorter test lifetimes can be selected with `bash configure.sh --days 1`. The secret is not saved or included in the app. Config files are ignored by Git and created with owner-only file permissions on macOS/Linux.

Do not commit, share or screenshot the token files. Tokens themselves are credentials, even though they are not the signing secret. They are compiled into these QA builds via Dart defines and may be extracted from a built app. Do not distribute this configuration as a production login system.

An alternative that does not use the signing secret in the local generator:

```bash
bash configure.sh --manual
```

In Tencent console's UserSig tools, generate a token for `host_001` and a separate token for `viewer_001`, under the same SDKAppID. Paste them at the script's hidden prompts. The local check reads token metadata and expiry; it does not verify the HMAC or confirm server-side service availability. Tencent validates the signature when the app enters the room.

For a third phone:

```bash
bash configure.sh --profile viewer2 --user-id viewer_002
bash run.sh viewer2 THIRD_DEVICE_ID
```

Every concurrently connected phone needs a different User ID and its corresponding UserSig. Signing the same User ID twice does not create two distinct identities.

## 6. Run on two phones

Connect the phones, enable the appropriate developer mode/USB debugging, and trust your computer when requested.

```bash
flutter devices
```

Terminal 1:

```bash
cd "$HOME/Documents/PROJECTS/tencent_flutter_live"
bash run.sh host HOST_DEVICE_ID
```

Wait for that build to finish and the app to launch. Terminal 2:

```bash
cd "$HOME/Documents/PROJECTS/tencent_flutter_live"
bash run.sh viewer VIEWER_DEVICE_ID
```

Replace device placeholders with actual IDs. Avoid simultaneous builds or simultaneous hot restarts from the same working directory; launch one build at a time so generated native build settings do not race.

On phone 1, enter **1001** and tap **Start Live**, then grant camera and microphone permission. On phone 2, enter **1001** and tap **Watch Live**. Same SDKAppID + same numeric Room ID + different User IDs. Viewer can also enter first and wait for the host. On both devices, verify the displayed identity in the home screen's configuration card.

The app uses a **numeric** TRTC `roomId`. When testing alongside a different sample, string room ID `"1001"` is not interchangeable with numeric room ID `1001`.

The run scripts default to debug mode. For a standalone QA launch/reopening from the home screen:

```bash
bash run.sh host HOST_DEVICE_ID --release
bash run.sh viewer VIEWER_DEVICE_ID --release
```

Run these sequentially, not as concurrent builds. Use the scripts instead of plain `flutter run` or a generic editor Run button: the scripts pass the chosen profile's Dart defines. The equivalent direct command is:

```bash
flutter run -d HOST_DEVICE_ID --dart-define-from-file=config/host.json
```

Regenerating JSON credentials does not update an already-installed binary. Stop and rebuild using `run.sh` after changing or renewing a token.

## 7. iPhone signing

After installing CocoaPods dependencies:

```bash
open ios/Runner.xcworkspace
```

Select the blue **Runner** project, then **TARGETS → Runner → Signing & Capabilities**. Enable automatic signing and select your Apple development Team. The initial app identifier is `com.vativeapps.tencentlive`; change it to a unique identifier owned by your team if provisioning requires that. Select your connected iPhone as the destination.

Use `run.sh` after setting signing so the correct credential profile is compiled. Simply opening Xcode and pressing Run without first building the selected profile can use missing or previously generated Dart defines.

This source kit configures iOS deployment target to at least 15.0, camera/microphone usage descriptions, permission-handler preprocessor macros, and CocoaPods configuration. On supported newer Flutter versions, Swift Package Manager is disabled **for this project only** because this integration uses the CocoaPods native SDK.

For release/profile builds, the installer sets `DEPLOYMENT_POSTPROCESSING = YES` and `STRIP_STYLE = non-global`, following Tencent's Dart FFI release-build guidance. These settings are included to preserve native symbols; a real device release build is still required to validate the exact local Xcode/toolchain combination.

## 8. Android release APKs for QA

```bash
bash build_apk.sh host
bash build_apk.sh viewer
```

Outputs are copied to `dist/tencent-live-host.apk` and `dist/tencent-live-viewer.apk`. Install host on one phone and viewer on another. They have the same package ID, so installing one over the other on the same device replaces its credential profile. Generated Flutter debug signing is sufficient for this local QA flow; configure your own release keystore before any store distribution.

The native patch sets compile SDK to at least 35 and min SDK to at least 23 while preserving higher Flutter defaults. It adds camera/audio/network permissions, optional hardware features, Tencent native library packaging rules and ProGuard keep rules. It does not add background streaming services, location access or storage permissions. Bluetooth headset routing is not a qualified feature of this demo; verify first with the phone's built-in camera, microphone and speaker.

## 9. Troubleshooting

| Symptom | Check |
| --- | --- |
| Setup needed | Run `bash configure.sh`, then launch through `run.sh` rather than a plain Run button. |
| Room entry/authentication error | SDKAppID belongs to the intended app; UserSig matches User ID and SDKAppID; token is current; RTC Engine service is enabled and not suspended; both clocks/internet connections are working. |
| One phone disconnects when the other joins | Inspect home-screen User IDs. Build separate host and viewer profiles. |
| Viewer stays at Waiting for host | Same SDKAppID and numeric Room ID; host pressed Start Live and remains foreground. |
| Camera permission denied | Use the supplied Open Settings action, allow camera and microphone, then return and try Start Live again. |
| Waiting for first frame | Keep both apps foreground; verify host camera is on, permissions granted, another app is not using the camera, and each phone has network access. The native view must also finish creating. |
| Host video unavailable | Host turned camera off, moved the app to the background, or stopped video. |
| No sound | Unmute host mic and viewer sound; turn up phone media volume; test without headset routing. Place phones apart to avoid feedback during testing. |
| Expired UserSig | Regenerate credentials and fully stop/rebuild the affected profile. |
| Room exit not confirmed | Fully terminate and reopen the app. The app refuses another room session after an unconfirmed SDK release. |
| iOS signing error | Select Team, valid bundle ID and trusted physical device in Runner's Signing & Capabilities. |
| iOS release missing native symbols | Verify the supplied Release/Profile strip settings remain present; resolve CocoaPods again after any native SDK change. |
| Pub/Pods/Gradle download failure | Check local internet/toolchain output. It is not proof of invalid Tencent credentials. |

A room-entry timeout is 25 seconds in this app. A missing first-frame warning appears after 15 seconds; these are application watchdog settings, not Tencent network guarantees. Errors stop capture and try to exit the room. Cleanup waits for `onExitRoom` before treating the session as released. The shared Tencent engine instance is retained across sessions to avoid destroying it while a native view is still being disposed.

If your Tencent application enables advanced room-entry permission checks, this simple UserSig-only demo is not sufficient: a backend-issued permission credential such as PrivateMapKey must also be implemented. Do not disable security controls on an existing production application merely to run a demo; use a separate test application or implement the required backend authorization.

## 10. Tests and verification boundary

Included Dart tests cover credential/room validation, home-screen setup errors and session orchestration with a fake TRTC object: host/audience role selection, view/stream event ordering, no viewer capture, host leaving/returning, media controls, background/foreground transitions, idempotent cleanup and close-during-initialization.

```bash
flutter analyze
flutter test
python3 -m unittest discover -s tools -p 'test_*.py' -v
```

Python tests cover token HMAC construction, metadata validation, expiry, file permissions, generated Gradle/XML/plist/Xcode transformations, idempotence, shell/Ruby syntax and new-project installer orchestration with a **mock** Flutter command. The mock is not a Flutter build and does not validate native media.

The preparation environment did not have Flutter/Dart, Xcode or an Android build toolchain. **Dart tests were written but not executed there; Android/iOS compilation and two-device live streaming remain unverified.** The outer kit's `verification/` folder records only checks actually executed. Run the commands above and this physical-device checklist:

| Test | Expected behavior |
| --- | --- |
| Android host → Android viewer | Host video/audio arrives; no viewer camera/mic permission prompt. |
| iPhone host → Android viewer | Same Room ID/profile identity rules, correct portrait frame. |
| Android host → iPhone viewer | Viewer receives video/audio without publishing. |
| Viewer joins first | Waiting screen, then video when host starts. |
| Mute/camera off/flip | Local control is reflected remotely where applicable. |
| Background and resume | Media pauses while backgrounded and resumes in foreground. |
| End, rejoin, leave | Resources stop; subsequent room entry works after confirmed exit. |
| Network loss/recovery | Status changes; reconnection or actionable error, not endless silent black screen. |
| Release builds on both platforms | Native symbols present and real camera/network behavior checked. |

## 11. Production authentication

This kit's local generator is for testing only. In production, authenticate users on your backend, generate short-lived UserSigs there, and return them through an authenticated HTTPS API. Never embed SDKSecretKey in Dart, JavaScript, Kotlin, Swift, source control or a distributed mobile binary.

A UserSig authenticates a user identity. It is not, by itself, an application-specific room membership or host-role authorization policy. Add server-side permissions/PrivateMapKey where appropriate, and build room management, token refresh, abuse controls and billing controls for a public service. This demo does not provide those backend features.

## 12. Source map and official references

`lib/main.dart`: home/live UI, host-only runtime permissions, lifecycle and screen-idle handling.

`lib/live_session.dart`: typed Tencent API integration and cleanup.

`lib/app_credentials.dart`: compile-time test configuration and room validation.

`tools/configure.py`: local TLS v2 UserSig generation, no third-party Python packages.

`tools/patch_native.py`: generated native shell configuration, not a patch for an existing app.

Official sources reviewed for this implementation (documentation can change; version pins above are intentional):

- Tencent Flutter SDK package: https://pub.dev/packages/tencent_rtc_sdk
- Tencent Flutter source: https://github.com/Tencent-RTC/TRTC_Flutter
- Current Flutter integration guide: https://trtc.io/document/64203?menulabel=sdk&platform=flutter&product=rtcengine
- Room entry and roles: https://trtc.io/document/58954
- RTC Engine activation: https://trtc.io/document/73281
- Live/TUILiveKit product activation: https://trtc.io/document/60033
- UserSig authentication: https://trtc.io/document/35166
- Tencent's Python TLS v2 reference: https://github.com/Tencent-RTC/tls-sig-api-v2-python
- Permission-handler native setup: https://pub.dev/packages/permission_handler/versions/12.0.1
- Wakelock package: https://pub.dev/packages/wakelock_plus/versions/1.3.3
- Flutter project-local SwiftPM configuration: https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers

The app uses the current typed `TRTCCloudListener`, `TRTCParams`, `TRTCAppScene.live` and `TRTCRoleType` APIs. Older examples using `TRTCCloudDef` constants or map-based listener callbacks should not be pasted into this pinned project without adaptation.
