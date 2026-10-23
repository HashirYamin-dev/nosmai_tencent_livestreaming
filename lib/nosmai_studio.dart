import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';
import 'package:permission_handler/permission_handler.dart';

import 'nosmai_license_local.dart';
import 'app_credentials.dart';
import 'live_session.dart';
import 'nosmai_tencent_bridge.dart';

// NOSMAI_DASHBOARD_PHASE2
// Each studio route owns exactly ONE NosmaiCameraPreview.
// Native Nosmai -> TRTC custom-frame bridge is NOT installed by this patch.
// The Start Live action offers the existing unfiltered Tencent fallback, with
// explicit consent, rather than falsely claiming filtered livestreaming.

enum NosmaiStudioMode { cloud, beauty, ar, backgrounds, color, games }

extension NosmaiStudioModeInfo on NosmaiStudioMode {
  String get title => switch (this) {
    NosmaiStudioMode.cloud => 'Cloud Filters',
    NosmaiStudioMode.beauty => 'Beauty & Makeup',
    NosmaiStudioMode.ar => 'AR Effects',
    NosmaiStudioMode.backgrounds => 'Backgrounds',
    NosmaiStudioMode.color => 'Color Studio',
    NosmaiStudioMode.games => 'Interactive Effects',
  };

  IconData get icon => switch (this) {
    NosmaiStudioMode.cloud => Icons.cloud_outlined,
    NosmaiStudioMode.beauty => Icons.face_retouching_natural,
    NosmaiStudioMode.ar => Icons.auto_awesome,
    NosmaiStudioMode.backgrounds => Icons.wallpaper_outlined,
    NosmaiStudioMode.color => Icons.tune,
    NosmaiStudioMode.games => Icons.sports_esports_outlined,
  };

  String get detail => switch (this) {
    NosmaiStudioMode.cloud => 'Download approved cloud looks',
    NosmaiStudioMode.beauty => 'Retouch, lipstick & blush',
    NosmaiStudioMode.ar => 'Face masks & 3D effects',
    NosmaiStudioMode.backgrounds => 'Background colors & scenes',
    NosmaiStudioMode.color => 'Brightness, contrast & color',
    NosmaiStudioMode.games => 'Interactive cloud effects',
  };
}

bool _nosmaiInitializedForSession = false;

Future<void> openNosmaiStudio(
  BuildContext context,
  NosmaiStudioMode mode, {
  Future<void> Function()? onUnfilteredLive,
  AppCredentials? hostCredentials,
  int? roomId,
}) async {
  if (!Platform.isAndroid && !Platform.isIOS) {
    await _studioAlert(context, 'Physical phone required',
        'Nosmai camera requires an Android/iOS physical device.');
    return;
  }
  final permission = await Permission.camera.request();
  if (!context.mounted) return;
  if (!permission.isGranted) {
    await _studioAlert(context, 'Camera permission needed',
        'Allow camera permission in Android/iOS Settings.');
    return;
  }
  if (NosmaiFlutter.instance.isInitialized) {
    _nosmaiInitializedForSession = true;
  }
  if (!_nosmaiInitializedForSession) {
    // NOSMAI_AUTO_LICENSE_LOCAL_V1
    // One local QA license is configured for all studio categories.
    // Platform-specific --dart-define values can override it if necessary.
    final fromBuild = Platform.isAndroid
        ? const String.fromEnvironment('NOSMAI_ANDROID_LICENSE_KEY')
        : const String.fromEnvironment('NOSMAI_IOS_LICENSE_KEY');
    final key = fromBuild.trim().isNotEmpty
        ? fromBuild.trim()
        : nosmaiLocalLicenseKey;
    if (key.isEmpty) {
      await _studioAlert(context, 'Nosmai configuration missing',
          'The Nosmai license was not included in this test build.');
      return;
    }
    try {
      final ok = await NosmaiFlutter.initialize(key);
      if (!ok) throw StateError('License was not accepted');
      _nosmaiInitializedForSession = true;
    } catch (_) {
      if (!context.mounted) return;
      await _studioAlert(context, 'Initialization failed',
          'Check Nosmai license, application ID, network and SDK setup.');
      return;
    }
  }
  if (!context.mounted) return;
  await Navigator.of(context).push<void>(MaterialPageRoute(
    builder: (_) => NosmaiStudioPage(
      mode: mode,
      onUnfilteredLive: onUnfilteredLive,
      hostCredentials: hostCredentials,
      roomId: roomId,
    ),
  ));
}

Future<void> _studioAlert(BuildContext context, String title, String body) async {
  if (!context.mounted) return;
  await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
    title: Text(title), content: Text(body), actions: [
      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
    ],
  ));
}

class NosmaiStudioPage extends StatefulWidget {
  const NosmaiStudioPage({super.key, required this.mode,
    this.onUnfilteredLive, this.hostCredentials, this.roomId});
  final NosmaiStudioMode mode;
  final Future<void> Function()? onUnfilteredLive;
  final AppCredentials? hostCredentials;
  final int? roomId;

  @override
  State<NosmaiStudioPage> createState() => _NosmaiStudioPageState();
}

class _NosmaiStudioPageState extends State<NosmaiStudioPage>
    with NosmaiCameraLifecycleMixin {
  // NOSMAI_TRTC_ANDROID_BRIDGE_V2: streaming never switches cameras.
  LiveSession? _live;
  bool _startingLive = false;
  bool _stoppingLive = false;
  Timer? _statsTimer;
  BridgeStats? _bridgeStats;
  bool _ready = false;
  bool _closing = false;
  bool _canPop = false;
  bool _busy = false;
  bool _catalogBusy = false;
  String _status = 'Starting Nosmai camera...';
  String? _activePackage;
  String? _selectedBackground;
  NosmaiCloudFilterType _cloudType = NosmaiCloudFilterType.filter;
  List<NosmaiFilter> _catalog = <NosmaiFilter>[];
  final Map<String, double> _beauty = {
    'Smooth': 0.35,
    'Whiten': 0.10,
    'Sharpen': 0.10,
    'Teeth': 0.0,
  };
  double _lipstick = 0;
  double _blush = 0;
  double _brightness = 0;
  double _contrast = 1;
  bool _grayscale = false;

  NosmaiCloudFilterType get _catalogType => switch (widget.mode) {
    NosmaiStudioMode.cloud => _cloudType,
    NosmaiStudioMode.ar => NosmaiCloudFilterType.effects,
    NosmaiStudioMode.backgrounds => NosmaiCloudFilterType.background,
    NosmaiStudioMode.games => NosmaiCloudFilterType.games,
    _ => NosmaiCloudFilterType.filter,
  };

  bool get _hasCatalog => widget.mode == NosmaiStudioMode.cloud ||
      widget.mode == NosmaiStudioMode.ar ||
      widget.mode == NosmaiStudioMode.backgrounds ||
      widget.mode == NosmaiStudioMode.games;

  Future<void> _loadCatalog() async {
    if (!_ready || _closing || !_hasCatalog) return;
    setState(() => _catalogBusy = true);
    try {
      final filters = await NosmaiFlutter.instance.getCloudFilters(
        filterType: _catalogType, page: 1, limit: 30,
      );
      if (!mounted || _closing) return;
      setState(() {
        _catalog = filters;
        _status = filters.isEmpty
            ? 'No items returned by your approved Nosmai catalog.'
            : '${filters.length} items available';
      });
    } catch (_) {
      if (!mounted || _closing) return;
      setState(() {
        _catalog = [];
        _status = 'Cloud catalog unavailable. Check license/network.';
      });
    } finally {
      if (mounted) setState(() => _catalogBusy = false);
    }
  }

  Future<void> _applyPackage(NosmaiFilter filter) async {
    if (!_ready || _closing || _busy) return;
    setState(() {
      _busy = true;
      _status = 'Downloading ${filter.displayName}...';
    });
    try {
      // This list is returned by getCloudFilters, so always request a
      // verified local file path (SDK may return an existing cache entry).
      final result = await NosmaiFlutter.instance.downloadCloudFilter(
        filter.cloudIdentifier,
      );
      final path = result['path'] as String? ?? '';
      if (path.isEmpty) throw StateError('No downloaded package path');
      final applied = await NosmaiFlutter.instance.applyEffect(path);
      if (!applied) throw StateError('Nosmai rejected the package');
      if (!mounted || _closing) return;
      setState(() {
        _activePackage = filter.cloudIdentifier;
        _status = 'Applied: ${filter.displayName}';
      });
    } catch (_) {
      if (mounted && !_closing) setState(() => _status =
          'Could not apply ${filter.displayName}; check entitlement and package.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _applyBeauty(String type, double value) async {
    if (!_ready || _closing) return;
    try {
      switch (type) {
        case 'Smooth':
          await NosmaiFlutter.instance.applySkinSmoothing(value);
        case 'Whiten':
          await NosmaiFlutter.instance.applySkinWhitening(value);
        case 'Sharpen':
          await NosmaiFlutter.instance.applySharpening(value);
        case 'Teeth':
          await NosmaiFlutter.instance.applyTeethWhitening(value);
      }
    } catch (_) {
      if (mounted) setState(() => _status = 'Beauty feature unavailable for license');
    }
  }

  Future<void> _applyMakeup(String type, double value) async {
    if (!_ready || _closing) return;
    try {
      if (type == 'Lipstick') {
        if (value == 0) {
          await NosmaiFlutter.instance.removeLipstick();
        } else {
          await NosmaiFlutter.instance.applyLipstick(
            style: NosmaiLipstickStyle.natural, intensity: value,
          );
        }
      } else {
        if (value == 0) {
          await NosmaiFlutter.instance.removeBlusher();
        } else {
          await NosmaiFlutter.instance.applyBlusher(
            style: NosmaiBlusherStyle.natural, intensity: value,
          );
        }
      }
    } catch (_) {
      if (mounted) setState(() => _status = 'Makeup unavailable for this license');
    }
  }

  Future<void> _setBackground(Color? color, String? label) async {
    if (!_ready || _closing || _busy) return;
    setState(() => _busy = true);
    try {
      if (color == null) {
        await NosmaiFlutter.instance.clearBackgroundSegmentation();
      } else {
        final success = await NosmaiFlutter.instance.setBackgroundSegmentation(
          NosmaiBackgroundSegmentationConfig.color(color),
        );
        if (!success) throw StateError('Background unavailable');
      }
      if (!mounted || _closing) return;
      setState(() {
        _selectedBackground = label;
        _status = label == null ? 'Background reset' : '$label background active';
      });
    } catch (_) {
      if (mounted) setState(() => _status = 'Background requires an enabled license');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    if (!_ready || _closing || _busy) return;
    setState(() => _busy = true);
    try {
      await NosmaiFlutter.instance.clearAll();
      if (!mounted || _closing) return;
      setState(() {
        for (final k in _beauty.keys) { _beauty[k] = 0; }
        _lipstick = 0;
        _blush = 0;
        _brightness = 0;
        _contrast = 1;
        _grayscale = false;
        _activePackage = null;
        _selectedBackground = null;
        _status = 'All effects cleared';
      });
    } catch (_) {
      if (mounted) setState(() => _status = 'Could not clear effects');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onCameraReady() async {
    if (!mounted || _closing) return;
    setState(() { _ready = true; _status = 'Nosmai preview ready'; });
    if (widget.mode == NosmaiStudioMode.beauty) {
      for (final e in _beauty.entries) {
        if (_closing || !mounted) return;
        await _applyBeauty(e.key, e.value);
      }
    }
    if (_hasCatalog) await _loadCatalog();
  }

  Future<void> _exit() async {
    if (_closing) return;
    setState(() => _closing = true);
    await _endFilteredLive();
    try {
      await cleanupBeforeNavigation();
    } catch (_) {
      try { await NosmaiFlutter.instance.endCameraSession(); } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _canPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  // iOS: native CVPixelBuffer handoff. Android: existing GPU bridge.
  // A local preview or native submit count is NOT proof of remote playback.
  Future<void> _startLive() async {
    if (!_ready || _closing || _startingLive || _live != null) return;
    // NOSMAI_JNI_CRASH_GUARD_V1
    // The earlier experimental texture callback aborted the process on
    // tested Android devices (libnosmai.so stale JNI weak global reference).
    // Do not call it until its listener lifetime is fixed and tested.
    final unsafeExperiment = const bool.fromEnvironment(
        'NOSMAI_TYPED_CALLBACK_TEST', defaultValue: false);
    if (Platform.isAndroid && !unsafeExperiment) {
      await _studioAlert(context, 'Typed native bridge test (opt-in)',
          'V3 uses the typed Nosmai FrameCallback instead of the crashing '
          'texture listener. It is still unverified. Run a debug build with '
          '--dart-define=NOSMAI_TYPED_CALLBACK_TEST=true to test it on one '
          'Android phone. The default build keeps filtered streaming disabled.');
      return;
    }
    if (!Platform.isAndroid && !Platform.isIOS) {
      await _studioAlert(context, 'Unsupported platform',
          'Filtered livestreaming requires a physical Android or iOS device.');
      return;
    }
    final credentials = widget.hostCredentials;
    final roomId = widget.roomId;
    if (credentials == null || roomId == null) {
      await _studioAlert(context, 'Tencent configuration missing',
          'Open this camera from the dashboard with a valid Room ID.');
      return;
    }
    final problem = credentials.validate();
    if (problem != null) {
      await _studioAlert(context, 'Tencent configuration', problem);
      return;
    }
    final micPermission = await Permission.microphone.request();
    if (!mounted || _closing) return;
    if (!micPermission.isGranted) {
      await _studioAlert(context, 'Microphone permission',
          'Allow microphone access to publish audio with the video.');
      return;
    }
    setState(() { _startingLive = true; _status = 'Preparing processed video...'; });
    try {
      // IMPORTANT: TRTC custom capture is enabled BEFORE enterRoom.
      // V2 starts in ARMED state. The bridge won't push until onEnterRoom.
      _bridgeStats = await NosmaiTencentBridge.start();
      if (!mounted || _closing) { await NosmaiTencentBridge.stop(); return; }
      final session = LiveSession(
        credentials: credentials, roomId: roomId, isHost: true,
        customVideoInput: true,
        expectedHostUserId: credentials.userId,
        expectedSdkAppId: credentials.sdkAppId,
      );
      _live = session;
      session.addListener(_onFilteredLiveChanged);
      await session.start();
      // Wait for room confirmation before submitting ANY processed video frame.
      final roomDeadline = DateTime.now().add(const Duration(seconds: 20));
      while (!session.joined && session.error == null &&
          DateTime.now().isBefore(roomDeadline) && mounted && !_closing) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final sessionError = session.error;
      if (sessionError != null) throw StateError(sessionError);
      if (!session.joined) throw StateError('Tencent room did not confirm join.');
      _bridgeStats = await NosmaiTencentBridge.publish();
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        unawaited(_refreshBridgeStats());
      });
      await _refreshBridgeStats();
      if (mounted) setState(() => _status = 'Connecting to Tencent room $roomId...');
    } catch (e) {
      await _endFilteredLive();
      if (!mounted || _closing) return;
      await _studioAlert(context, 'Filtered livestream could not start',
          '$e\n\nThe app did not switch to an unfiltered camera.');
    } finally {
      if (mounted) setState(() => _startingLive = false);
    }
  }

  void _onFilteredLiveChanged() {
    if (!mounted || _closing) return;
    final live = _live;
    if (live == null) return;
    setState(() {
      _status = live.error != null ? 'Tencent: ${live.error}'
          : '${live.status} • ${live.diagnostics.replaceAll('\n', ' / ')}';
    });
  }

  Future<void> _refreshBridgeStats() async {
    try {
      final stats = await NosmaiTencentBridge.status();
      if (mounted && !_closing) setState(() => _bridgeStats = stats);
    } catch (_) { /* Native SDK status should not freeze the camera UI. */ }
  }

  Future<void> _endFilteredLive() async {
    if (_stoppingLive) return;
    _stoppingLive = true;
    _statsTimer?.cancel();
    _statsTimer = null;
    final live = _live;
    _live = null;
    // Stop capture producer first; do not send frames while leaving the room.
    try { await NosmaiTencentBridge.stop(); } catch (_) {}
    if (live != null) {
      live.removeListener(_onFilteredLiveChanged);
      try { await live.close(); } catch (_) {}
      live.dispose();
    }
    _bridgeStats = null;
    _stoppingLive = false;
    if (mounted && !_closing) setState(() => _status = 'Nosmai preview ready');
  }

  Widget _liveInfo() {
    final live = _live;
    if (live == null) return const SizedBox.shrink();
    final stats = _bridgeStats;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: Text(
        'Tencent: ${live.status} | Room ${widget.roomId}\n'
        'Live Stream Stats • frames: ${stats?.frames ?? 0} • sent: ${stats?.sent ?? 0}'
        ' • dropped: ${stats?.dropped ?? 0}\n'
        '${(stats?.lastError.isNotEmpty ?? false) ? stats!.lastError : 'Viewer must confirm remote video'}',
        maxLines: 3, overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, color: Colors.amberAccent),
      ),
    );
  }

  Widget _slider(String title, double value, double min, double max,
      ValueChanged<double> changed, ValueChanged<double> committed) {
    return Row(children: [
      SizedBox(width: 90, child: Text(title, maxLines: 1,
          overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
      Expanded(child: Slider(value: value, min: min, max: max,
        onChanged: !_ready || _closing || _busy ? null : changed,
        onChangeEnd: !_ready || _closing || _busy ? null : committed)),
      SizedBox(width: 38, child: Text(value.toStringAsFixed(2),
          style: const TextStyle(fontSize: 11))),
    ]);
  }

  Widget _beautyPanel() => ListView(children: [
    const Text('FACE BEAUTY', style: TextStyle(fontWeight: FontWeight.bold)),
    for (final item in _beauty.entries)
      _slider(item.key, item.value, 0, 1,
        (v) => setState(() => _beauty[item.key] = v),
        (v) => _applyBeauty(item.key, v)),
    const SizedBox(height: 7),
    const Text('MAKEUP', style: TextStyle(fontWeight: FontWeight.bold)),
    _slider('Lipstick', _lipstick, 0, 1,
      (v) => setState(() => _lipstick = v),
      (v) => _applyMakeup('Lipstick', v)),
    _slider('Blush', _blush, 0, 1,
      (v) => setState(() => _blush = v),
      (v) => _applyMakeup('Blush', v)),
    TextButton(onPressed: !_ready ? null : () async {
      await NosmaiFlutter.instance.removeAllMakeup();
      if (mounted) setState(() { _lipstick = 0; _blush = 0; });
    }, child: const Text('Remove makeup')),
  ]);

  Widget _colorPanel() => ListView(children: [
    const Text('COLOR ADJUSTMENTS', style: TextStyle(fontWeight: FontWeight.bold)),
    _slider('Brightness', _brightness, -1, 1,
      (v) => setState(() => _brightness = v),
      (v) async {
        try { await NosmaiFlutter.instance.applyBrightnessFilter(v); }
        catch (_) { if (mounted) setState(() => _status = 'Brightness unavailable'); }
      }),
    _slider('Contrast', _contrast, 0, 2,
      (v) => setState(() => _contrast = v),
      (v) async {
        try { await NosmaiFlutter.instance.applyContrastFilter(v); }
        catch (_) { if (mounted) setState(() => _status = 'Contrast unavailable'); }
      }),
    SwitchListTile(title: const Text('Grayscale'), value: _grayscale,
      onChanged: !_ready ? null : (value) async {
        try {
          if (value) { await NosmaiFlutter.instance.applyGrayscaleFilter(); }
          else { await NosmaiFlutter.instance.removeBuiltInFilterByName('grayscale'); }
          if (mounted) setState(() => _grayscale = value);
        } catch (_) { if (mounted) setState(() => _status = 'Grayscale unavailable'); }
      }),
  ]);

  Widget _backgroundPanel() => Column(children: [
    SizedBox(height: 52, child: ListView(scrollDirection: Axis.horizontal,
      children: [
        _backgroundChip(null, null, 'Original'),
        _backgroundChip(const Color(0xFF1352BD), 'Blue', 'Blue'),
        _backgroundChip(Colors.black, 'Black', 'Black'),
        _backgroundChip(const Color(0xFF168052), 'Green', 'Green'),
      ])),
    Expanded(child: _catalogPanel()),
  ]);

  Widget _backgroundChip(Color? color, String? selected, String title) {
    return Padding(padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(label: Text(title),
        selected: _selectedBackground == selected,
        onSelected: !_ready || _busy ? null : (_) => _setBackground(color, selected)));
  }

  Widget _catalogPanel() {
    if (_catalogBusy) return const Center(child: CircularProgressIndicator());
    if (_catalog.isEmpty) return Center(child: Column(
      mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.cloud_off_outlined, size: 38),
        const SizedBox(height: 8),
        const Text('No cloud items available', textAlign: TextAlign.center),
        TextButton.icon(onPressed: _ready ? _loadCatalog : null,
            icon: const Icon(Icons.refresh), label: const Text('Retry')),
      ],
    ));
    return ListView.builder(
      itemCount: _catalog.length,
      itemBuilder: (_, i) {
        final item = _catalog[i];
        final active = _activePackage == item.cloudIdentifier;
        return ListTile(dense: true,
          leading: CircleAvatar(child: Icon(active ? Icons.check : Icons.auto_awesome, size: 18)),
          title: Text(item.displayName.isEmpty ? item.name : item.displayName,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(active ? 'Applied' : (item.isDownloaded ? 'Cached' : 'Tap to download & apply'),
              style: const TextStyle(fontSize: 11)),
          trailing: Icon(active ? Icons.check_circle : Icons.download_outlined, size: 20),
          onTap: !_ready || _busy ? null : () => _applyPackage(item),
        );
      },
    );
  }

  Widget _modePanel() {
    if (widget.mode == NosmaiStudioMode.beauty) return _beautyPanel();
    if (widget.mode == NosmaiStudioMode.color) return _colorPanel();
    if (widget.mode == NosmaiStudioMode.backgrounds) return _backgroundPanel();
    return Column(children: [
      if (widget.mode == NosmaiStudioMode.cloud)
        SizedBox(height: 45, child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            _typeChip('Looks', NosmaiCloudFilterType.filter),
            _typeChip('AR', NosmaiCloudFilterType.effects),
            _typeChip('Makeup', NosmaiCloudFilterType.beautyEffect),
            _typeChip('Background', NosmaiCloudFilterType.background),
          ]),
        )),
      Expanded(child: _catalogPanel()),
    ]);
  }

  Widget _typeChip(String label, NosmaiCloudFilterType type) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label), selected: _cloudType == type,
      onSelected: !_ready || _catalogBusy || _busy ? null : (_) {
        setState(() { _cloudType = type; _catalog = []; _activePackage = null; });
        _loadCatalog();
      },
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: _canPop,
    onPopInvokedWithResult: (didPop, result) { if (!didPop) _exit(); },
    child: Scaffold(
      appBar: AppBar(title: Text(widget.mode.title),
        leading: IconButton(onPressed: _closing ? null : _exit,
            icon: const Icon(Icons.arrow_back)),
        actions: [
          IconButton(tooltip: 'Reset all effects', onPressed: _ready && !_busy ? _reset : null,
              icon: const Icon(Icons.restart_alt)),
          IconButton(tooltip: 'Flip camera', onPressed: !_ready || _closing ? null : () async {
            try { await NosmaiFlutter.instance.switchCamera(); }
            catch (_) { if (mounted) setState(() => _status = 'Camera flip failed'); }
          }, icon: const Icon(Icons.cameraswitch_outlined)),
        ],
      ),
      body: SafeArea(child: Column(children: [
        Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(18),
          child: Stack(fit: StackFit.expand, children: [
            const ColoredBox(color: Colors.black),
            NosmaiCameraPreview(onInitialized: _onCameraReady,
              onError: (msg) { if (mounted) setState(() => _status = 'Camera error: check license and permissions'); }),
            Positioned(left: 12, right: 12, top: 12,
              child: DecoratedBox(decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(12)),
                child: Padding(padding: const EdgeInsets.all(10),
                  child: Text(_status, style: const TextStyle(fontSize: 12))),
              )),
          ]),
        )),
        if (_closing || _busy || _startingLive) const LinearProgressIndicator(minHeight: 2),
        _liveInfo(),
        SizedBox(height: 250, child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _modePanel(),
        )),
        Padding(padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
          child: SizedBox(width: double.infinity, height: 50,
            child: FilledButton.icon(
              onPressed: _ready && !_closing && !_busy && !_startingLive && !_stoppingLive
                  ? (_live == null ? _startLive : _endFilteredLive) : null,
              icon: Icon(_live == null ? Icons.sensors : Icons.stop_circle),
              label: Text(_live == null ? 'Start Live (Nosmai + Tencent)' : 'End Live'),
            ),
          ),
        ),
      ])),
    ),
  );
}
