import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_tencent_live/nosmai_tencent_live.dart';
import 'package:nosmai_tencent_live/src/rtc_session.dart';
import 'package:tencent_rtc_sdk/trtc_cloud.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_def.dart';

import 'fakes.dart';

void main() {
  const credentials = NosmaiLiveCredentials(
    sdkAppId: 1400000000,
    userId: 'test_user',
    userSig: 'not-a-real-token',
  );
  late FakeCloud cloud;
  late RtcSession session;

  Future<void> begin({bool host = false, NosmaiLiveRoom room = const NosmaiLiveRoom(1001),
      String? target}) async {
    cloud = FakeCloud();
    session = RtcSession(
      credentials: credentials,
      room: room,
      isHost: host,
      targetHostUserId: target,
      encoder: host ? NosmaiLiveVideoConfig.hd.toEncoderParam() : null,
      cloudFactory: () async => cloud,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });
    await session.start();
  }

  setUp(RtcSession.resetRestartGuardForTesting);

  test('viewer enters live as audience without starting local media', () async {
    await begin();
    cloud.events.onEnterRoom?.call(10);
    expect(cloud.params!.role, TRTCRoleType.audience);
    expect(cloud.scene, TRTCAppScene.live);
    expect(cloud.params!.roomId, 1001);
    expect(cloud.autoAudio, isTrue);
    expect(cloud.autoVideo, isTrue);
    expect(cloud.localAudioStarts, 0);
    expect(session.joined, isTrue);
    await expectLater(session.entered, completes);
  });

  test('named rooms use strRoomId', () async {
    await begin(room: const NosmaiLiveRoom.named('studio-7'));
    expect(cloud.params!.roomId, 0);
    expect(cloud.params!.strRoomId, 'studio-7');
  });

  test('video availability before the native view binds once the view arrives', () async {
    await begin();
    cloud.events.onEnterRoom?.call(10);
    cloud.events.onUserVideoAvailable?.call('host_001', true);
    expect(cloud.remoteStarts, isEmpty);
    session.attachVideoView(7);
    session.attachVideoView(7);
    cloud.events.onUserVideoAvailable?.call('host_001', true);
    expect(cloud.remoteStarts, ['host_001:7']);
    expect(cloud.audioMuted['host_001'], isFalse);
  });

  test('native view before the stream binds when availability arrives', () async {
    await begin();
    session.attachVideoView(8);
    cloud.events.onEnterRoom?.call(10);
    expect(cloud.remoteStarts, isEmpty);
    cloud.events.onUserVideoAvailable?.call('host_001', true);
    expect(cloud.remoteStarts, ['host_001:8']);
    expect(session.firstFrame, isFalse);
    cloud.events.onFirstVideoFrame?.call('host_001', TRTCVideoStreamType.big, 720, 1280);
    expect(session.firstFrame, isTrue);
  });

  test('a target host is watched even when another broadcaster joins first', () async {
    await begin(target: 'host_b');
    session.attachVideoView(3);
    cloud.events.onEnterRoom?.call(10);
    cloud.events.onUserVideoAvailable?.call('host_a', true);
    expect(session.hostUserId, isNull);
    expect(cloud.remoteStarts, isEmpty);
    cloud.events.onUserVideoAvailable?.call('host_b', true);
    expect(session.hostUserId, 'host_b');
    expect(cloud.remoteStarts, ['host_b:3']);
  });

  test('host leaving clears video and a returning host binds again', () async {
    await begin();
    session.attachVideoView(8);
    cloud.events.onEnterRoom?.call(10);
    cloud.events.onUserVideoAvailable?.call('host_001', true);
    cloud.events.onRemoteUserLeaveRoom?.call('host_001', 0);
    expect(session.hostUserId, isNull);
    expect(cloud.remoteStops, contains('host_001'));
    cloud.events.onUserAudioAvailable?.call('host_001', false);
    cloud.events.onUserVideoAvailable?.call('host_001', false);
    expect(session.hostUserId, isNull);
    cloud.events.onUserVideoAvailable?.call('host_001', true);
    expect(cloud.remoteStarts, ['host_001:8', 'host_001:8']);
  });

  test('detaching the view stops remote rendering', () async {
    await begin();
    session.attachVideoView(8);
    cloud.events.onEnterRoom?.call(10);
    cloud.events.onUserVideoAvailable?.call('host_001', true);
    session.detachVideoView(8);
    expect(cloud.remoteStops, ['host_001']);
  });

  test('viewer speaker mute never starts its microphone', () async {
    await begin();
    cloud.events.onEnterRoom?.call(10);
    cloud.events.onUserAudioAvailable?.call('host_001', true);
    session.setSpeakerMuted(true);
    expect(cloud.audioMuted['host_001'], isTrue);
    session.setSpeakerMuted(false);
    expect(cloud.audioMuted['host_001'], isFalse);
    expect(cloud.localAudioStarts, 0);
  });

  test('host applies the encoder and publishes audio only after joining', () async {
    await begin(host: true);
    expect(cloud.params!.role, TRTCRoleType.anchor);
    expect(cloud.encoder!.videoFps, 30);
    expect(cloud.encoder!.videoResolution, TRTCVideoResolution.res_1280_720);
    expect(cloud.localAudioStarts, 0);
    cloud.events.onEnterRoom?.call(10);
    expect(cloud.localAudioStarts, 1);
    expect(cloud.videoMuted, isFalse);
    cloud.events.onSendFirstLocalVideoFrame?.call(TRTCVideoStreamType.big);
    expect(session.videoPublished, isTrue);
  });

  test('host microphone and video mutes', () async {
    await begin(host: true);
    cloud.events.onEnterRoom?.call(10);
    session.setMicMuted(true);
    expect(cloud.localAudioStops, 1);
    session.setMicMuted(false);
    expect(cloud.localAudioStarts, 2);
    session.setVideoMuted(true);
    expect(cloud.videoMuted, isTrue);
    session.setVideoMuted(false);
    expect(cloud.videoMuted, isFalse);
  });

  test('background pauses host media and foreground resumes it', () async {
    await begin(host: true);
    cloud.events.onEnterRoom?.call(10);
    session.setForeground(false);
    expect(cloud.localAudioStops, 1);
    expect(cloud.videoMuted, isTrue);
    session.setForeground(true);
    expect(cloud.localAudioStarts, 2);
    expect(cloud.videoMuted, isFalse);
  });

  test('statistics map local stats for the host', () async {
    await begin(host: true);
    cloud.events.onEnterRoom?.call(10);
    cloud.events.onStatistics?.call(TRTCStatistics(
      appCpu: 0, systemCpu: 0, upLoss: 2, downLoss: 1, rtt: 80, gatewayRtt: 0,
      sentBytes: 0, receivedBytes: 0,
      localStatisticsArray: [
        TRTCLocalStatistics(width: 720, height: 1280, frameRate: 30, videoBitrate: 1700,
            audioSampleRate: 48000, audioBitrate: 50, streamType: TRTCVideoStreamType.big,
            audioCaptureState: 0),
      ],
      remoteStatisticsArray: const [],
    ));
    expect(session.stats.width, 720);
    expect(session.stats.fps, 30);
    expect(session.stats.rttMs, 80);
    expect(session.stats.upLossPercent, 2);
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

  test('failed room entry exits and exposes an actionable, redacted error', () async {
    await begin();
    final entered = session.entered;
    cloud.events.onEnterRoom?.call(-3301);
    await expectLater(entered, throwsStateError);
    await session.close();
    expect(session.error, contains('UserSig'));
    expect(session.error, isNot(contains('not-a-real-token')));
    expect(cloud.exits, 1);
  });

  test('invalid credentials fail before touching the engine', () async {
    final fake = FakeCloud();
    final bad = RtcSession(
      credentials: const NosmaiLiveCredentials(sdkAppId: 0, userId: 'u', userSig: 's'),
      room: const NosmaiLiveRoom(1001),
      isHost: false,
      cloudFactory: () async => fake,
    );
    await bad.start();
    await expectLater(bad.entered, throwsStateError);
    expect(bad.error, contains('sdkAppId'));
    expect(fake.params, isNull);
    bad.dispose();
  });

  test('closing during initialization never enters a room afterwards', () async {
    final pending = Completer<TRTCCloud>();
    final fake = FakeCloud();
    final early = RtcSession(
      credentials: credentials,
      room: const NosmaiLiveRoom(1001),
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
