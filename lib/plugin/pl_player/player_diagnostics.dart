import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter/scheduler.dart' show FrameTiming;
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:path/path.dart' as p;

/// Opt-in playback diagnostics for the media_kit / mpv render path.
///
/// Enable it at build time with:
/// `--dart-define=PLAYER_DIAGNOSTICS=true`
///
/// It writes two files into `appSupportDirPath`:
/// * `player_diagnostics_<time>.log`: one `key=value` sample per second with
///   mpv frame-drop / vsync / A-V sync properties and Flutter frame timings.
/// * `player_mpv_<time>.log`: libmpv's own verbose log (vo/vd/cplayer).
final class PlayerDiagnostics {
  PlayerDiagnostics._();

  static final PlayerDiagnostics instance = PlayerDiagnostics._();

  static const bool enabled = bool.fromEnvironment('PLAYER_DIAGNOSTICS');

  /// Marks builds which use the native D3D11 render backend.
  static const bool d3d11 = bool.fromEnvironment('MEDIA_KIT_D3D11');

  /// Properties sampled once per second and shown in the playback info dialog.
  static const List<String> properties = [
    'time-pos',
    'video-pts',
    'audio-pts',
    'avsync',
    'frame-drop-count',
    'decoder-frame-drop-count',
    'vo-delayed-frame-count',
    'mistimed-frame-count',
    'estimated-vf-fps',
    'display-fps',
    'estimated-display-fps',
    'vsync-ratio',
    'vsync-jitter',
    'video-sync',
    'hwdec-current',
    'current-vo',
    'container-fps',
    'video-bitrate',
    'audio-bitrate',
    'demuxer-cache-duration',
  ];

  NativePlayer? _player;
  Timer? _timer;

  String? _sampleLogPath;
  String? _mpvLogPath;

  int _frameCount = 0;
  int _slowFrameCount = 0;
  double _buildTotalMs = 0;
  double _rasterTotalMs = 0;
  double _rasterMaxMs = 0;
  double _totalMaxMs = 0;

  final String _runStamp = _formatStamp(DateTime.now());

  String get sampleLogPath =>
      _sampleLogPath ?? p.join(appSupportDirPath, 'player_diagnostics_$_runStamp.log');

  String get mpvLogPath =>
      _mpvLogPath ?? p.join(appSupportDirPath, 'player_mpv_$_runStamp.log');

  /// Options which must be passed to [NativePlayer] before `mpv_initialize`.
  Map<String, String> get mpvOptions {
    if (!enabled) {
      return const {};
    }
    _mpvLogPath ??= mpvLogPath;
    return {
      'log-file': _mpvLogPath!,
      // Keep the file small: only the modules which explain frame pacing,
      // seeking and decoding are enabled. mpv's log file records debug level
      // for those modules, so leave everything else off.
      'msg-level': 'all=no,vo=v,vd=v,cplayer=v',
    };
  }

  /// Starts sampling [player] once per second.
  void attach(NativePlayer player) {
    if (!enabled) {
      return;
    }
    if (identical(player, _player)) {
      return;
    }
    _timer?.cancel();
    _player = player;
    _resetFrameStats();
    _sampleLogPath ??= sampleLogPath;
    _mpvLogPath ??= mpvLogPath;
    try {
      final file = File(_sampleLogPath!);
      if (!file.existsSync() || file.lengthSync() == 0) {
        file.writeAsStringSync(_header(), flush: true);
      } else {
        file.writeAsStringSync(
          '\n# player recreated at ${DateTime.now().toIso8601String()}\n',
          mode: FileMode.append,
          flush: true,
        );
      }
    } catch (_) {
      // Diagnostics must never break playback.
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _sample());
  }

  /// Stops sampling. Pass [player] to avoid detaching a newer player.
  void detach([NativePlayer? player]) {
    if (!enabled) {
      return;
    }
    if (player != null && !identical(player, _player)) {
      return;
    }
    _timer?.cancel();
    _timer = null;
    if (_player != null) {
      _sample();
    }
    _player = null;
  }

  /// A snapshot for the playback info dialog. Does not reset counters.
  Map<String, String> snapshot([NativePlayer? player]) {
    final p = player ?? _player;
    if (p == null) {
      return const {};
    }
    final values = <String, String>{};
    for (final property in properties) {
      values[property] = _read(p, property);
    }
    values['flutter-frames'] = '$_frameCount';
    values['flutter-build-ms'] = _average(_buildTotalMs, _frameCount);
    values['flutter-raster-ms'] = _average(_rasterTotalMs, _frameCount);
    values['flutter-raster-max-ms'] = _rasterMaxMs.toStringAsFixed(2);
    values['flutter-frame-max-ms'] = _totalMaxMs.toStringAsFixed(2);
    values['flutter-slow-frames'] = '$_slowFrameCount';
    return values;
  }

  /// A copyable report for the playback info dialog.
  String report([NativePlayer? player]) {
    final buffer = StringBuffer()
      ..writeln(
        'PiliPlus ${BuildConfig.versionName} '
        '(${BuildConfig.versionCode}, ${BuildConfig.commitHash})',
      )
      ..writeln('time=${DateTime.now().toIso8601String()}')
      ..writeln('platform=${Platform.operatingSystemVersion}')
      ..writeln('render-backend=${d3d11 ? 'd3d11' : 'opengl-angle'}');
    final values = snapshot(player);
    for (final entry in values.entries) {
      buffer.writeln('${entry.key}=${entry.value}');
    }
    buffer
      ..writeln('mpv-log=$mpvLogPath')
      ..writeln('sample-log=$sampleLogPath');
    return buffer.toString();
  }

  /// Registered on [SchedulerBinding.addTimingsCallback].
  void addTimings(List<FrameTiming> timings) {
    if (!enabled || _player == null) {
      return;
    }
    for (final timing in timings) {
      final buildMs = timing.buildDuration.inMicroseconds / 1000;
      final rasterMs = timing.rasterDuration.inMicroseconds / 1000;
      final totalMs = buildMs + rasterMs;
      _frameCount++;
      _buildTotalMs += buildMs;
      _rasterTotalMs += rasterMs;
      if (rasterMs > _rasterMaxMs) {
        _rasterMaxMs = rasterMs;
      }
      if (totalMs > _totalMaxMs) {
        _totalMaxMs = totalMs;
      }
      // A frame is considered slow when its UI + raster work exceeds one
      // 60 Hz vsync interval. The actual display refresh is logged separately.
      if (totalMs > 16.7) {
        _slowFrameCount++;
      }
    }
  }

  void _sample() {
    final player = _player;
    if (player == null) {
      return;
    }
    final values = snapshot(player);
    values['t'] = DateTime.now().toIso8601String();
    final buffer = StringBuffer();
    for (final entry in values.entries) {
      if (entry.value.isEmpty) {
        continue;
      }
      if (buffer.isNotEmpty) {
        buffer.write(' ');
      }
      buffer
        ..write(entry.key)
        ..write('=')
        ..write(entry.value);
    }
    _resetFrameStats();
    _append(buffer.toString());
  }

  void _append(String line) {
    try {
      File(sampleLogPath).writeAsStringSync(
        '$line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Diagnostics must never break playback.
    }
  }

  String _header() {
    final buffer = StringBuffer()
      ..writeln('# PiliPlus player diagnostics')
      ..writeln('time=${DateTime.now().toIso8601String()}')
      ..writeln('version=${BuildConfig.versionName}')
      ..writeln('version-code=${BuildConfig.versionCode}')
      ..writeln('commit=${BuildConfig.commitHash}')
      ..writeln('build-time=${BuildConfig.buildTime}')
      ..writeln('platform=${Platform.operatingSystemVersion}')
      ..writeln('render-backend=${d3d11 ? 'd3d11' : 'opengl-angle'}')
      ..writeln('sample-log=$sampleLogPath')
      ..writeln('mpv-log=$mpvLogPath')
      ..writeln('# one line per second, key=value');
    return buffer.toString();
  }

  String _read(NativePlayer player, String property) {
    try {
      return player.getProperty(property).trim();
    } catch (_) {
      return '';
    }
  }

  void _resetFrameStats() {
    _frameCount = 0;
    _slowFrameCount = 0;
    _buildTotalMs = 0;
    _rasterTotalMs = 0;
    _rasterMaxMs = 0;
    _totalMaxMs = 0;
  }

  String _average(double total, int count) {
    if (count == 0) {
      return '0.00';
    }
    return (total / count).toStringAsFixed(2);
  }

  static String _formatStamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${two(time.month)}${two(time.day)}_'
        '${two(time.hour)}${two(time.minute)}${two(time.second)}';
  }
}
