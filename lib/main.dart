import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_video_view.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app_credentials.dart';
import 'live_session.dart';
import 'nosmai_dashboard.dart';

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
    return MaterialApp(
      title: 'Tencent Live',
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
      // NOSMAI_DASHBOARD_PHASE2: dashboard with feature-specific Nosmai camera.
      home: NosmaiDashboardPage(
        hostCredentials: _plainRunProfiles[true] ?? credentials,
        viewerCredentials: _plainRunProfiles[false] ?? credentials,
        buildLivePage: (isHost, roomId) => LivePage(
          credentials: isHost ? (_plainRunProfiles[true] ?? credentials) : (_plainRunProfiles[false] ?? credentials),
          roomId: roomId,
          isHost: isHost,
        ),
        buildLegacyPage: () => HomePage(credentials: credentials),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.credentials});
  final AppCredentials credentials;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _room = TextEditingController(text: '1001');
  bool _opening = false;

  @override
  void dispose() {
    _room.dispose();
    super.dispose();
  }

  Future<void> _message(String title, String message,
      {bool offerSettings = false}) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: SelectableText(message)),
        actions: [
          if (offerSettings)
            TextButton(
              onPressed: () async {
                Navigator.pop(dialogContext);
                await openAppSettings();
              },
              child: const Text('Open Settings'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _open(bool isHost) async {
    if (_opening) return;
    FocusScope.of(context).unfocus();
    final roomId = parseRoomId(_room.text);
    if (roomId == null) {
      await _message(
          'Invalid Room ID',
          'Enter a number from 1 to 4294967294. '
              'Use the same Room ID on the host and viewer.');
      return;
    }
    final selected = _plainRunProfiles[isHost] ?? widget.credentials;
    final problem = selected.validate();
    if (problem != null) {
      await _message('Tencent setup needed', problem);
      return;
    }
    if (!(Platform.isAndroid || Platform.isIOS)) {
      await _message(
          'Use a phone',
          'This project targets Android and iOS. '
              'Run it on an Android phone or iPhone, not Chrome or macOS.');
      return;
    }
    setState(() => _opening = true);
    try {
      // Audience never requests camera/microphone or starts local capture.
      if (isHost) {
        final result =
            await [Permission.camera, Permission.microphone].request();
        if (!mounted) return;
        if (result[Permission.camera] != PermissionStatus.granted ||
            result[Permission.microphone] != PermissionStatus.granted) {
          await _message(
              'Camera and microphone needed',
              'Allow Camera and Microphone to start a livestream. '
                  'Watch Live does not require these permissions.',
              offerSettings: true);
          return;
        }
      }
      if (!mounted) return;
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => LivePage(
          credentials: selected,
          roomId: roomId,
          isHost: isHost,
        ),
      ));
    } catch (e) {
      await _message('Could not open livestream', '$e');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final credentials = _plainRunProfiles[true] ?? widget.credentials;
    final ready = credentials.validate() == null;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tencent Live'),
        actions: [
          IconButton(
            tooltip: 'Setup help',
            icon: const Icon(Icons.help_outline),
            onPressed: () => _message(
                'Two-phone test',
                '1. On your Mac, run bash configure.sh.\n'
                    '2. Run flutter run and select the host phone.\n'
                    '3. Run flutter run in another terminal for the viewer phone.\n'
                    '4. Use Room ID 1001 on both phones.\n'
                    '5. Tap Start Live on the host and Watch Live on the viewer.\n\n'
                    'The SDKAppID must match. Each phone needs its own User ID and '
                    'matching UserSig. Keep the app in the foreground.\n\n'
                    'This is camera/microphone streaming through TRTC, not an '
                    'RTMP broadcast to YouTube. No beauty/AR SDK is included.'),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 28),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Icon(Icons.live_tv,
                        size: 36, color: colors.onPrimaryContainer),
                  ),
                ),
                const SizedBox(height: 24),
                Text('Go live.\nWatch together.',
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        )),
                const SizedBox(height: 12),
                Text('One phone streams. Another phone watches.',
                    style: TextStyle(color: colors.onSurfaceVariant)),
                const SizedBox(height: 32),
                TextField(
                  key: const ValueKey('room-id'),
                  controller: _room,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 10,
                  enabled: !_opening,
                  decoration: const InputDecoration(
                    labelText: 'Room ID',
                    helperText: 'Use the same number on both phones',
                    prefixIcon: Icon(Icons.meeting_room_outlined),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 58,
                  child: FilledButton.icon(
                    onPressed: _opening ? null : () => _open(true),
                    icon: const Icon(Icons.videocam_outlined),
                    label: const Text('Start Live',
                        style: TextStyle(fontSize: 17)),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 58,
                  child: OutlinedButton.icon(
                    onPressed: _opening ? null : () => _open(false),
                    icon: const Icon(Icons.play_circle_outline),
                    label: const Text('Watch Live',
                        style: TextStyle(fontSize: 17)),
                  ),
                ),
                const SizedBox(height: 24),
                if (_opening) const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(ready ? 'Tencent configured' : 'Setup needed',
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        SelectableText(ready
                            ? 'SDKAppID: ${credentials.sdkAppId}\n'
                                'Start Live: ${credentials.userId}\n'
                              'Watch Live: ${(_plainRunProfiles[false] ?? credentials).userId}'
                            : 'Run bash configure.sh, then flutter run.'),
                        const SizedBox(height: 8),
                        Text('TRTC SDK 13.5.2 · Android / iOS',
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('Host: camera + microphone.\n'
                    'Viewer: receive-only, with no camera/microphone access.'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LivePage extends StatefulWidget {
  const LivePage({
    super.key,
    required this.credentials,
    required this.roomId,
    required this.isHost,
  });
  final AppCredentials credentials;
  final int roomId;
  final bool isHost;

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> with WidgetsBindingObserver {
  late final LiveSession _session;
  bool _leaving = false;
  bool _confirming = false;
  bool _allowPop = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session = LiveSession(
      credentials: widget.credentials,
      roomId: widget.roomId,
      isHost: widget.isHost,
      expectedHostUserId: _plainRunProfiles[true]?.userId ?? "host_001",
      expectedSdkAppId: _plainRunProfiles[true]?.sdkAppId ?? 20049546,
    );
    _session.addListener(_onSessionChanged);
    unawaited(_keepAwake(true));
    unawaited(_session.start());
  }

  void _onSessionChanged() {
    if (_session.closing) unawaited(_keepAwake(false));
  }

  Future<void> _keepAwake(bool enabled) async {
    try {
      await WakelockPlus.toggle(enable: enabled);
    } catch (_) {
      // Screen-idle support must not prevent the video session from opening.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    _session.setForeground(foreground);
    unawaited(_keepAwake(foreground && !_session.closing && !_leaving));
  }

  Future<void> _leave({bool confirm = true}) async {
    if (_leaving || _confirming) return;
    if (confirm && widget.isHost && !_session.closing) {
      _confirming = true;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('End livestream?'),
          content:
              const Text('Your camera and microphone will stop publishing.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep live')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('End Live')),
          ],
        ),
      );
      _confirming = false;
      if (accepted != true || !mounted) return;
    }
    setState(() => _leaving = true);
    await _session.close();
    await _keepAwake(false);
    if (!mounted) return;
    // PopScope is rebuilt with canPop=true before the programmatic pop.
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_onSessionChanged);
    _session.dispose();
    unawaited(_keepAwake(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_leave());
      },
      child: AnimatedBuilder(
        animation: _session,
        builder: (context, _) {
          final s = _session;
          return Scaffold(
            appBar: AppBar(
              leading: IconButton(
                onPressed: _leaving ? null : () => _leave(),
                icon: const Icon(Icons.arrow_back),
              ),
              title: Text(
                  '${widget.isHost ? 'Host' : 'Viewer'} · Room ${widget.roomId}'),
            ),
            body: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(
                      children: [
                        Icon(s.reconnecting ? Icons.wifi_off : Icons.sensors,
                            size: 19),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(s.status,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600))),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            const ColoredBox(color: Colors.black),
                            if (s.engineReady && !s.closing)
                              TRTCCloudVideoView(
                                key: ValueKey(widget.isHost
                                    ? 'host-view'
                                    : 'viewer-view'),
                                onViewCreated: s.attachVideoView,
                              ),
                            if (!s.showVideo)
                              ColoredBox(
                                color: Colors.black.withValues(alpha: 0.65),
                                child: Center(
                                  child: SingleChildScrollView(
                                    padding: const EdgeInsets.all(24),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                            s.error != null
                                                ? Icons.error_outline
                                                : (widget.isHost
                                                    ? Icons.videocam_outlined
                                                    : Icons.live_tv),
                                            size: 44),
                                        const SizedBox(height: 18),
                                        Text(s.error ?? s.status,
                                            textAlign: TextAlign.center),
                                        if (!widget.isHost &&
                                            s.error == null &&
                                            s.hostUserId == null) ...[
                                          const SizedBox(height: 12),
                                          Text(
                                              'On the other phone, tap Start Live\n'
                                              'in Room ${widget.roomId}.',
                                              textAlign: TextAlign.center),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            Positioned(
                              left: 12,
                              bottom: 12,
                              right: 12,
                              child: IgnorePointer(
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  color: Colors.black.withValues(alpha: 0.6),
                                  child: Text(
                                      s.diagnostics,
                                      style: const TextStyle(fontSize: 12)),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (s.warning != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 92),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: Text(s.warning!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.tertiary)),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        if (widget.isHost) ...[
                          _control(
                              s.micMuted ? 'Unmute mic' : 'Mute mic',
                              s.micMuted ? Icons.mic_off : Icons.mic,
                              s.controlsEnabled ? s.toggleMic : null),
                          _control(
                              s.cameraOff ? 'Camera on' : 'Camera off',
                              s.cameraOff ? Icons.videocam_off : Icons.videocam,
                              s.controlsEnabled ? s.toggleCamera : null),
                          _control(
                              'Flip',
                              Icons.cameraswitch,
                              s.controlsEnabled && !s.cameraOff
                                  ? s.switchCamera
                                  : null),
                        ] else
                          _control(
                              s.speakerMuted ? 'Unmute sound' : 'Mute sound',
                              s.speakerMuted
                                  ? Icons.volume_off
                                  : Icons.volume_up,
                              s.controlsEnabled ? s.toggleSpeaker : null),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                Theme.of(context).colorScheme.errorContainer,
                            foregroundColor:
                                Theme.of(context).colorScheme.onErrorContainer,
                          ),
                          onPressed: _leaving ? null : () => _leave(),
                          icon: const Icon(Icons.call_end),
                          label: Text(_leaving
                              ? 'Leaving…'
                              : widget.isHost
                                  ? 'End Live'
                                  : 'Leave'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _control(String label, IconData icon, VoidCallback? onPressed) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label),
    );
  }
}
