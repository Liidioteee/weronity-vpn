import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

// ---- C signatures -------------------------------------------------------

typedef _StrRetC = Pointer<Utf8> Function();
typedef _StrArgC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _StrArgDart = Pointer<Utf8> Function(Pointer<Utf8>);
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

  /// Library names to try, in order. Shared with the isolate helper.
  static List<String> _libNames() => switch (_os()) {
        _Os.windows => const ['weronity_core.dll'],
        _Os.linux => const ['libweronity_core.so', 'weronity_core.so'],
        _Os.android => const ['libweronity_core.so'],
        _Os.other => const <String>[],
      };

  static NativeCore _load() {
    final names = _libNames();
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
  late final _isElevated =
      _lib?.lookupFunction<_IntRetC, _IntRetDart>('wrnIsElevated');
  late final _relaunchElevated =
      _lib?.lookupFunction<_IntRetC, _IntRetDart>('wrnRelaunchElevated');

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

  /// Process elevation: `1` elevated (admin), `0` not, `-1` unknown / n/a
  /// (non-Windows, or the core is missing).
  int elevation() => _isElevated?.call() ?? -1;

  /// Re-launch this executable with a UAC prompt. `0` = elevated instance is
  /// starting (the caller should `exit(0)`), `1` = user declined, `-1` = failed.
  int relaunchElevated() => _relaunchElevated?.call() ?? -1;

  /// Boots the sing-box engine for one node [outbound] (Go sanitizes it).
  /// Returns 0 on success.
  ///
  /// [mode] `'proxy'` opens a loopback proxy on 127.0.0.1:[listenPort]
  /// (0 = pick free; default 55555). `'vpn'` is rejected until Phase 3.3.
  int startNode(
    Map<String, dynamic> outbound, {
    String mode = 'proxy',
    int listenPort = 0,
    bool selfTest = true,
    String logLevel = 'info',
  }) {
    final fn = _start;
    if (fn == null) return -1;
    final payload = jsonEncode({
      'outbound': outbound,
      'mode': mode,
      'listen_port': listenPort,
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

  /// Isolated reachability test for one node — spins a throwaway sing-box on an
  /// ephemeral loopback port, runs HTTP probes through it, tears it down.
  /// Never touches an active connection. Runs in a helper isolate so it doesn't
  /// block the UI (it can take a few seconds). Returns the `probeSummary` map,
  /// or null if the core is missing / the call failed.
  Future<Map<String, dynamic>?> testNode(
    Map<String, dynamic> outbound, {
    List<String>? targets,
    int timeoutMs = 7000,
  }) {
    if (!isAvailable) return Future<Map<String, dynamic>?>.value();
    final payload = jsonEncode({
      'outbound': outbound,
      if (targets != null && targets.isNotEmpty) 'targets': targets,
      'timeout_ms': timeoutMs,
    });
    return Isolate.run(() => _runTestNode(payload));
  }
}

/// Isolate entrypoint: opens its own handle to the native library, calls
/// `wrnTestNode`, frees the result. Must be a top-level function.
Map<String, dynamic>? _runTestNode(String payload) {
  DynamicLibrary? lib;
  for (final name in NativeCore._libNames()) {
    try {
      lib = DynamicLibrary.open(name);
      break;
    } on Object {
      // try the next name
    }
  }
  if (lib == null) return null;
  final test = lib.lookupFunction<_StrArgC, _StrArgDart>('wrnTestNode');
  final free = lib.lookupFunction<_FreeC, _FreeDart>('wrnFree');
  final p = payload.toNativeUtf8();
  try {
    final rp = test(p);
    try {
      return jsonDecode(rp.toDartString()) as Map<String, dynamic>;
    } finally {
      free(rp);
    }
  } on Object {
    return null;
  } finally {
    malloc.free(p);
  }
}

enum _Os { windows, linux, android, other }

_Os _os() {
  if (Platform.isWindows) return _Os.windows;
  if (Platform.isAndroid) return _Os.android;
  if (Platform.isLinux) return _Os.linux;
  return _Os.other;
}
