import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_tencent_live/src/native_bridge.dart';
import 'package:tencent_rtc_sdk/trtc_cloud.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_def.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_listener.dart';
import 'package:tencent_rtc_sdk/tx_device_manager.dart';

/// Shared call log, so tests can assert ordering across the bridge and cloud.
final List<String> callLog = <String>[];

// These fakes test our orchestration, not Tencent's native engine or network.
class FakeDeviceManager extends Fake implements TXDeviceManager {
  @override
  int setAudioRoute(TXAudioRoute route) => 0;
}

class FakeCloud extends Fake implements TRTCCloud {
  late TRTCCloudListener events;
  final device = FakeDeviceManager();
  TRTCParams? params;
  TRTCAppScene? scene;
  TRTCVideoEncParam? encoder;
  int localAudioStarts = 0;
  int localAudioStops = 0;
  int exits = 0;
  int unregisters = 0;
  bool? videoMuted;
  bool confirmExit = true;
  final remoteStarts = <String>[];
  final remoteStops = <String>[];
  final audioMuted = <String, bool>{};
  bool? autoAudio;
  bool? autoVideo;

  @override
  void registerListener(TRTCCloudListener func) => events = func;

  @override
  void unRegisterListener(TRTCCloudListener func) => unregisters++;

  @override
  void enterRoom(TRTCParams param, TRTCAppScene appScene) {
    callLog.add('enterRoom');
    params = param;
    scene = appScene;
  }

  @override
  void exitRoom() {
    callLog.add('exitRoom');
    exits++;
    if (confirmExit) events.onExitRoom?.call(0);
  }

  @override
  void setDefaultStreamRecvMode(bool audio, bool video) {
    autoAudio = audio;
    autoVideo = video;
  }

  @override
  void setVideoEncoderParam(TRTCVideoEncParam param) => encoder = param;
  @override
  void setVideoEncoderMirror(bool mirror) {}
  @override
  void setRemoteRenderParams(String userId, TRTCVideoStreamType streamType, TRTCRenderParams params) {}
  @override
  TXDeviceManager getDeviceManager() => device;
  @override
  void startLocalAudio(TRTCAudioQuality quality) => localAudioStarts++;
  @override
  void stopLocalAudio() => localAudioStops++;
  @override
  void muteLocalVideo(TRTCVideoStreamType streamType, bool mute) => videoMuted = mute;

  @override
  void startRemoteView(String userId, TRTCVideoStreamType streamType, int? viewId) =>
      remoteStarts.add('$userId:$viewId');

  @override
  void stopRemoteView(String userId, TRTCVideoStreamType streamType) => remoteStops.add(userId);

  @override
  void stopAllRemoteView() {}
  @override
  void muteRemoteAudio(String userId, bool mute) => audioMuted[userId] = mute;
  @override
  void muteAllRemoteAudio(bool mute) {}
  @override
  void muteAllRemoteVideoStreams(bool mute) {}
}

class FakeBridge extends NativeBridge {
  FakeBridge() : super();

  bool microphoneGranted = true;
  bool armed = false;
  bool publishing = false;
  int? armedFps;
  int stops = 0;

  @override
  Future<bool> prepare() async {
    callLog.add('prepare');
    return true;
  }

  @override
  Future<({bool camera, bool microphone})> requestPermissions() async =>
      (camera: true, microphone: microphoneGranted);

  @override
  Future<NativeFrameStats> arm({required int fps, required bool adaptToThermalState}) async {
    callLog.add('arm');
    armed = true;
    armedFps = fps;
    return _stats();
  }

  @override
  Future<NativeFrameStats> publish() async {
    callLog.add('publish');
    publishing = true;
    return _stats();
  }

  @override
  Future<NativeFrameStats> setMaxFps(int fps) async => _stats();

  @override
  Future<NativeFrameStats> stats() async => _stats(frames: 60, sent: 48);

  @override
  Future<void> stop() async {
    callLog.add('bridge.stop');
    stops++;
    armed = false;
    publishing = false;
  }

  NativeFrameStats _stats({int frames = 0, int sent = 0}) => NativeFrameStats(
      armed: armed, publishing: publishing, transport: 'texture', frames: frames, sent: sent);
}
