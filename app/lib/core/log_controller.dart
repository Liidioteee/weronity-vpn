import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;

import '../app/theme/tokens.dart';

enum LogLevel {
  debug,
  info,
  warn,
  error;

  static LogLevel parse(String raw) => switch (raw.toLowerCase()) {
        'debug' || 'trace' || 'verbose' => LogLevel.debug,
        'warn' || 'warning' => LogLevel.warn,
        'error' || 'err' || 'fatal' => LogLevel.error,
        _ => LogLevel.info,
      };

  String get label => switch (this) {
        LogLevel.debug => 'DEBUG',
        LogLevel.info => 'INFO',
        LogLevel.warn => 'WARN',
        LogLevel.error => 'ERROR',
      };

  Color get color => switch (this) {
        LogLevel.debug => WColors.textMutedDark,
        LogLevel.info => WColors.info,
        LogLevel.warn => WColors.connecting,
        LogLevel.error => WColors.danger,
      };
}

@immutable
class LogLine {
  const LogLine({
    required this.level,
    required this.ts,
    required this.tag,
    required this.message,
  });

  final LogLevel level;
  final DateTime ts;
  final String tag;
  final String message;

  String get clock {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(ts.hour)}:${two(ts.minute)}:${two(ts.second)}.${three(ts.millisecond)}';
  }

  @override
  String toString() => '$clock ${level.label.padRight(5)} [$tag] $message';
}

/// In-memory ring buffer of core log lines.
///
/// Phase 2 fills it with synthetic lines from the stub [ConnectionController];
/// Phase 3 will pipe sing-box's real log stream through the same sink.
class LogController extends ChangeNotifier {
  LogController({this.capacity = 500});

  final int capacity;
  final Queue<LogLine> _lines = Queue<LogLine>();

  List<LogLine> get lines => List<LogLine>.unmodifiable(_lines);
  int get length => _lines.length;

  void add(String level, String tag, String message) {
    _lines.addLast(
      LogLine(
        level: LogLevel.parse(level),
        ts: DateTime.now(),
        tag: tag,
        message: message,
      ),
    );
    while (_lines.length > capacity) {
      _lines.removeFirst();
    }
    notifyListeners();
  }

  void clear() {
    if (_lines.isEmpty) return;
    _lines.clear();
    notifyListeners();
  }

  String dump([Iterable<LogLine>? subset]) =>
      (subset ?? _lines).map((l) => l.toString()).join('\n');
}
