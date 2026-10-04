import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../data/settings_repository.dart';
import '../domain/node.dart';
import 'connection_controller.dart';
import 'native/native_core.dart';

/// Real [ConnectionEngine] backed by the sing-box FFI core.
///
/// Proxy mode: a local SOCKS/HTTP proxy on `127.0.0.1:<port>`.
/// VPN mode (Phase 3.3): a `tun` device with `auto_route` — the whole system's
/// traffic goes through the node; needs admin rights on Windows.
///
/// Since 3.3b the engine is started with a *candidate set* — the chosen node
/// plus [backupsFor] backups — which the core wraps in a sing-box `selector`
/// group. Switching to a node that is already in that group is a hot-swap: no
/// restart, and in VPN mode no total network drop. Anything else still falls
/// back to stop/start.
///
/// Starting and stopping the engine happens on a helper isolate
/// ([NativeCore.startNodesAsync] / [NativeCore.stopAsync]): bringing a TUN
/// adapter up or down can take seconds and must not freeze the window. One
/// such operation runs at a time ([_busy]); [_epoch] lets a `disconnect()`
/// that arrives mid-start win over the start it interrupted.
class SingBoxBridge extends ChangeNotifier implements ConnectionEngine {
  SingBoxBridge({
    required this.core,
    required this.modeOf,
    required this.portOf,
    this.strictRouteOf,
    this.backupsFor,
    this.onLog,
  });

  final NativeCore core;
  final ConnectionMode Function() modeOf;
  final int Function() portOf;

  /// VPN mode only — sing-box `strict_route` on the tun inbound.
  final bool Function()? strictRouteOf;

  /// Backup nodes to preload alongside the chosen one, best first. They cost
  /// nothing until used (sing-box builds the outbound but does not dial it),
  /// and they are what makes a later switch seamless.
  final List<Node> Function(Node primary)? backupsFor;

  final void Function(String level, String tag, String message)? onLog;

  static const _historyCap = 600;

  /// How many nodes go into the selector group. The core caps this at 32 too.
  static const maxCandidates = 16;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  Selection _selection = const Selection.auto();
  Node? _activeNode;
  String? _lastError;
  TrafficSample _traffic = TrafficSample.zero;
  final Queue<TrafficPoint> _history = Queue<TrafficPoint>();
  bool _switching = false;
  Timer? _poll;
  String? _listen;

  /// A start / restart of the engine is in flight.
  bool _busy = false;

  /// Bumped by every [disconnect]; an operation that finds it changed after an
  /// `await` knows the user cancelled it.
  int _epoch = 0;

  /// The engine stop still running in the background, if any — a new connect
  /// waits for it rather than racing it.
  Future<void>? _stopping;

  /// The mode the *running* session was started in. The setting can change
  /// while connected; the session does not change with it.
  ConnectionMode? _activeMode;

  /// The candidate set the running engine was started with, in the order the
  /// core received it — the index into this list is what [NativeCore
  /// .selectCandidate] takes.
  List<Node> _candidates = const [];

  @override
  ConnectionStatus get status => _status;
  @override
  Selection get selection => _selection;
  @override
  Node? get activeNode => _activeNode;
  @override
  String? get lastError => _lastError;
  @override
  TrafficSample get traffic => _traffic;
  @override
  List<TrafficPoint> get history => List<TrafficPoint>.unmodifiable(_history);
  @override
  bool get isBusy => _status == ConnectionStatus.connecting;
  @override
  bool get isActive =>
      _status == ConnectionStatus.protected ||
      _status == ConnectionStatus.connecting;
  @override
  bool get isSwitching => _switching;

  void _log(String level, String tag, String message) =>
      onLog?.call(level, tag, message);

  /// The proxy address the user can point apps at, once connected (cached from
  /// the poll — cheap to read every build).
  String? get proxyEndpoint => isActive ? _listen : null;

  /// Whether the transport is the system-wide TUN: the running session's mode
  /// while connected, otherwise the mode the next connect will use.
  bool get isVpn => (_activeMode ?? modeOf()) == ConnectionMode.vpn;

  /// VPN mode is selected but the process is not elevated — the tun device
  /// cannot be created. UI offers a "restart as admin" path.
  bool get needsElevationForVpn =>
      modeOf() == ConnectionMode.vpn &&
      core.isAvailable &&
      core.elevation() == 0;

  @override
  Future<void> connect(Node? Function(Selection) resolve) async {
    if (isActive || _busy) return;
    _lastError = null;

    if (needsElevationForVpn) {
      _status = ConnectionStatus.error;
      _lastError = 'Режим VPN требует прав администратора. Перезапустите '
          'приложение от имени администратора (Настройки → Подключение).';
      _log('warn', 'core', _lastError!);
      notifyListeners();
      return;
    }

    final node = resolve(_selection);
    if (node == null) {
      _status = ConnectionStatus.error;
      _lastError = 'Нет доступных узлов для выбранной локации';
      notifyListeners();
      return;
    }

    _busy = true;
    final epoch = _epoch;
    _status = ConnectionStatus.connecting;
    notifyListeners();
    try {
      await _stopping; // a previous session may still be tearing down
      // Never start on top of a leftover engine: the core treats a second
      // start as a no-op and we would report the wrong node as connected.
      if (core.isRunning()) await core.stopAsync();
      final mode = modeOf();
      final rc = await _start(node, mode, epoch);
      if (epoch != _epoch) {
        // disconnect() arrived meanwhile and won. Its stop may have run before
        // our start did — make sure no engine is left behind a "disconnected" UI.
        await _stopOrphan(rc);
        return;
      }

      if (rc != 0 || !core.isRunning()) {
        _fail(_lastLogError() ??
            (mode == ConnectionMode.vpn
                ? 'Не удалось поднять VPN — запустите приложение от имени '
                    'администратора'
                : 'Ядро не запустилось (код $rc)'));
        return;
      }

      _activeNode = node;
      _status = ConnectionStatus.protected;
      _traffic = TrafficSample.zero;
      _history.clear();
      _startPoll();
      notifyListeners();
    } on Object catch (e) {
      if (epoch == _epoch) _fail('Не удалось подключиться: $e');
    } finally {
      _busy = false;
    }
  }

  void _fail(String message) {
    _poll?.cancel();
    _poll = null;
    _status = ConnectionStatus.error;
    _lastError = message;
    _activeMode = null;
    _switching = false;
    notifyListeners();
  }

  /// Boots the core for [primary] plus its backups and records the candidate
  /// set. Returns the core's return code. The call returns only once the
  /// engine is up (or has failed), with its startup messages already queued.
  Future<int> _start(Node primary, ConnectionMode mode, int epoch) async {
    _pendingError = null;
    final candidates = _candidateSet(primary);
    final rc = await core.startNodesAsync(
      [for (final n in candidates) n.outbound],
      mode: mode.wire,
      listenPort: portOf(),
      selfTest: mode == ConnectionMode.proxy,
      strictRoute: strictRouteOf?.call() ?? false,
    );
    _drainLogs();
    // Record the session only if it is still wanted (no disconnect meanwhile).
    if (rc == 0 && epoch == _epoch) {
      _candidates = candidates;
      _activeMode = mode;
    } else {
      _candidates = const [];
    }
    return rc;
  }

  /// Stops an engine that came up after the user had already cancelled the
  /// operation that started it.
  Future<void> _stopOrphan(int rc) async {
    if (rc == 0 && core.isRunning()) await core.stopAsync();
    _drainLogs();
  }

  /// [primary] first, then its backups, deduplicated and capped.
  List<Node> _candidateSet(Node primary) {
    final out = <Node>[primary];
    final seen = <String>{primary.id};
    for (final n in backupsFor?.call(primary) ?? const <Node>[]) {
      if (out.length >= maxCandidates) break;
      if (seen.add(n.id)) out.add(n);
    }
    return out;
  }

  @override
  Future<void> disconnect() async {
    _epoch++;
    _poll?.cancel();
    _poll = null;
    _switching = false;
    _candidates = const [];
    final hadSession = _status != ConnectionStatus.disconnected;
    _status = ConnectionStatus.disconnected;
    _activeNode = null;
    _activeMode = null;
    _traffic = TrafficSample.zero;
    _history.clear();
    _listen = null;
    if (hadSession) notifyListeners();

    // The UI is already "disconnected"; the engine follows off-thread. If a
    // start is still in flight the core queues this stop right behind it.
    if (core.isRunning() || _busy) {
      final stop = core.stopAsync().then((_) {}, onError: (_) {});
      _stopping = stop;
      await stop;
      if (identical(_stopping, stop)) _stopping = null;
    }
    _drainLogs();
  }

  @override
  Future<bool> select(
    Selection selection,
    Node? Function(Selection) resolve,
  ) async {
    _selection = selection;
    notifyListeners();
    // Idle, or still connecting: just remember the choice.
    if (_status != ConnectionStatus.protected) return true;

    final next = resolve(selection);
    if (next == null) {
      _log('warn', 'route', 'в выбранной локации нет живых узлов');
      return false;
    }
    return _switchTo(next);
  }

  @override
  Future<bool> switchTo(Node node) async {
    if (_status != ConnectionStatus.protected) return false;
    return _switchTo(node);
  }

  /// Moves the live session to [next]: a hot-swap inside the running selector
  /// group when possible, otherwise stop/start.
  Future<bool> _switchTo(Node next) async {
    if (next.id == _activeNode?.id) return true;
    if (_busy) return false; // one engine operation at a time

    _busy = true;
    final epoch = _epoch;
    _switching = true;
    _log('info', 'route',
        'переключение на ${next.tag.isEmpty ? next.endpoint.host : next.tag}…');
    notifyListeners();
    try {
      // Already in the running selector group? Then this is a hot-swap: no
      // restart, and in VPN mode no drop of the whole machine's network.
      final idx = _candidates.indexWhere((n) => n.id == next.id);
      if (idx >= 0 && core.isRunning() && core.selectCandidate(idx)) {
        _drainLogs();
        _switching = false;
        _activeNode = next;
        notifyListeners();
        return true;
      }

      // Otherwise fall back to stop/start — a real (brief) drop. The mode is
      // the session's own, not whatever the setting says right now.
      final mode = _activeMode ?? modeOf();
      await core.stopAsync();
      if (epoch != _epoch) return false;
      final rc = await _start(next, mode, epoch);
      if (epoch != _epoch) {
        await _stopOrphan(rc);
        return false;
      }

      if (rc != 0 || !core.isRunning()) {
        _fail(_lastLogError() ?? 'Не удалось переключить узел (код $rc)');
        return false;
      }
      _switching = false;
      _activeNode = next;
      _status = ConnectionStatus.protected;
      notifyListeners();
      return true;
    } on Object catch (e) {
      if (epoch == _epoch) _fail('Не удалось переключить узел: $e');
      return false;
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> toggle(Node? Function(Selection) resolve) =>
      isActive ? disconnect() : connect(resolve);

  // ---- polling ------------------------------------------------------

  void _startPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _tick();
  }

  void _tick() {
    // A restart is in flight: "not running" right now is expected, not a crash.
    if (_busy) return;
    _drainLogs();
    final s = core.stats();
    if (s == null || s['running'] != true) {
      _fail('Ядро остановилось');
      return;
    }

    num n(Object? v) => v is num ? v : 0;
    if (s['listen'] is String) _listen = s['listen'] as String;
    final elapsed = Duration(milliseconds: n(s['uptime_ms']).toInt());
    _traffic = TrafficSample(
      upBps: n(s['up_bps']).toDouble(),
      downBps: n(s['down_bps']).toDouble(),
      upBytes: n(s['up_bytes']).toInt(),
      downBytes: n(s['down_bytes']).toInt(),
      elapsed: elapsed,
    );
    _history.addLast(
      TrafficPoint(
        elapsed: elapsed,
        downBps: _traffic.downBps,
        upBps: _traffic.upBps,
        pingMs: n(s['ping_ms']).toInt().clamp(0, 1 << 20),
      ),
    );
    while (_history.length > _historyCap) {
      _history.removeFirst();
    }
    notifyListeners();
  }

  // ---- log plumbing ----------------------------------------------

  /// The core's own explanation of the start that is in flight. Only `core`
  /// messages count: sing-box logs an `error` line for every connection that
  /// fails at runtime, and one of those must not be shown later as the reason
  /// a completely different operation failed.
  String? _pendingError;

  void _drainLogs() {
    for (final e in core.drainEvents()) {
      final level = '${e['level'] ?? 'info'}';
      final tag = '${e['tag'] ?? 'core'}';
      final msg = '${e['message'] ?? ''}';
      if (level == 'error' && tag == 'core') _pendingError = msg;
      _log(level, tag, msg);
    }
  }

  String? _lastLogError() {
    final e = _pendingError;
    _pendingError = null;
    return e;
  }

  @override
  void dispose() {
    _epoch++;
    _poll?.cancel();
    if (core.isRunning()) core.stop();
    super.dispose();
  }
}
