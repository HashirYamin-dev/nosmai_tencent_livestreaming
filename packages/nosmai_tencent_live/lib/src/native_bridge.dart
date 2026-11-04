import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Counters reported by the native frame forwarder.
@immutable
class NativeFrameStats {
  const NativeFrameStats({
    this.armed = false,
    this.publishing = false,
    this.transport = '',
    this.frames = 0,
    this.sent = 0,
    this.dropped = 0,
    this.errors = 0,
    this.width = 0,
    this.height = 0,
    this.maxFps = 0,
    this.lastError = '',
  });

  factory NativeFrameStats.fromMap(Map<Object?, Object?>? map) {
    int number(String key) => (map?[key] as num?)?.toInt() ?? 0;
    return NativeFrameStats(
      armed: map?['armed'] == true,
      publishing: map?['publishing'] == true,
      transport: map?['transport']?.toString() ?? '',
      frames: number('frames'),
      sent: number('sent'),
      dropped: number('dropped'),
      errors: number('errors'),
      width: number('width'),
      height: number('height'),
      maxFps: number('maxFps'),
      lastError: map?['lastError']?.toString() ?? '',
    );
  }

  final bool armed;
  final bool publishing;
  final String transport;
  final int frames;
  final int sent;
  final int dropped;
  final int errors;
  final int width;
  final int height;
  final int maxFps;
  final String lastError;
}

/// Thin wrapper over the plugin's method channel; replaceable in tests.
class NativeBridge {
  const NativeBridge([this._channel = const MethodChannel('nosmai_tencent_live')]);

  final MethodChannel _channel;

  /// Android: registers the shared GL context Nosmai must join. Call before
  /// Nosmai initializes. Returns whether a share context exists.
  Future<bool> prepare() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>('prepare');
    return result?['sharedContext'] == true;
  }

  Future<({bool camera, bool microphone})> requestPermissions() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>('requestPermissions');
    return (
      camera: result?['camera'] == true,
      microphone: result?['microphone'] == true,
    );
  }

  /// Enables Tencent custom video capture. Must precede entering the room.
  Future<NativeFrameStats> arm({required int fps, required bool adaptToThermalState}) async =>
      NativeFrameStats.fromMap(await _channel.invokeMapMethod<Object?, Object?>(
          'arm', {'fps': fps, 'adaptToThermalState': adaptToThermalState}));

  /// Starts forwarding Nosmai frames. Call after the room is entered.
  Future<NativeFrameStats> publish() async =>
      NativeFrameStats.fromMap(await _channel.invokeMapMethod<Object?, Object?>('publish'));

  Future<NativeFrameStats> setMaxFps(int fps) async => NativeFrameStats.fromMap(
      await _channel.invokeMapMethod<Object?, Object?>('setMaxFps', {'fps': fps}));

  Future<NativeFrameStats> stats() async =>
      NativeFrameStats.fromMap(await _channel.invokeMapMethod<Object?, Object?>('stats'));

  /// Stops forwarding, drains in-flight frames and disables custom capture.
  Future<void> stop() => _channel.invokeMethod<void>('stop');
}
