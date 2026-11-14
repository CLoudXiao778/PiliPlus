import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/player_diagnostics.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;

/// Live mpv / Flutter frame statistics for the playback info dialog.
///
/// Only shown in builds with `--dart-define=PLAYER_DIAGNOSTICS=true`.
class PlayerDiagnosticsPanel extends StatefulWidget {
  const PlayerDiagnosticsPanel({super.key, required this.player});

  final NativePlayer player;

  @override
  State<PlayerDiagnosticsPanel> createState() => _PlayerDiagnosticsPanelState();
}

class _PlayerDiagnosticsPanelState extends State<PlayerDiagnosticsPanel> {
  Timer? _timer;
  Map<String, String> _values = const {};

  @override
  void initState() {
    super.initState();
    _values = PlayerDiagnostics.instance.snapshot(widget.player);
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) {
        _refresh();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _values = PlayerDiagnostics.instance.snapshot(widget.player);
    });
  }

  String _value(String key) {
    final value = _values[key];
    if (value == null || value.isEmpty) {
      return '-';
    }
    return value;
  }

  void _copy(String label, String key) {
    Utils.copyText('$label ($key)\n${_value(key)}');
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return Column(
      children: [
        Padding(
          padding: const .symmetric(horizontal: 24, vertical: 4),
          child: Text(
            '每 0.5 秒刷新。播放 10 秒、拖动一次进度条后再复制。',
            style: TextStyle(fontSize: 12, color: colorScheme.outline),
          ),
        ),
        _tile('视频输出 FPS', 'estimated-vf-fps'),
        _tile('显示刷新率', 'display-fps'),
        _tile('VO 丢帧', 'frame-drop-count'),
        _tile('解码丢帧', 'decoder-frame-drop-count'),
        _tile('VO 延迟帧', 'vo-delayed-frame-count'),
        _tile('时机错误帧', 'mistimed-frame-count'),
        _tile('A/V 同步 (s)', 'avsync'),
        _tile('视频 PTS', 'video-pts'),
        _tile('音频 PTS', 'audio-pts'),
        _tile('同步模式', 'video-sync'),
        _tile('硬解 / VO', 'hwdec-current', secondKey: 'current-vo'),
        _tile(
          'Flutter 帧 / build / raster',
          'flutter-frames',
          secondKey: 'flutter-build-ms',
          thirdKey: 'flutter-raster-ms',
        ),
        _tile(
          'Flutter raster 最大 / 慢帧',
          'flutter-raster-max-ms',
          secondKey: 'flutter-slow-frames',
        ),
        ListTile(
          dense: true,
          title: const Text('诊断日志'),
          subtitle: Text(
            PlayerDiagnostics.instance.sampleLogPath,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () =>
              Utils.copyText(PlayerDiagnostics.instance.sampleLogPath),
        ),
      ],
    );
  }

  Widget _tile(
    String label,
    String key, {
    String? secondKey,
    String? thirdKey,
  }) {
    final parts = [
      _value(key),
      if (secondKey != null) _value(secondKey),
      if (thirdKey != null) _value(thirdKey),
    ];
    return ListTile(
      dense: true,
      title: Text(label),
      subtitle: Text(parts.join(' / ')),
      onTap: () => _copy(label, key),
    );
  }
}
