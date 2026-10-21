import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tencent_flutter_live/app_credentials.dart';
import 'package:tencent_flutter_live/live_session.dart';
import 'package:tencent_rtc_sdk/trtc_cloud.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_def.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_listener.dart';
import 'package:tencent_rtc_sdk/tx_device_manager.dart';

// These fakes test our orchestration, not Tencent's native engine/network.
class FakeDeviceManager extends Fake implements TXDeviceManager {
  bool front = true;
  @override
  int setAudioRoute(TXAudioRoute route) => 0;
  @override
  int switchCamera(bool frontCamera) {
    front = frontCamera;
    return 0;
  }
}

class FakeCloud extends Fake implements TRTCCloud {
  late TRTCCloudListener events;
  final device = FakeDeviceManager();
  TRTCParams? params;
  TRTCAppScene? scene;
  TRTCVideoEncParam? encoder;
  int localAudioStarts = 0;
  int localAudioStops = 0;
  int localPreviewStarts = 0;
  int localPreviewStops = 0;
  int exits = 0;
  int unregisters = 0;
  int? localView;
  final remoteStarts = <String>[];
  final remoteStops = <String>[];
  final audioMuted = <String, bool>{};
  bool? autoAudio;
  bool? autoVideo;

  @override
  void registerListener(TRTCCloudListener func) {
    events = func;
  }

  @override
  void unRegisterListener(TRTCCloudListener func) {
    unregisters++;
  }

  @override
  void enterRoom(TRTCParams param, TRTCAppScene appScene) {
    params = param;
    scene = appScene;
  }

  @override
  void exitRoom() {
    exits++;
    events.onExitRoom?.call(0);
  }

  @override
  void setDefaultStreamRecvMode(bool audio, bool video) {
    autoAudio = audio;
    autoVideo = video;
  }

  @override
  void setVideoEncoderParam(TRTCVideoEncParam param) {
    encoder = param;
  }

  @override
  void setVideoEncoderMirror(bool mirror) {}
  @override
  void setLocalRenderParams(TRTCRenderParams params) {}
  @override
  void setRemoteRenderParams(
      String userId, TRTCVideoStreamType streamType, TRTCRenderParams params) {}
  @override
  TXDeviceManager getDeviceManager() => device;
  @override
  void startLocalAudio(TRTCAudioQuality quality) {
    localAudioStarts++;
  }

  @override
  void stopLocalAudio() {
    localAudioStops++;
  }

  @override
  void startLocalPreview(bool frontCamera, int? viewId) {
    localPreviewStarts++;
    localView = viewId;
  }

  @override
  void updateLocalView(int? viewId) {
    localView = viewId;
  }

  @override
  void stopLocalPreview() {
    localPreviewStops++;
  }

  @override
  void startRemoteView(
      String userId, TRTCVideoStreamType streamType, int? viewId) {
    remoteStarts.add('$userId:$viewId');
  }

  @override
  void stopRemoteView(String userId, TRTCVideoStreamType streamType) {
    remoteStops.add(userId);
  }

  @override
  void stopAllRemoteView() {}
  @override
  void muteRemoteAudio(String userId, bool mute) {
    audioMuted[userId] = mute;
  }

  @override
  void muteAllRemoteAudio(bool mute) {}
  @override
  void muteAllRemoteVideoStreams(bool mute) {}
}

void main() {
  const credentials = AppCredentials(
    sdkAppId: 1400000000,
    userId: 'test_user',
    userSig: 'not-a-real-token',
  );
  late FakeCloud cloud;
  late LiveSession session;

  Future<void> begin({bool host = false}) async {
    cloud = FakeCloud();
    session = LiveSession(
      credentials: credentials,
      roomId: 1001,
      isHost: host,
      cloudFactory: () async => cloud,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });
    await session.start();
  }

  test('viewer enters live as audience without starting local media', () async {
    await begin();
    cloud.events.onEnterRoom?.call(10);
    expect(cloud.params!.role, TRTCRoleType.audience);
    expect(cloud.scene, TRTCAppScene.live);
    expect(cloud.params!.roomId, 1001);
    expect(cloud.autoAudio, isTrue);
    expect(cloud.autoVideo, isTrue);
    expect(cloud.localAudioStarts, 0);
    expect(cloud.localPreviewStarts, 0);
    expect(session.status, 'Waiting for host…');
  });

  test('video availability before native view binds once after view arrives',
      () async {
    await begin();
    cloud.events.onEnterRoom?.call(10);
    cloud.events.onUserVideoAvailable?.call('host_001', true);
    expect(cloud.remoteStarts, isEmpty);
    session.attachVideoView(7);
    session.attachVideoView(7);
    cloud.events.onUserVideoAvailable?.call('host_001', true);
    expect(cloud.remoteStarts, ['host_001:7']);
    expect(cloud.audioMuted['host_001'], isFalse);
    expect(cloud.localPreviewStarts, 0);
  });

  test('native view before stream binds when availability arrives', () async {
    await begin();
    session.attachVideoView(8);
    cloud.events.onEnterRoom?.call(10);
    expect(cloud.remoteStarts, isEmpty);
    cloud.events.onUserVideoAvailable?.call('host_001', true);
    expect(cloud.remoteStarts, ['host_001:8']);
    expect(session.showVideo, isFalse);
    cloud.events.onFirstVideoFrame
        ?.call('host_001', TRTCVideoStreamType.big, 720, 1280);
    expect(session.showVideo, isTrue);
  });

  test('host leaving clears video and a returning host binds again', () async {
    await begin();
    session.attachVideoView(8);
    cloud.events.onEnterRoom?.call(10);
    cloud.events.onUserVideoAvailable?.call('host_001', true);
    cloud.events.onRemoteUserLeaveRoom?.call('host_001', 0);
    expect(session.hostUserId, isNull);
    expect(session.status, 'Waiting for host…');
    expect(cloud.remoteStops, contains('host_001'));
    cloud.events.onUserAudioAvailable?.call('host_001', false);
    cloud.events.onUserVideoAvailable?.call('host_001', false);
    expect(session.hostUserId, isNull);
    cloud.events.onUserVideoAvailable?.call('host_001', true);
    expect(cloud.remoteStarts, ['host_001:8', 'host_001:8']);
  });

  test('viewer speaker toggle never starts its microphone', () async {
    await begin();
    cloud.events.onEnterRoom?.call(10);
    cloud.events.onUserAudioAvailable?.call('host_001', true);
    session.toggleSpeaker();
    expect(cloud.audioMuted['host_001'], isTrue);
    session.toggleSpeaker();
    expect(cloud.audioMuted['host_001'], isFalse);
    expect(cloud.localAudioStarts, 0);
  });

  test('Nosmai custom video host never opens Tencent local camera', () async {
    cloud = FakeCloud();
    session = LiveSession(
      credentials: credentials,
      roomId: 1001,
      isHost: true,
      customVideoInput: true,
      cloudFactory: () async => cloud,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });
    await session.start();
    cloud.events.onEnterRoom?.call(10);
    expect(cloud.localAudioStarts, 1);
    expect(cloud.localPreviewStarts, 0);
    session.attachVideoView(9);
    expect(cloud.localPreviewStarts, 0);
    await session.close();
    expect(cloud.localPreviewStops, 0);
  });

  test('host publishes audio after join and preview only after view creation',
      () async {
    await begin(host: true);
    expect(cloud.localPreviewStarts, 0);
    cloud.events.onEnterRoom?.call(10);
    expect(cloud.params!.role, TRTCRoleType.anchor);
    expect(cloud.localAudioStarts, 1);
    expect(cloud.localPreviewStarts, 0);
    session.attachVideoView(9);
    expect(cloud.localPreviewStarts, 1);
    expect(cloud.encoder!.videoFps, 20);
    cloud.events.onFirstVideoFrame
        ?.call('', TRTCVideoStreamType.big, 720, 1280);
    expect(session.showVideo, isTrue);
  });

  test('host camera and microphone controls stop and restart capture',
      () async {
    await begin(host: true);
    session.attachVideoView(9);
    cloud.events.onEnterRoom?.call(10);
    session.toggleMic();
    expect(cloud.localAudioStops, 1);
    session.toggleMic();
    expect(cloud.localAudioStarts, 2);
    session.toggleCamera();
    expect(cloud.localPreviewStops, 1);
    expect(session.showVideo, isFalse);
    session.toggleCamera();
    expect(cloud.localPreviewStarts, 2);
    session.switchCamera();
    expect(cloud.device.front, isFalse);
  });

  test('background pauses capture and foreground resumes host', () async {
    await begin(host: true);
    session.attachVideoView(9);
    cloud.events.onEnterRoom?.call(10);
    session.setForeground(false);
    expect(cloud.localAudioStops, 1);
    expect(cloud.localPreviewStops, 1);
    session.setForeground(true);
    expect(cloud.localAudioStarts, 2);
    expect(cloud.localPreviewStarts, 2);
  });

  test('close is idempotent and unregisters the listener', () async {
    await begin(host: true);
    cloud.events.onEnterRoom?.call(10);
    await session.close();
    await session.close();
    expect(cloud.exits, 1);
    expect(cloud.unregisters, 1);
    expect(session.closed, isTrue);
    expect(session.joined, isFalse);
  });

  test('failed room entry exits and exposes an actionable error', () async {
    await begin();
    cloud.events.onEnterRoom?.call(-3301);
    await session.close();
    expect(session.error, contains('UserSig'));
    expect(cloud.exits, 1);
  });

  test('closing during initialization never enters a room afterwards',
      () async {
    final pending = Completer<TRTCCloud>();
    final fake = FakeCloud();
    final early = LiveSession(
      credentials: credentials,
      roomId: 1001,
      isHost: false,
      cloudFactory: () => pending.future,
    );
    final starting = early.start();
    await early.close();
    pending.complete(fake);
    await starting;
    expect(fake.params, isNull);
    expect(early.closed, isTrue);
    early.dispose();
  });
}
