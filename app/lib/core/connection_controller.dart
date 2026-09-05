import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/node.dart';

enum ConnectionStatus {
  disconnected,
  connecting,
  protected,
  error;

  String get label => switch (this) {
        ConnectionStatus.disconnected => 'Отключено',
        ConnectionStatus.connecting => 'Подключение…',
        ConnectionStatus.protected => 'Защищено',
        ConnectionStatus.error => 'Ошибка',
      };
}

/// Live throughput + session totals. Bytes are cumulative for the session.
class TrafficSample {
  const TrafficSample({
    required this.upBps,
    required this.downBps,
    required this.upBytes,
    required this.downBytes,
    required this.elapsed,
  });

  final double upBps;
  final double downBps;
  final int upBytes;
  final int downBytes;
  final Duration elapsed;

  static const zero = TrafficSample(
    upBps: 0,
    downBps: 0,
    upBytes: 0,
    downBytes: 0,
    elapsed: Duration.zero,
  );
}

/// Auto-selects the lowest-latency node when the user picks "⚡ Авто".
class Selection {
  const Selection.auto()
      : isAuto = true,
        countryCode = null,
        node = null;
  const Selection.country(String this.countryCode)
      : isAuto = false,
        node = null;
  const Selection.node(Node this.node)
      : isAuto = false,
        countryCode = null;

  final bool isAuto;
  final String? countryCode;
  final Node? node;
}

/// **Stub** connection controller for Phase 2.
///
/// Drives the full UI state machine (disconnected → connecting → protected) and
/// emits synthetic traffic, but performs no real tunnelling. Phase 3 replaces the
/// body of [connect]/[disconnect] with the sing-box FFI bridge; the public
/// surface is intended to stay the same.
class ConnectionController extends ChangeNotifier {
  ConnectionController();

  ConnectionStatus _status = ConnectionStatus.disconnected;
  Selection _selection = const Selection.auto();
  Node? _activeNode;
  String? _lastError;
  TrafficSample _traffic = TrafficSample.zero;

  Timer? _tick;
  DateTime? _connectedAt;
  int _up = 0;
  int _down = 0;
  final _rng = Random();

  ConnectionStatus get status => _status;
  Selection get selection => _selection;
  Node? get activeNode => _activeNode;
  String? get lastError => _lastError;
  TrafficSample get traffic => _traffic;
  bool get isBusy => _status == ConnectionStatus.connecting;
  bool get isActive =>
      _status == ConnectionStatus.protected ||
      _status == ConnectionStatus.connecting;

  bool _switching = false;

  /// True while a live location switch is settling (session stays "protected").
  bool get isSwitching => _switching;

  /// Change the selected location.
  ///
  /// If a session is active, the active node is hot-swapped to one in the new
  /// location without dropping the connection (the stub for sing-box's
  /// urltest/selector switch — see docs/architecture.md). Returns `false` when
  /// the new location has no usable node; the current session is left intact.
  Future<bool> select(
    Selection selection,
    Node? Function(Selection) resolve,
  ) async {
    _selection = selection;
    notifyListeners();
    if (!isActive) return true;

    final next = resolve(selection);
    if (next == null) return false;
    if (next.id == _activeNode?.id) return true;

    _switching = true;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _activeNode = next;
    _switching = false;
    notifyListeners();
    return true;
  }

  /// [resolve] maps the current [Selection] to a concrete node (lowest ping for
  /// auto / a country). Provided by the caller so the controller stays UI-free.
  Future<void> connect(Node? Function(Selection) resolve) async {
    if (isActive) return;
    _lastError = null;
    _status = ConnectionStatus.connecting;
    notifyListeners();

    await Future<void>.delayed(const Duration(milliseconds: 900));
    final node = resolve(_selection);
    if (node == null) {
      _status = ConnectionStatus.error;
      _lastError = 'Нет доступных узлов для выбранной локации';
      notifyListeners();
      return;
    }

    _activeNode = node;
    _status = ConnectionStatus.protected;
    _connectedAt = DateTime.now();
    _up = 0;
    _down = 0;
    _startTicker();
    notifyListeners();
  }

  Future<void> disconnect() async {
    _tick?.cancel();
    _tick = null;
    _switching = false;
    if (_status == ConnectionStatus.disconnected) return;
    _status = ConnectionStatus.disconnected;
    _activeNode = null;
    _connectedAt = null;
    _traffic = TrafficSample.zero;
    notifyListeners();
  }

  Future<void> toggle(Node? Function(Selection) resolve) =>
      isActive ? disconnect() : connect(resolve);

  void _startTicker() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      // Synthetic traffic: idle-ish with occasional bursts.
      final burst = _rng.nextDouble() < 0.25;
      final down = (burst ? 400000 + _rng.nextInt(2500000) : 20000 + _rng.nextInt(180000));
      final up = (burst ? 60000 + _rng.nextInt(300000) : 8000 + _rng.nextInt(40000));
      _down += down;
      _up += up;
      _traffic = TrafficSample(
        upBps: up.toDouble(),
        downBps: down.toDouble(),
        upBytes: _up,
        downBytes: _down,
        elapsed: DateTime.now().difference(_connectedAt!),
      );
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }
}

/// Lowest-latency alive node, or null if none. Used by the "⚡ Авто" selection.
Node? pickLowestPing(Iterable<Node> nodes) {
  Node? best;
  for (final n in nodes) {
    if (!n.health.alive) continue;
    if (best == null ||
        (n.health.pingMs ?? 1 << 30) < (best.health.pingMs ?? 1 << 30)) {
      best = n;
    }
  }
  return best;
}
