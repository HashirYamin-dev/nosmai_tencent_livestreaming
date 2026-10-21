/// Only short-lived test credentials reach the app. Never add SecretKey here.
class AppCredentials {
  const AppCredentials({
    required this.sdkAppId,
    required this.userId,
    required this.userSig,
    this.expiresAt = 0,
  });

  const AppCredentials.fromEnvironment()
      : sdkAppId = const int.fromEnvironment('SDK_APP_ID'),
        userId = const String.fromEnvironment('USER_ID'),
        userSig = const String.fromEnvironment('USER_SIG'),
        expiresAt = const int.fromEnvironment('TOKEN_EXPIRES_AT');

  final int sdkAppId;
  final String userId;
  final String userSig;
  final int expiresAt;

  String? validate({DateTime? now}) {
    if (sdkAppId <= 0 || sdkAppId > 4294967295) {
      return 'Tencent credentials are missing. Run bash configure.sh, then '
          'launch with flutter run. '
          'Use your application SDKAppID, not the console account number.';
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(userId)) {
      return 'USER_ID must contain 1–32 letters, numbers, underscores or hyphens.';
    }
    if (userSig.trim().isEmpty || userSig.contains('PASTE_')) {
      return 'USER_SIG is missing. Run bash configure.sh and rebuild the app.';
    }
    final seconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    if (expiresAt > 0 && seconds >= expiresAt) {
      return 'This test UserSig has expired. Run bash configure.sh again, '
          'then stop the app and run flutter run again.';
    }
    return null;
  }
}

int? parseRoomId(String input) {
  final text = input.trim();
  if (!RegExp(r'^[0-9]+$').hasMatch(text)) return null;
  final value = int.tryParse(text);
  return value != null && value >= 1 && value <= 4294967294 ? value : null;
}
