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
/// traffic goes through the node; needs admin rights + `wintun.dll` on Windows.
///
/// Since 3.3b the engine is started with a *candidate set* — the chosen node
/// plus [backupsFor] backups — which the core wraps in a sing-box `selector`
/// group. Switching to a node that is already in that group is a hot-swap: no
/// restart, and in VPN mode no total network drop. Anything else still falls
/// back to stop/start.
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

  /// Whether the active/selected transport is the system-wide TUN.
  bool get isVpn => modeOf() == ConnectionMode.vpn;

  /// VPN mode is selected but the process is not elevated — the tun device
  /// cannot be created. UI offers a "restart as admin" path.
  bool get needsElevationForVpn =>
      isVpn && core.isAvailable && core.elevation() == 0;

  @override
  Future<void> connect(Node? Function(Selection) resolve) async {
    if (isActive) return;
    _lastError = null;

    if (needsElevationForVpn) {
      _status = ConnectionStatus.error;
      _lastError = 'Режим VPN требует прав администратора. Перезапустите '
          'приложение от имени администратора (Настройки → Подключение).';
      _log('warn', 'core', _lastError!);
      notifyListeners();
      return;
    }

    _status = ConnectionStatus.connecting;
    notifyListeners();

    final node = resolve(_selection);
    if (node == null) {
      _status = ConnectionStatus.error;
      _lastError = 'Нет доступных узлов для выбранной локации';
      notifyListeners();
      return;
    }

    final mode = modeOf();
    final rc = await _start(node, mode);

    if (rc != 0 || !core.isRunning()) {
      _status = ConnectionStatus.error;
      _lastError = _lastLogError() ??
          (mode == ConnectionMode.vpn
              ? 'Не удалось поднять VPN — запустите приложение от имени '
                  'администратора'
              : 'Ядро не запустилось (код $rc)');
      notifyListeners();
      return;
    }

    _activeNode = node;
    _status = ConnectionStatus.protected;
    _traffic = TrafficSample.zero;
    _history.clear();
    _startPoll();
    notifyListeners();
  }

  /// Boots the core for [primary] plus its backups and records the candidate
  /// set. Returns the core's return code.
  Future<int> _start(Node primary, ConnectionMode mode) async {
    _candidates = _candidateSet(primary);
    final rc = core.startNodes(
      [for (final n in _candidates) n.outbound],
      mode: mode.wire,
      listenPort: portOf(),
      selfTest: mode == ConnectionMode.proxy,
      strictRoute: strictRouteOf?.call() ?? false,
    );
    // Let the core surface any startup error into the event stream. The TUN
    // path (Wintun adapter + route table) can take a moment longer.
    await Future<void>.delayed(Duration(
      milliseconds: mode == ConnectionMode.vpn ? 400 : 150,
    ));
    _drainLogs();
    if (rc != 0) _candidates = const [];
    return rc;
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
    _poll?.cancel();
    _poll = null;
    _switching = false;
    _candidates = const [];
    if (core.isRunning()) core.stop();
    _drainLogs();
    if (_status == ConnectionStatus.disconnected) return;
    _status = ConnectionStatus.disconnected;
    _activeNode = null;
    _traffic = TrafficSample.zero;
    _history.clear();
    _listen = null;
    notifyListeners();
  }

  @override
  Future<bool> select(
    Selection selection,
    Node? Function(Selection) resolve,
  ) async {
    _selection = selection;
    notifyListeners();
    if (!isActive) return true;

    final next = resolve(selection);
    if (next == null) {
      _log('warn', 'route', 'в выбранной локации нет живых узлов');
      return false;
    }
    if (next.id == _activeNode?.id) return true;

    _switching = true;
    _log('info', 'route',
        'переключение на ${next.tag.isEmpty ? next.endpoint.host : next.tag}…');
    notifyListeners();

    // Already in the running selector group? Then this is a hot-swap: no
    // restart, and in VPN mode no drop of the whole machine's network.
    final idx = _candidates.indexWhere((n) => n.id == next.id);
    if (idx >= 0 && core.isRunning() && core.selectCandidate(idx)) {
      _drainLogs();
      _switching = false;
      _activeNode = next;
      _status = ConnectionStatus.protected;
      notifyListeners();
      return true;
    }

    // Otherwise fall back to stop/start — a real (brief) drop.
    if (core.isRunning()) core.stop();
    final mode = modeOf();
    final rc = await _start(next, mode);
    _switching = false;

    if (rc != 0 || !core.isRunning()) {
      _status = ConnectionStatus.error;
      _lastError = _lastLogError() ?? 'Не удалось переключить узел (код $rc)';
      _poll?.cancel();
      _poll = null;
      notifyListeners();
      return false;
    }
    _activeNode = next;
    _status = ConnectionStatus.protected;
    notifyListeners();
    return true;
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
    _drainLogs();
    final s = core.stats();
    if (s == null || s['running'] != true) {
      _poll?.cancel();
      _poll = null;
      _status = ConnectionStatus.error;
      _lastError = 'Ядро остановилось';
      notifyListeners();
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

  String? _pendingError;

  void _drainLogs() {
    for (final e in core.drainEvents()) {
      final level = '${e['level'] ?? 'info'}';
      final tag = '${e['tag'] ?? 'core'}';
      final msg = '${e['message'] ?? ''}';
      if (level == 'error') _pendingError = msg;
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
    _poll?.cancel();
    if (core.isRunning()) core.stop();
    super.dispose();
  }
}
