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
typedef _IntArgC = Int32 Function(Int32);
typedef _IntArgDart = int Function(int);

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

  /// Library paths to try, in order. Shared with the isolate helpers.
  ///
  /// On desktop these are **absolute paths next to the executable**, never a
  /// bare name: a bare name goes through the OS search order (current
  /// directory, PATH…), and this process may be running elevated for VPN mode —
  /// a planted `weronity_core.dll` must not get loaded as administrator.
  static List<String> _libNames() {
    final sep = Platform.pathSeparator;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return switch (_os()) {
      _Os.windows => ['$exeDir${sep}weronity_core.dll'],
      _Os.linux => [
          '$exeDir${sep}lib${sep}libweronity_core.so',
          '$exeDir${sep}libweronity_core.so',
        ],
      // Android resolves a bare soname inside the APK's own lib directory.
      _Os.android => const ['libweronity_core.so'],
      _Os.other => const <String>[],
    };
  }

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
  late final _selectCandidate =
      _lib?.lookupFunction<_IntArgC, _IntArgDart>('wrnSelectCandidate');

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

  /// Boots the sing-box engine for the candidate set [outbounds] (Go sanitizes
  /// every one of them). Returns 0 on success.
  ///
  /// The first entry is the node to use; the rest are backups. Passing more
  /// than one makes the core build a `selector` group, which is what lets
  /// [selectCandidate] switch nodes later without tearing the tunnel down. Go
  /// caps the list at 32 and drops any backup it cannot sanitize; only a bad
  /// *first* entry fails the start.
  ///
  /// [mode] `'proxy'` opens a loopback proxy on 127.0.0.1:[listenPort]
  /// (0 = let the OS pick a free port); `'vpn'` builds the system-wide TUN.
  /// [strictRoute] applies to VPN mode only.
  ///
  /// **Blocks the calling isolate** until the engine is up — in VPN mode that
  /// includes creating the TUN adapter and can take seconds. UI code uses
  /// [startNodesAsync].
  int startNodes(
    List<Map<String, dynamic>> outbounds, {
    String mode = 'proxy',
    int listenPort = 0,
    bool selfTest = true,
    bool strictRoute = false,
    String logLevel = 'info',
  }) {
    final fn = _start;
    if (fn == null || outbounds.isEmpty) return -1;
    final p = _startPayload(
      outbounds,
      mode: mode,
      listenPort: listenPort,
      selfTest: selfTest,
      strictRoute: strictRoute,
      logLevel: logLevel,
    ).toNativeUtf8();
    try {
      return fn(p);
    } finally {
      malloc.free(p);
    }
  }

  /// [startNodes] on a helper isolate, so the UI keeps painting while the
  /// engine (and, in VPN mode, the TUN adapter) comes up. The engine state is
  /// process-wide, so [stats] / [drainEvents] on this isolate see the result.
  Future<int> startNodesAsync(
    List<Map<String, dynamic>> outbounds, {
    String mode = 'proxy',
    int listenPort = 0,
    bool selfTest = true,
    bool strictRoute = false,
    String logLevel = 'info',
  }) {
    if (!isAvailable || outbounds.isEmpty) return Future<int>.value(-1);
    final payload = _startPayload(
      outbounds,
      mode: mode,
      listenPort: listenPort,
      selfTest: selfTest,
      strictRoute: strictRoute,
      logLevel: logLevel,
    );
    return Isolate.run(() => _runStart(payload));
  }

  static String _startPayload(
    List<Map<String, dynamic>> outbounds, {
    required String mode,
    required int listenPort,
    required bool selfTest,
    required bool strictRoute,
    required String logLevel,
  }) =>
      jsonEncode({
        'outbounds': outbounds,
        'mode': mode,
        'listen_port': listenPort,
        'self_test': selfTest,
        'strict_route': strictRoute,
        'log_level': logLevel,
      });

  /// Single-node convenience wrapper around [startNodes].
  int startNode(
    Map<String, dynamic> outbound, {
    String mode = 'proxy',
    int listenPort = 0,
    bool selfTest = true,
    bool strictRoute = false,
    String logLevel = 'info',
  }) =>
      startNodes(
        [outbound],
        mode: mode,
        listenPort: listenPort,
        selfTest: selfTest,
        strictRoute: strictRoute,
        logLevel: logLevel,
      );

  /// Switches the running selector group to candidate [index] (the order given
  /// to [startNodes]) without restarting the engine — no tunnel teardown, and
  /// in VPN mode no network drop.
  ///
  /// Returns `true` on success. `false` means the core refused (the session was
  /// started with a single node, the index is out of range, or the engine is
  /// stopped) and the caller should fall back to stop/start.
  bool selectCandidate(int index) => (_selectCandidate?.call(index) ?? 1) == 0;

  /// Stops the engine. **Blocks** until the tunnel is torn down — see
  /// [stopAsync] for UI code.
  int stop() => _stop?.call() ?? -1;

  /// [stop] on a helper isolate: a TUN teardown that stalls must not freeze
  /// the window with it.
  Future<int> stopAsync() =>
      isAvailable ? Isolate.run(_runStop) : Future<int>.value(-1);

  /// `{running, mode, listen, socks_port, up_bytes, down_bytes, up_bps,
  /// down_bps, ping_ms, uptime_ms, self_test:{done,ok,status,latency_ms}, …}`.
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
  ///
  /// With [exitGeo] the summary also says where the node's traffic actually
  /// comes out: `exit_country`, a second opinion in `exit_country_alt`, and
  /// the exit address in `exit_ip` (asked in parallel with the probes, so it
  /// costs no extra time).
  Future<Map<String, dynamic>?> testNode(
    Map<String, dynamic> outbound, {
    List<String>? targets,
    int timeoutMs = 7000,
    bool exitGeo = false,
  }) {
    if (!isAvailable) return Future<Map<String, dynamic>?>.value();
    final payload = jsonEncode({
      'outbound': outbound,
      if (targets != null && targets.isNotEmpty) 'targets': targets,
      'timeout_ms': timeoutMs,
      if (exitGeo) 'exit_geo': true,
    });
    return Isolate.run(() => _runTestNode(payload));
  }
}

/// Opens a handle to the native library from a helper isolate (handles are
/// per-isolate; the library and its state are process-wide).
DynamicLibrary? _openLib() {
  for (final name in NativeCore._libNames()) {
    try {
      return DynamicLibrary.open(name);
    } on Object {
      // try the next name
    }
  }
  return null;
}

/// Isolate entrypoint for [NativeCore.startNodesAsync].
int _runStart(String payload) {
  final lib = _openLib();
  if (lib == null) return -1;
  final start = lib.lookupFunction<_StartC, _StartDart>('wrnStart');
  final p = payload.toNativeUtf8();
  try {
    return start(p);
  } finally {
    malloc.free(p);
  }
}

/// Isolate entrypoint for [NativeCore.stopAsync].
int _runStop() {
  final lib = _openLib();
  if (lib == null) return -1;
  return lib.lookupFunction<_IntRetC, _IntRetDart>('wrnStop')();
}

/// Isolate entrypoint: opens its own handle to the native library, calls
/// `wrnTestNode`, frees the result. Must be a top-level function.
Map<String, dynamic>? _runTestNode(String payload) {
  final lib = _openLib();
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
