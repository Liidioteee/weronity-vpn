import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// ---- C signatures -------------------------------------------------------

typedef _VersionC = Pointer<Utf8> Function();
typedef _PingC = Int32 Function(Int32);
typedef _PingDart = int Function(int);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);
typedef _StartC = Int32 Function(Pointer<Utf8>);
typedef _StartDart = int Function(Pointer<Utf8>);
typedef _StopC = Int32 Function();
typedef _StopDart = int Function();
typedef _IsRunningC = Int32 Function();
typedef _IsRunningDart = int Function();
typedef _StatsC = Pointer<Utf8> Function();

/// How the native core resolved on this platform.
enum NativeCoreState { ok, unavailable, unsupported }

/// Thin `dart:ffi` wrapper around `weronity_core` (the Go/cgo shared library).
///
/// Phase 3.0: only [version]/[ping] are meaningful — they prove the library
/// loads and marshals across the FFI boundary. [start]/[stop]/[stats] talk to
/// the current stub engine and will keep the same signatures when sing-box
/// lands in Phase 3.1. If the library is missing (not built yet, or an
/// unsupported platform) this degrades to [NativeCoreState.unavailable] instead
/// of throwing, so the app still runs on the stub `ConnectionController`.
class NativeCore {
  NativeCore._(this._lib);

  final DynamicLibrary? _lib;
  NativeCoreState _state = NativeCoreState.unavailable;
  String? _loadError;

  NativeCoreState get state => _state;
  String? get loadError => _loadError;
  bool get isAvailable => _state == NativeCoreState.ok;

  static NativeCore? _instance;

  /// Loads the library once. Safe to call repeatedly.
  factory NativeCore.instance() => _instance ??= _load();

  static NativeCore _load() {
    final names = switch (_os()) {
      _Os.windows => ['weronity_core.dll'],
      _Os.linux => ['libweronity_core.so', 'weronity_core.so'],
      _Os.android => ['libweronity_core.so'],
      _Os.other => const <String>[],
    };
    if (names.isEmpty) {
      final c = NativeCore._(null)
        .._state = NativeCoreState.unsupported
        .._loadError = 'no native core for this platform yet';
      return c;
    }
    for (final name in names) {
      try {
        final lib = DynamicLibrary.open(name);
        final core = NativeCore._(lib).._state = NativeCoreState.ok;
        return core;
      } on Object catch (e) {
        _instanceLoadError = '$e';
      }
    }
    return NativeCore._(null)
      .._state = NativeCoreState.unavailable
      .._loadError = _instanceLoadError;
  }

  static String? _instanceLoadError;

  // ---- lazy-bound symbols --------------------------------------------

  late final _version =
      _lib?.lookupFunction<_VersionC, _VersionC>('wrnCoreVersion');
  late final _ping = _lib?.lookupFunction<_PingC, _PingDart>('wrnPing');
  late final _free = _lib?.lookupFunction<_FreeC, _FreeDart>('wrnFree');
  late final _start = _lib?.lookupFunction<_StartC, _StartDart>('wrnStart');
  late final _stop = _lib?.lookupFunction<_StopC, _StopDart>('wrnStop');
  late final _isRunning =
      _lib?.lookupFunction<_IsRunningC, _IsRunningDart>('wrnIsRunning');
  late final _stats = _lib?.lookupFunction<_StatsC, _StatsC>('wrnStatsJSON');

  /// Version string baked into the library, or `null` if unavailable.
  String? version() {
    final fn = _version;
    final free = _free;
    if (fn == null || free == null) return null;
    final ptr = fn();
    try {
      return ptr.toDartString();
    } finally {
      free(ptr);
    }
  }

  /// Round-trips an int through the library (`x` -> `x + 1`). Smoke test.
  int? ping(int x) => _ping?.call(x);

  int start(String configJson) {
    final fn = _start;
    if (fn == null) return -1;
    final p = configJson.toNativeUtf8();
    try {
      return fn(p);
    } finally {
      malloc.free(p);
    }
  }

  int stop() => _stop?.call() ?? -1;

  bool isRunning() => (_isRunning?.call() ?? 0) == 1;

  String? statsJson() {
    final fn = _stats;
    final free = _free;
    if (fn == null || free == null) return null;
    final ptr = fn();
    try {
      return ptr.toDartString();
    } finally {
      free(ptr);
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
