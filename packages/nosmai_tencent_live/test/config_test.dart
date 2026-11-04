import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_tencent_live/nosmai_tencent_live.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_def.dart';

void main() {
  group('NosmaiLiveCredentials', () {
    test('accepts valid values', () {
      expect(
          const NosmaiLiveCredentials(sdkAppId: 1400000000, userId: 'host_1', userSig: 'sig')
              .validate(),
          isNull);
    });

    test('rejects a missing SDKAppID, bad userId and empty UserSig', () {
      expect(const NosmaiLiveCredentials(sdkAppId: 0, userId: 'a', userSig: 's').validate(),
          contains('sdkAppId'));
      expect(const NosmaiLiveCredentials(sdkAppId: 1, userId: 'has space', userSig: 's')
          .validate(), contains('userId'));
      expect(const NosmaiLiveCredentials(sdkAppId: 1, userId: 'a', userSig: ' ').validate(),
          contains('userSig'));
    });

    test('toString never includes the UserSig', () {
      expect(const NosmaiLiveCredentials(sdkAppId: 1, userId: 'a', userSig: 'secret').toString(),
          isNot(contains('secret')));
    });
  });

  group('NosmaiLiveRoom', () {
    test('numeric bounds', () {
      expect(const NosmaiLiveRoom(1).validate(), isNull);
      expect(const NosmaiLiveRoom(4294967294).validate(), isNull);
      expect(const NosmaiLiveRoom(0).validate(), isNotNull);
      expect(const NosmaiLiveRoom(4294967295).validate(), isNotNull);
    });

    test('names', () {
      expect(const NosmaiLiveRoom.named('studio-7').validate(), isNull);
      expect(const NosmaiLiveRoom.named('').validate(), isNotNull);
      expect(NosmaiLiveRoom.named('x' * 65).validate(), isNotNull);
    });
  });

  group('NosmaiLiveVideoConfig', () {
    test('presets map to portrait Tencent encoder settings', () {
      final hd = NosmaiLiveVideoConfig.hd.toEncoderParam();
      expect(hd.videoResolution, TRTCVideoResolution.res_1280_720);
      expect(hd.videoResolutionMode, TRTCVideoResolutionMode.portrait);
      expect(hd.videoFps, 30);
      expect(hd.videoBitrate, 1800);

      final standard = NosmaiLiveVideoConfig.standard.toEncoderParam();
      expect(standard.videoResolution, TRTCVideoResolution.res_960_540);
      expect(standard.videoFps, 24);
    });

    test('explicit bitrates win over defaults', () {
      final custom = const NosmaiLiveVideoConfig(bitrateKbps: 900, minBitrateKbps: 300)
          .toEncoderParam();
      expect(custom.videoBitrate, 900);
      expect(custom.minVideoBitrate, 300);
    });
  });
}
