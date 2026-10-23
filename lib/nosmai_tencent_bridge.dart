import 'dart:io';
import 'package:flutter/services.dart';

/// Platform bridge for native processed-frame publishing.
/// Android and iOS use the SAME TRTC
/// sharedInstance used by the original Flutter livestream implementation.
/// The stream is not confirmed until remote frames render on a second phone.
class NosmaiTencentBridge {
  static const _channel = MethodChannel(
    'com.vativeapps.tencent_flutter_live/nosmai_tencent',
  );

  static Future<BridgeStats> start() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw UnsupportedError('Nosmai custom video requires Android or iOS');
    }
    final result = await _channel.invokeMapMethod<String, dynamic>('start');
    return BridgeStats.fromMap(result);
  }

  static Future<BridgeStats> publish() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw UnsupportedError('Nosmai custom publishing requires Android or iOS');
    }
    final result = await _channel.invokeMapMethod<String, dynamic>('publish');
    return BridgeStats.fromMap(result);
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await _channel.invokeMethod<void>('stop');
  }

  static Future<BridgeStats> status() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('status');
    return BridgeStats.fromMap(result);
  }
}

class BridgeStats {
  const BridgeStats({required this.active, required this.frames,
    required this.sent, required this.dropped, required this.errors,
    required this.lastError, required this.publishing, required this.mode});

  factory BridgeStats.fromMap(Map<String, dynamic>? map) => BridgeStats(
    active: map?['active'] == true,
    publishing: map?['publishing'] == true,
    mode: map?['mode']?.toString() ?? 'unknown',
    frames: (map?['frames'] as num?)?.toInt() ?? 0,
    sent: (map?['sent'] as num?)?.toInt() ?? 0,
    dropped: (map?['dropped'] as num?)?.toInt() ?? 0,
    errors: (map?['errors'] as num?)?.toInt() ?? 0,
    lastError: map?['lastError']?.toString() ?? '',
  );

  final bool active;
  final bool publishing;
  final String mode;
  final int frames;
  final int sent;
  final int dropped;
  final int errors;
  final String lastError;
}
