import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';

import 'native_bridge.dart';
import 'stats.dart';

/// Camera and microphone permission state.
class NosmaiLivePermissions {
  const NosmaiLivePermissions({required this.camera, required this.microphone});

  final bool camera;
  final bool microphone;

  bool get allGranted => camera && microphone;
}

/// Entry point: initializes Nosmai for livestreaming.
///
/// ```dart
/// await NosmaiTencentLive.initialize(
///   androidLicenseKey: 'NOSMAI_ANDROID_KEY',
///   iosLicenseKey: 'NOSMAI_IOS_KEY',
/// );
/// ```
///
/// After this, every Nosmai feature is available through
/// [NosmaiTencentLive.effects] (the same object as `NosmaiFlutter.instance`).
class NosmaiTencentLive {
  NosmaiTencentLive._();

  static NativeBridge _bridge = const NativeBridge();
  static Future<void>? _initializing;
  static bool _initialized = false;

  /// Nosmai's effects API: beauty, makeup, filters, AR effects, backgrounds,
  /// cloud filters, camera switching and capture.
  static NosmaiFlutter get effects => NosmaiFlutter.instance;

  /// Whether [initialize] has completed successfully.
  static bool get isInitialized => _initialized;

  /// Initializes Nosmai with the license key for the current platform.
  ///
  /// Call once, before showing `NosmaiCameraPreview`. Do not call
  /// `NosmaiFlutter.initialize` yourself: on Android this method must run
  /// first so Nosmai shares GPU textures with the stream (otherwise frames
  /// fall back to a slower CPU copy).
  ///
  /// Nosmai keys are bound to the app: Android to the applicationId, iOS to
  /// the bundle identifier. Throws [NosmaiLiveException] if the key is missing
  /// or rejected.
  static Future<void> initialize({String? androidLicenseKey, String? iosLicenseKey}) {
    if (_initialized) return Future.value();
    return _initializing ??= _initialize(androidLicenseKey, iosLicenseKey)
        .whenComplete(() => _initializing = null);
  }

  static Future<void> _initialize(String? androidKey, String? iosKey) async {
    final platform = defaultTargetPlatform;
    if (kIsWeb || (platform != TargetPlatform.android && platform != TargetPlatform.iOS)) {
      throw const NosmaiLiveException(
          'unsupported_platform', 'Nosmai livestreaming runs on Android and iOS devices only.');
    }
    final key = (platform == TargetPlatform.android ? androidKey : iosKey)?.trim() ?? '';
    if (key.isEmpty) {
      throw NosmaiLiveException('missing_license_key',
          'Pass the Nosmai ${platform == TargetPlatform.android ? 'Android' : 'iOS'} license key.');
    }
    if (NosmaiFlutter.instance.isInitialized) {
      debugPrint('[NosmaiTencentLive] Nosmai was initialized before '
          'NosmaiTencentLive.initialize; Android will stream with CPU frames.');
    }
    // Must precede NosmaiFlutter.initialize (see the method documentation).
    await _bridge.prepare();
    final accepted = NosmaiFlutter.instance.isInitialized ||
        await NosmaiFlutter.initialize(key);
    if (!accepted) {
      throw const NosmaiLiveException('license_rejected',
          'Nosmai rejected the license key. Check that it was issued for this '
          'platform and this applicationId / bundle identifier.');
    }
    _initialized = true;
  }

  /// Asks for camera and microphone access if not already decided.
  static Future<NosmaiLivePermissions> requestPermissions() async {
    final result = await _bridge.requestPermissions();
    return NosmaiLivePermissions(camera: result.camera, microphone: result.microphone);
  }

  @visibleForTesting
  static set bridgeForTesting(NativeBridge bridge) => _bridge = bridge;

  @visibleForTesting
  static void resetForTesting() {
    _bridge = const NativeBridge();
    _initializing = null;
    _initialized = false;
  }
}
