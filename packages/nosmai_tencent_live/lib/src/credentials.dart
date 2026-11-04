/// Tencent RTC identity for one user.
///
/// Generate [userSig] on your backend with the SDKSecretKey. Never ship the
/// secret key inside a mobile app.
class NosmaiLiveCredentials {
  const NosmaiLiveCredentials({
    required this.sdkAppId,
    required this.userId,
    required this.userSig,
  });

  final int sdkAppId;
  final String userId;
  final String userSig;

  /// A human-readable problem, or null when the values are usable.
  String? validate() {
    if (sdkAppId <= 0 || sdkAppId > 4294967295) {
      return 'sdkAppId must be your Tencent RTC application SDKAppID.';
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(userId)) {
      return 'userId must be 1-32 letters, digits, underscores or hyphens.';
    }
    if (userSig.trim().isEmpty) {
      return 'userSig is empty. Generate it on your server for this userId.';
    }
    return null;
  }

  @override
  String toString() => 'NosmaiLiveCredentials(sdkAppId: $sdkAppId, userId: $userId)';
}

/// A Tencent RTC room, identified by number or by name.
///
/// Every participant must use the same kind of identifier: a numeric room and
/// a named room with the same digits are different rooms.
class NosmaiLiveRoom {
  /// A numeric room ID from 1 to 4294967294.
  const NosmaiLiveRoom(int id)
      : numericId = id,
        name = null;

  /// A named room: up to 64 letters, digits and `_-.!#$%&()+:;<=>?@[]^{}|~`.
  const NosmaiLiveRoom.named(String this.name) : numericId = null;

  final int? numericId;
  final String? name;

  String? validate() {
    final id = numericId;
    if (id != null) {
      return id >= 1 && id <= 4294967294
          ? null
          : 'Room ID must be between 1 and 4294967294.';
    }
    final text = name ?? '';
    if (!RegExp(r'^[A-Za-z0-9 _\-.!#$%&()+:;<=>?@\[\]^{}|~,]{1,64}$').hasMatch(text)) {
      return 'Room name must be 1-64 characters from the allowed set.';
    }
    return null;
  }

  @override
  String toString() => numericId != null ? 'room $numericId' : 'room "$name"';

  @override
  bool operator ==(Object other) =>
      other is NosmaiLiveRoom && other.numericId == numericId && other.name == name;

  @override
  int get hashCode => Object.hash(numericId, name);
}
