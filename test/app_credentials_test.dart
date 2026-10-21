import 'package:flutter_test/flutter_test.dart';
import 'package:tencent_flutter_live/app_credentials.dart';

void main() {
  group('Credential validation', () {
    test('missing setup returns an actionable message', () {
      const credentials = AppCredentials(sdkAppId: 0, userId: '', userSig: '');
      expect(credentials.validate(), contains('configure.sh'));
    });

    test('configured test credentials pass local checks', () {
      const credentials = AppCredentials(
        sdkAppId: 1400000000,
        userId: 'viewer_001',
        userSig: 'test-token',
      );
      expect(credentials.validate(), isNull);
    });

    test('invalid user ID and missing token are rejected', () {
      const badId = AppCredentials(
        sdkAppId: 1400000000,
        userId: 'viewer with spaces',
        userSig: 'token',
      );
      const badToken = AppCredentials(
        sdkAppId: 1400000000,
        userId: 'viewer_001',
        userSig: '',
      );
      expect(badId.validate(), contains('USER_ID'));
      expect(badToken.validate(), contains('USER_SIG'));
    });

    test('expired token requires a rebuild', () {
      const credentials = AppCredentials(
        sdkAppId: 1400000000,
        userId: 'host_001',
        userSig: 'token',
        expiresAt: 1000,
      );
      expect(
          credentials.validate(
              now: DateTime.fromMillisecondsSinceEpoch(1000000)),
          contains('expired'));
      expect(
          credentials.validate(
              now: DateTime.fromMillisecondsSinceEpoch(999000)),
          isNull);
    });
  });

  group('Numeric Room ID', () {
    test('valid boundaries and whitespace', () {
      expect(parseRoomId('1'), 1);
      expect(parseRoomId(' 1001 '), 1001);
      expect(parseRoomId('4294967294'), 4294967294);
      expect(parseRoomId('001001'), 1001);
    });
    test('invalid values', () {
      for (final input in ['', '0', '-1', '1.5', 'room1001', '4294967295']) {
        expect(parseRoomId(input), isNull, reason: input);
      }
    });
  });
}
