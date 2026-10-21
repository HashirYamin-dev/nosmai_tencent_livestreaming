import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_credentials.dart';
import 'nosmai_studio.dart';

// NOSMAI_DASHBOARD_PHASE2
// All category tiles open the SAME Nosmai camera route with a mode-specific
// tool panel. Separate preview sessions are never active simultaneously.
class NosmaiDashboardPage extends StatefulWidget {
  const NosmaiDashboardPage({
    super.key,
    required this.hostCredentials,
    required this.viewerCredentials,
    required this.buildLivePage,
    required this.buildLegacyPage,
  });
  final AppCredentials hostCredentials;
  final AppCredentials viewerCredentials;
  final Widget Function(bool isHost, int roomId) buildLivePage;
  final Widget Function() buildLegacyPage;

  @override
  State<NosmaiDashboardPage> createState() => _NosmaiDashboardPageState();
}

class _NosmaiDashboardPageState extends State<NosmaiDashboardPage> {
  final TextEditingController _room = TextEditingController(text: '1001');
  bool _opening = false;

  @override
  void dispose() { _room.dispose(); super.dispose(); }

  int? _roomNumber() {
    final number = int.tryParse(_room.text.trim());
    if (number == null || number < 1 || number > 4294967294) return null;
    return number;
  }

  Future<void> _alert(String title, String text) async {
    if (!mounted) return;
    await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
      title: Text(title), content: Text(text), actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK')),
      ],
    ));
  }

  Future<void> _openLive(bool host) async {
    final room = _roomNumber();
    if (room == null) {
      await _alert('Invalid Room ID', 'Enter a number between 1 and 4294967294.');
      return;
    }
    final credentials = host ? widget.hostCredentials : widget.viewerCredentials;
    final error = credentials.validate();
    if (error != null) {
      await _alert('Tencent setup required', error);
      return;
    }
    if (!Platform.isAndroid && !Platform.isIOS) {
      await _alert('Physical phone needed', 'Use a connected Android or iOS phone.');
      return;
    }
    if (host) {
      final result = await [Permission.camera, Permission.microphone].request();
      if (!mounted) return;
      if (result[Permission.camera] != PermissionStatus.granted ||
          result[Permission.microphone] != PermissionStatus.granted) {
        await _alert('Permissions required',
            'Allow camera and microphone permissions for Tencent live.');
        return;
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => widget.buildLivePage(host, room),
    ));
  }

  Future<void> _openStudio(NosmaiStudioMode mode) async {
    if (_opening) return;
    if (_roomNumber() == null) {
      await _alert('Invalid Room ID', 'Enter a numeric room ID, for example 1001.');
      return;
    }
    setState(() => _opening = true);
    try {
      // Called only after Nosmai has stopped its camera and navigated back.
      await openNosmaiStudio(context, mode,
          hostCredentials: widget.hostCredentials,
          roomId: _roomNumber(),
          onUnfilteredLive: () => _openLive(true));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final modes = NosmaiStudioMode.values;
    return Scaffold(
      appBar: AppBar(title: const Text('Nosmai × Tencent'), actions: [
        IconButton(
          tooltip: 'Original Tencent screen',
          onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute(
            builder: (_) => widget.buildLegacyPage(),
          )),
          icon: const Icon(Icons.video_camera_front_outlined),
        ),
      ]),
      body: SafeArea(child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: const LinearGradient(colors: [Color(0xFF163449), Color(0xFF122038)]),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.auto_awesome, size: 35, color: Color(0xFF72E3EA)),
                const SizedBox(height: 12),
                const Text('Create your live look', style: TextStyle(
                  fontSize: 25, fontWeight: FontWeight.w800)),
                const SizedBox(height: 7),
                Text('Select a feature to open the Nosmai camera and edit your look.',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              ]),
            ),
            const SizedBox(height: 20),
            TextField(
              key: const ValueKey('room-id'), controller: _room,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 10, enabled: !_opening,
              decoration: const InputDecoration(
                labelText: 'Room ID', prefixIcon: Icon(Icons.meeting_room_outlined),
                helperText: 'Use the same room for host and viewer',
              ),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Text('NOSMAI FEATURES', style: TextStyle(
                color: scheme.primary, fontWeight: FontWeight.w700, letterSpacing: 1.1)),
              const Spacer(),
              const Text('Tap to open camera', style: TextStyle(fontSize: 12)),
            ]),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 12,
                childAspectRatio: 1.27,
              ),
              itemCount: modes.length,
              itemBuilder: (context, index) {
                final mode = modes[index];
                return Card(clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: _opening ? null : () => _openStudio(mode),
                    child: Padding(padding: const EdgeInsets.all(14),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(children: [
                            Icon(mode.icon, size: 29, color: scheme.primary),
                            const Spacer(),
                            const Icon(Icons.arrow_outward, size: 17),
                          ]),
                          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(mode.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                            const SizedBox(height: 2),
                            Text(mode.detail, maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                          ]),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 22),
            const Text('LIVESTREAM', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            SizedBox(height: 54, child: FilledButton.icon(
              onPressed: _opening ? null : () => _openLive(false),
              icon: const Icon(Icons.live_tv), label: const Text('Watch Live'),
            )),
            const SizedBox(height: 10),
            SizedBox(height: 50, child: OutlinedButton.icon(
              onPressed: _opening ? null : () => _openLive(true),
              icon: const Icon(Icons.videocam_outlined),
              label: const Text('Tencent Live (without Nosmai)'),
            )),
            const SizedBox(height: 10),
            const Text('Android: V2 CPU-copy (8fps) validation only. '
              'Verify transmitted frames on a second phone before production. '
              'iOS: filtered-video publishing is not available yet.',
              style: TextStyle(fontSize: 12, color: Colors.amber)),
            if (_opening) const Padding(padding: EdgeInsets.only(top: 10),
                child: LinearProgressIndicator()),
          ],
        ),
      ))),
    );
  }
}
