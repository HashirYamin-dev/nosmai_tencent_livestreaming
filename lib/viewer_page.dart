import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nosmai_tencent_live/nosmai_tencent_live.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app_credentials.dart';

/// Watches the broadcaster in a room. Needs no Nosmai license or camera.
class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key, required this.credentials, required this.roomId});

  final AppCredentials credentials;
  final int roomId;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  late final NosmaiLiveViewer _viewer = NosmaiLiveViewer(
    credentials: widget.credentials.toLive(),
    room: NosmaiLiveRoom(widget.roomId),
  );
  bool _leaving = false;
  bool _allowPop = false;

  @override
  void initState() {
    super.initState();
    unawaited(_keepAwake(true));
    // Failures are shown from viewer.error; nothing else to do here.
    unawaited(_viewer.start().catchError((Object _) {}));
  }

  Future<void> _keepAwake(bool enabled) async {
    try {
      await WakelockPlus.toggle(enable: enabled);
    } catch (_) {/* Screen-idle support must not block playback. */}
  }

  Future<void> _leave() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    await _viewer.stop();
    await _keepAwake(false);
    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _viewer.dispose();
    unawaited(_keepAwake(false));
    super.dispose();
  }

  String get _status => switch (_viewer.state) {
        NosmaiLiveState.idle || NosmaiLiveState.connecting => 'Connecting to Tencent…',
        NosmaiLiveState.waitingForHost => _viewer.watchingUserId == null
            ? 'Waiting for host…'
            : 'Loading host video…',
        NosmaiLiveState.live => 'Watching live',
        NosmaiLiveState.reconnecting => 'Connection lost · Reconnecting…',
        NosmaiLiveState.paused => 'Paused while the app is in the background',
        NosmaiLiveState.stopping => 'Leaving room…',
        NosmaiLiveState.stopped => 'Session ended',
        NosmaiLiveState.failed => 'Session stopped',
      };

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_leave());
      },
      child: ListenableBuilder(
        listenable: _viewer,
        builder: (context, _) {
          final stats = _viewer.stats;
          return Scaffold(
            appBar: AppBar(
              leading: IconButton(
                  onPressed: _leaving ? null : _leave, icon: const Icon(Icons.arrow_back)),
              title: Text('Viewer · Room ${widget.roomId}'),
            ),
            body: SafeArea(
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(children: [
                    Icon(_viewer.state == NosmaiLiveState.reconnecting
                        ? Icons.wifi_off
                        : Icons.sensors, size: 19),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_status,
                        style: const TextStyle(fontWeight: FontWeight.w600))),
                  ]),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Stack(fit: StackFit.expand, children: [
                        const ColoredBox(color: Colors.black),
                        NosmaiLiveViewerView(
                          viewer: _viewer,
                          placeholder: _Placeholder(
                            error: _viewer.error,
                            status: _status,
                            roomId: widget.roomId,
                            waiting: _viewer.watchingUserId == null,
                          ),
                        ),
                        if (_viewer.hasVideo)
                          Positioned(
                            left: 12, bottom: 12, right: 12,
                            child: IgnorePointer(
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                color: Colors.black.withValues(alpha: 0.6),
                                child: Text(
                                  'Host ${_viewer.watchingUserId} · '
                                  '${stats.width}x${stats.height} ${stats.fps} fps · '
                                  '${stats.videoBitrateKbps} kbps · RTT ${stats.rttMs} ms · '
                                  'loss ${stats.downLossPercent}%',
                                  style: const TextStyle(fontSize: 12)),
                              ),
                            ),
                          ),
                      ]),
                    ),
                  ),
                ),
                if (_viewer.warning != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_viewer.warning!,
                        maxLines: 3, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Theme.of(context).colorScheme.tertiary)),
                  ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(spacing: 8, alignment: WrapAlignment.center, children: [
                    OutlinedButton.icon(
                      onPressed: _viewer.state.isActive
                          ? () => _viewer.setSpeakerMuted(!_viewer.speakerMuted)
                          : null,
                      icon: Icon(_viewer.speakerMuted ? Icons.volume_off : Icons.volume_up,
                          size: 20),
                      label: Text(_viewer.speakerMuted ? 'Unmute sound' : 'Mute sound'),
                    ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.errorContainer,
                        foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                      onPressed: _leaving ? null : _leave,
                      icon: const Icon(Icons.call_end),
                      label: Text(_leaving ? 'Leaving…' : 'Leave'),
                    ),
                  ]),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.error, required this.status, required this.roomId,
      required this.waiting});

  final String? error;
  final String status;
  final int roomId;
  final bool waiting;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.black.withValues(alpha: 0.65),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(error != null ? Icons.error_outline : Icons.live_tv, size: 44),
              const SizedBox(height: 18),
              Text(error ?? status, textAlign: TextAlign.center),
              if (error == null && waiting) ...[
                const SizedBox(height: 12),
                Text('On the other phone, open a Nosmai feature\n'
                    'and tap Start Live in Room $roomId.', textAlign: TextAlign.center),
              ],
            ]),
          ),
        ),
      );
}
