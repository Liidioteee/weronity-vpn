import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// ---- C signatures -------------------------------------------------------

typedef _StrRetC = Pointer<Utf8> Function();
typedef _PingC = Int32 Function(Int32);
typedef _PingDart = int Function(int);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);
typedef _StartC = Int32 Function(Pointer<Utf8>);
typedef _StartDart = int Function(Pointer<Utf8>);
typedef _IntRetC = Int32 Function();
typedef _IntRetDart = int Function();

/// How the native core resolved on this platform.
enum NativeCoreState { ok, unavailable, unsupported }

/// Thin `dart:ffi` wrapper around `weronity_core` (the Go/cgo shared library
/// that embeds sing-box).
///
/// The engine here is **independent of `ConnectionController`** — Phase 3.1 uses
/// it only for an isolated "does sing-box boot a real node and carry traffic"
/// check. Phase 3.2 routes the real connection flow through it. If the library
/// is missing this degrades to [NativeCoreState.unavailable] rather than
/// throwing, so the app still runs on the stub controller.
class NativeCore {
  NativeCore._(this._lib);

  final DynamicLibrary? _lib;
  NativeCoreState _state = NativeCoreState.unavailable;
  String? _loadError;

  NativeCoreState get state => _state;
  String? get loadError => _loadError;
  bool get isAvailable => _state == NativeCoreState.ok;

  static NativeCore? _instance;
  static String? _lastLoadError;

  factory NativeCore.instance() => _instance ??= _load();

  static NativeCore _load() {
    final names = switch (_os()) {
      _Os.windows => const ['weronity_core.dll'],
      _Os.linux => const ['libweronity_core.so', 'weronity_core.so'],
      _Os.android => const ['libweronity_core.so'],
      _Os.other => const <String>[],
    };
    if (names.isEmpty) {
      return NativeCore._(null)
        .._state = NativeCoreState.unsupported
        .._loadError = 'no native core for this platform yet';
    }
    for (final name in names) {
      try {
        return NativeCore._(DynamicLibrary.open(name))
          .._state = NativeCoreState.ok;
      } on Object catch (e) {
        _lastLoadError = '$e';
      }
    }
    return NativeCore._(null)
      .._state = NativeCoreState.unavailable
      .._loadError = _lastLoadError;
  }

  // ---- lazy-bound symbols -----------------------------------------

  late final _version =
      _lib?.lookupFunction<_StrRetC, _StrRetC>('wrnCoreVersion');
  late final _ping = _lib?.lookupFunction<_PingC, _PingDart>('wrnPing');
  late final _free = _lib?.lookupFunction<_FreeC, _FreeDart>('wrnFree');
  late final _start = _lib?.lookupFunction<_StartC, _StartDart>('wrnStart');
  late final _stop = _lib?.lookupFunction<_IntRetC, _IntRetDart>('wrnStop');
  late final _isRunning =
      _lib?.lookupFunction<_IntRetC, _IntRetDart>('wrnIsRunning');
  late final _stats = _lib?.lookupFunction<_StrRetC, _StrRetC>('wrnStatsJSON');
  late final _drain =
      _lib?.lookupFunction<_StrRetC, _StrRetC>('wrnDrainEvents');

  String? _takeString(Pointer<Utf8> Function()? fn) {
    final free = _free;
    if (fn == null || free == null) return null;
    final ptr = fn();
    try {
      return ptr.toDartString();
    } finally {
      free(ptr);
    }
  }

  /// Version string baked into the library.
  String? version() => _takeString(_version);

  /// Round-trips an int (`x` -> `x + 1`). Smoke test.
  int? ping(int x) => _ping?.call(x);

  bool isRunning() => (_isRunning?.call() ?? 0) == 1;

  /// Boots the sing-box engine for one sanitized node [outbound].
  /// Returns 0 on success. The engine opens a loopback-only SOCKS inbound.
  int startNode(
    Map<String, dynamic> outbound, {
    int socksPort = 0,
    bool selfTest = true,
    String logLevel = 'info',
  }) {
    final fn = _start;
    if (fn == null) return -1;
    final payload = jsonEncode({
      'outbound': outbound,
      'socks_port': socksPort,
      'self_test': selfTest,
      'log_level': logLevel,
    });
    final p = payload.toNativeUtf8();
    try {
      return fn(p);
    } finally {
      malloc.free(p);
    }
  }

  int stop() => _stop?.call() ?? -1;

  /// `{running, socks_port, uptime_ms, self_test:{done,ok,status,latency_ms}}`.
  Map<String, dynamic>? stats() {
    final s = _takeString(_stats);
    if (s == null) return null;
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } on FormatException {
      return null;
    }
  }

  /// Events (log lines) queued since the last call. Each is
  /// `{kind, level, tag, message}`.
  List<Map<String, dynamic>> drainEvents() {
    final s = _takeString(_drain);
    if (s == null || s == '[]') return const [];
    try {
      final list = jsonDecode(s) as List<dynamic>;
      return [
        for (final e in list)
          if (e is Map<String, dynamic>) e,
      ];
    } on FormatException {
      return const [];
    }
  }
}

enum _Os { windows, linux, android, other }

_Os _os() {
  if (Platform.isWindows) return _Os.windows;
  if (Platform.isAndroid) return _Os.android;
  if (Platform.isLinux) return _Os.linux;
  return _Os.other;
}
