import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_tencent_live/nosmai_tencent_live.dart';
import 'package:nosmai_tencent_live/src/rtc_session.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_def.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const credentials = NosmaiLiveCredentials(
    sdkAppId: 1400000000,
    userId: 'viewer_001',
    userSig: 'not-a-real-token',
  );
  late FakeCloud cloud;

  setUp(() {
    callLog.clear();
    RtcSession.resetRestartGuardForTesting();
    cloud = FakeCloud();
  });

  NosmaiLiveViewer create() {
    final viewer = NosmaiLiveViewer(
      credentials: credentials,
      room: const NosmaiLiveRoom(1001),
      cloudFactory: () async => cloud,
    );
    addTearDown(viewer.dispose);
    return viewer;
  }

  test('moves from connecting to waiting to live', () async {
    final viewer = create();
    final started = viewer.start();
    await pumpEventQueue();
    expect(viewer.state, NosmaiLiveState.connecting);
    cloud.events.onEnterRoom?.call(10);
    await started;
    expect(viewer.state, NosmaiLiveState.waitingForHost);
    expect(cloud.params!.role, TRTCRoleType.audience);
  });

  test('finds the broadcaster once its video is available', () async {
    final viewer = create();
    final started = viewer.start();
    await pumpEventQueue();
    cloud.events.onEnterRoom?.call(10);
    await started;
    cloud.events.onUserVideoAvailable?.call('host_001', true);
    expect(viewer.watchingUserId, 'host_001');
    expect(viewer.state, NosmaiLiveState.waitingForHost);
  });

  test('a rejected entry fails with a readable error', () async {
    final viewer = create();
    final started = viewer.start();
    await pumpEventQueue();
    cloud.events.onEnterRoom?.call(-100018);
    await expectLater(started, throwsA(isA<NosmaiLiveException>()));
    expect(viewer.state, NosmaiLiveState.failed);
    expect(viewer.error, isNotNull);
  });

  test('stop leaves the room', () async {
    final viewer = create();
    final started = viewer.start();
    await pumpEventQueue();
    cloud.events.onEnterRoom?.call(10);
    await started;
    await viewer.stop();
    expect(cloud.exits, 1);
    expect(viewer.state, NosmaiLiveState.stopped);
  });
}
