import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/node.dart';

/// Sink for core log lines — `(level, tag, message)`. Kept as a bare function so
/// the controller stays free of UI / Riverpod imports.
typedef ConnectionLog = void Function(String level, String tag, String message);

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

/// One point in the rolling network-activity history (fed to the Pro graphs).
class TrafficPoint {
  const TrafficPoint({
    required this.elapsed,
    required this.downBps,
    required this.upBps,
    required this.pingMs,
  });

  final Duration elapsed;
  final double downBps;
  final double upBps;
  final int pingMs;
}

/// The surface the UI drives, regardless of whether it is backed by the Phase-2
/// stub ([ConnectionController]) or the real sing-box engine ([SingBoxBridge]).
abstract class ConnectionEngine implements ChangeNotifier {
  ConnectionStatus get status;
  Selection get selection;
  Node? get activeNode;
  String? get lastError;
  TrafficSample get traffic;
  List<TrafficPoint> get history;
  bool get isBusy;
  bool get isActive;
  bool get isSwitching;

  Future<void> connect(Node? Function(Selection) resolve);
  Future<void> disconnect();
  Future<bool> select(Selection selection, Node? Function(Selection) resolve);
  Future<void> toggle(Node? Function(Selection) resolve);
}

/// Auto-selects the lowest-latency node when the user picks "⚡ Авто".
class Selection {
  const Selection.auto()
      : isAuto = true,
        countryCode = null,
        bundleId = null,
        node = null;
  const Selection.country(String this.countryCode)
      : isAuto = false,
        bundleId = null,
        node = null;
  const Selection.node(Node this.node)
      : isAuto = false,
        countryCode = null,
        bundleId = null;
  const Selection.bundle(String this.bundleId)
      : isAuto = false,
        countryCode = null,
        node = null;

  final bool isAuto;
  final String? countryCode;
  final String? bundleId;
  final Node? node;
}

/// **Stub** connection controller for Phase 2.
///
/// Drives the full UI state machine (disconnected → connecting → protected),
/// emits synthetic traffic + a synthetic core-log stream, but performs no real
/// tunnelling. Phase 3 replaces the body of [connect]/[disconnect]/[select] with
/// the sing-box FFI bridge; the public surface is intended to stay the same.
class ConnectionController extends ChangeNotifier implements ConnectionEngine {
  ConnectionController({this.onLog});

  /// Optional core-log sink; wired to the [LogController] in `providers.dart`.
  final ConnectionLog? onLog;

  /// Points kept for the Pro network graphs (~10 min at one sample/second).
  static const historyCapacity = 600;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  Selection _selection = const Selection.auto();
  Node? _activeNode;
  String? _lastError;
  TrafficSample _traffic = TrafficSample.zero;
  final Queue<TrafficPoint> _history = Queue<TrafficPoint>();

  Timer? _tick;
  int _tickCount = 0;
  DateTime? _connectedAt;
  int _up = 0;
  int _down = 0;
  final _rng = Random();

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

  bool _switching = false;

  /// True while a live location switch is settling (session stays "protected").
  @override
  bool get isSwitching => _switching;

  void _log(String level, String tag, String message) =>
      onLog?.call(level, tag, message);

  /// Change the selected location.
  ///
  /// If a session is active, the active node is hot-swapped to one in the new
  /// location without dropping the connection (the stub for sing-box's
  /// urltest/selector switch — see docs/architecture.md). Returns `false` when
  /// the new location has no usable node; the current session is left intact.
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
      _log('warn', 'route', 'в выбранной локации нет живых узлов — не переключаюсь');
      return false;
    }
    if (next.id == _activeNode?.id) return true;

    _switching = true;
    _log('info', 'route', 'переключение на ${_name(next)}…');
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _activeNode = next;
    _switching = false;
    _log('info', 'route', 'переключение завершено: ${_name(next)}');
    notifyListeners();
    return true;
  }

  /// [resolve] maps the current [Selection] to a concrete node (lowest ping for
  /// auto / a country). Provided by the caller so the controller stays UI-free.
  @override
  Future<void> connect(Node? Function(Selection) resolve) async {
    if (isActive) return;
    _lastError = null;
    _status = ConnectionStatus.connecting;
    _log('info', 'core', 'запуск туннеля (заглушка Фазы 2)…');
    notifyListeners();

    await Future<void>.delayed(const Duration(milliseconds: 900));
    final node = resolve(_selection);
    if (node == null) {
      _status = ConnectionStatus.error;
      _lastError = 'Нет доступных узлов для выбранной локации';
      _log('error', 'core', _lastError!);
      notifyListeners();
      return;
    }

    _activeNode = node;
    _status = ConnectionStatus.protected;
    _connectedAt = DateTime.now();
    _up = 0;
    _down = 0;
    _tickCount = 0;
    _history.clear();
    _log('info', 'core', 'соединение установлено: ${_name(node)}');
    _log('debug', 'tls', 'рукопожатие ok · sni=${node.classification.sni ?? '—'}');
    _startTicker();
    notifyListeners();
  }

  @override
  Future<void> disconnect() async {
    _tick?.cancel();
    _tick = null;
    _switching = false;
    if (_status == ConnectionStatus.disconnected) return;
    _status = ConnectionStatus.disconnected;
    _activeNode = null;
    _connectedAt = null;
    _traffic = TrafficSample.zero;
    _history.clear();
    _log('info', 'core', 'туннель закрыт');
    notifyListeners();
  }

  @override
  Future<void> toggle(Node? Function(Selection) resolve) =>
      isActive ? disconnect() : connect(resolve);

  void _startTicker() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _emitSample());
  }

  /// Runs one synthetic-traffic step. Exposed for tests so they need not wait a
  /// real second for the periodic timer.
  @visibleForTesting
  void debugTick() => _emitSample();

  void _emitSample() {
    _connectedAt ??= DateTime.now();
    _tickCount++;

    // Synthetic traffic: idle-ish with occasional bursts.
    final burst = _rng.nextDouble() < 0.25;
    final down =
        burst ? 400000 + _rng.nextInt(2500000) : 20000 + _rng.nextInt(180000);
    final up = burst ? 60000 + _rng.nextInt(300000) : 8000 + _rng.nextInt(40000);
    _down += down;
    _up += up;
    final elapsed = DateTime.now().difference(_connectedAt!);
    _traffic = TrafficSample(
      upBps: up.toDouble(),
      downBps: down.toDouble(),
      upBytes: _up,
      downBytes: _down,
      elapsed: elapsed,
    );

    final basePing = _activeNode?.health.pingMs ?? 60;
    final pingMs = max(1, basePing + _rng.nextInt(31) - 15);
    _history.addLast(
      TrafficPoint(
        elapsed: elapsed,
        downBps: down.toDouble(),
        upBps: up.toDouble(),
        pingMs: pingMs,
      ),
    );
    while (_history.length > historyCapacity) {
      _history.removeFirst();
    }

    if (_tickCount % 30 == 0) {
      _log('debug', 'core', 'keepalive ok · rtt ${pingMs}ms');
    } else if (_tickCount % 12 == 0) {
      _log(
        'debug',
        'net',
        'rx ${_kb(_down)} · tx ${_kb(_up)}',
      );
    }

    notifyListeners();
  }

  static String _kb(int bytes) => '${(bytes / 1024).toStringAsFixed(0)} КБ';

  String _name(Node n) {
    final where = n.geo.countryName ?? n.countryCode;
    final label = n.tag.isEmpty ? n.endpoint.host : n.tag;
    return '$label · $where';
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
