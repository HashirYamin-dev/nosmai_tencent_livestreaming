import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nosmai_tencent_live/nosmai_tencent_live.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'nosmai_license_local.dart';
import 'app_credentials.dart';

// Each studio route owns exactly ONE NosmaiCameraPreview. Start Live publishes
// that preview (with every applied effect) through nosmai_tencent_live; this
// app contains no Android or iOS bridge code of its own.

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

Future<void> openNosmaiStudio(
  BuildContext context,
  NosmaiStudioMode mode, {
  AppCredentials? hostCredentials,
  int? roomId,
}) async {
  if (!Platform.isAndroid && !Platform.isIOS) {
    await _studioAlert(context, 'Physical phone required',
        'Nosmai camera requires an Android/iOS physical device.');
    return;
  }
  final permissions = await NosmaiTencentLive.requestPermissions();
  if (!context.mounted) return;
  if (!permissions.camera) {
    await _studioAlert(context, 'Camera permission needed',
        'Allow camera permission in Android/iOS Settings.');
    return;
  }
  try {
    // NOSMAI_AUTO_LICENSE_LOCAL_V1: local QA keys unless a platform key is
    // passed with --dart-define. An empty local iOS key falls back to the
    // Android one.
    String key(String fromBuild, String local) =>
        fromBuild.trim().isNotEmpty ? fromBuild.trim() : local.trim();
    await NosmaiTencentLive.initialize(
      androidLicenseKey: key(
          const String.fromEnvironment('NOSMAI_ANDROID_LICENSE_KEY'), nosmaiLocalLicenseKey),
      iosLicenseKey: key(const String.fromEnvironment('NOSMAI_IOS_LICENSE_KEY'),
          nosmaiLocalIosLicenseKey.trim().isNotEmpty
              ? nosmaiLocalIosLicenseKey
              : nosmaiLocalLicenseKey),
    );
  } on NosmaiLiveException catch (e) {
    if (!context.mounted) return;
    await _studioAlert(context, 'Nosmai initialization failed', e.message);
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push<void>(MaterialPageRoute(
    builder: (_) => NosmaiStudioPage(
      mode: mode,
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
    this.hostCredentials, this.roomId});
  final NosmaiStudioMode mode;
  final AppCredentials? hostCredentials;
  final int? roomId;

  @override
  State<NosmaiStudioPage> createState() => _NosmaiStudioPageState();
}

class _NosmaiStudioPageState extends State<NosmaiStudioPage>
    with NosmaiCameraLifecycleMixin {
  NosmaiLiveBroadcaster? _live;
  bool _startingLive = false;
  bool _stoppingLive = false;
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
    await _endLive();
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

  // Publishes this screen's Nosmai preview. Optional quality preset:
  // --dart-define=LIVE_QUALITY=low|standard|hd (default standard).
  static const _quality = String.fromEnvironment('LIVE_QUALITY', defaultValue: 'standard');

  NosmaiLiveVideoConfig get _videoConfig => switch (_quality) {
    'low' => NosmaiLiveVideoConfig.low,
    'hd' => NosmaiLiveVideoConfig.hd,
    _ => NosmaiLiveVideoConfig.standard,
  };

  Future<void> _startLive() async {
    if (!_ready || _closing || _startingLive || _live != null) return;
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
    final live = NosmaiLiveBroadcaster(
      credentials: credentials.toLive(),
      room: NosmaiLiveRoom(roomId),
      video: _videoConfig,
    );
    live.addListener(_onLiveChanged);
    setState(() { _live = live; _startingLive = true; _status = 'Connecting to Tencent room $roomId...'; });
    try {
      await live.start();
      unawaited(_keepAwake(true));
    } on NosmaiLiveException catch (e) {
      await _endLive();
      if (!mounted || _closing) return;
      await _studioAlert(context, 'Livestream could not start', e.message);
    } finally {
      if (mounted) setState(() => _startingLive = false);
    }
  }

  void _onLiveChanged() {
    if (!mounted || _closing) return;
    final live = _live;
    if (live == null) return;
    setState(() {
      _status = switch (live.state) {
        NosmaiLiveState.live => 'LIVE in room ${widget.roomId}',
        NosmaiLiveState.reconnecting => 'Connection lost · Reconnecting…',
        NosmaiLiveState.paused => 'Paused in background',
        NosmaiLiveState.failed => 'Live stopped: ${live.error ?? 'unknown error'}',
        NosmaiLiveState.stopping || NosmaiLiveState.stopped => 'Live ended',
        _ => 'Connecting to Tencent room ${widget.roomId}...',
      };
    });
    if (live.state == NosmaiLiveState.failed) unawaited(_endLive());
  }

  Future<void> _endLive() async {
    if (_stoppingLive) return;
    _stoppingLive = true;
    final live = _live;
    _live = null;
    if (live != null) {
      live.removeListener(_onLiveChanged);
      await live.stop();
      live.dispose();
    }
    await _keepAwake(false);
    _stoppingLive = false;
    if (mounted && !_closing) setState(() {});
  }

  Future<void> _keepAwake(bool enabled) async {
    try {
      await WakelockPlus.toggle(enable: enabled);
    } catch (_) {/* Screen-idle support must not block the broadcast. */}
  }

  Widget _liveInfo() {
    final live = _live;
    if (live == null) return const SizedBox.shrink();
    final stats = live.stats;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: Text(
        'Sent ${stats.width}x${stats.height} ${stats.fps} fps · '
        '${stats.videoBitrateKbps} kbps · RTT ${stats.rttMs} ms · up loss ${stats.upLossPercent}%\n'
        'Nosmai frames ${stats.framesFromNosmai} · to Tencent ${stats.framesSent} · '
        'dropped ${stats.framesDropped} · ${stats.transport}'
        '${live.warning != null ? '\n${live.warning}' : ''}',
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
                  ? (_live == null ? _startLive : _endLive) : null,
              icon: Icon(_live == null ? Icons.sensors : Icons.stop_circle),
              label: Text(_live == null ? 'Start Live (Nosmai + Tencent)' : 'End Live'),
            ),
          ),
        ),
      ])),
    ),
  );
}
