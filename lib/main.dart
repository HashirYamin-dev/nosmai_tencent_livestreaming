import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_credentials.dart';
import 'nosmai_dashboard.dart';
import 'viewer_page.dart';

// PLAIN_FLUTTER_RUN_V1 - local two-phone QA only.
Map<bool, AppCredentials> _plainRunProfiles = const {};

Future<void> _loadPlainRunProfiles() async {
  const explicit = bool.hasEnvironment('SDK_APP_ID') ||
      bool.hasEnvironment('USER_ID') || bool.hasEnvironment('USER_SIG') ||
      bool.hasEnvironment('TOKEN_EXPIRES_AT');
  if (!kDebugMode || explicit) return;
  try {
    final profiles = <bool, AppCredentials>{};
    for (final entry in {true: 'host', false: 'viewer'}.entries) {
      final text = await rootBundle.loadString('config/${entry.value}.json');
      final data = jsonDecode(text) as Map<String, dynamic>;
      profiles[entry.key] = AppCredentials(
        sdkAppId: int.parse('${data['SDK_APP_ID']}'),
        userId: data['USER_ID'] as String,
        userSig: data['USER_SIG'] as String,
        expiresAt: int.parse('${data['TOKEN_EXPIRES_AT']}'),
      );
    }
    _plainRunProfiles = Map<bool, AppCredentials>.unmodifiable(profiles);
  } catch (_) {
    debugPrint('QA config unavailable. Run bash configure.sh, then flutter run.');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await _loadPlainRunProfiles();
  runApp(const TencentLiveApp());
}

class TencentLiveApp extends StatelessWidget {
  const TencentLiveApp({
    super.key,
    this.credentials = const AppCredentials.fromEnvironment(),
  });

  final AppCredentials credentials;

  @override
  Widget build(BuildContext context) {
    final viewer = _plainRunProfiles[false] ?? credentials;
    return MaterialApp(
      title: 'Nosmai × Tencent Live',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF54D6E7),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0E1420),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
        ),
      ),
      home: NosmaiDashboardPage(
        hostCredentials: _plainRunProfiles[true] ?? credentials,
        viewerCredentials: viewer,
        buildViewerPage: (roomId) => ViewerPage(credentials: viewer, roomId: roomId),
      ),
    );
  }
}
