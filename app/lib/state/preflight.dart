import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/node.dart';
import 'providers.dart';

/// Result of an on-device reachability probe for one node.
enum ProbeVerdict {
  untested,
  testing,
  works, // at least one clean hit, fast
  slow, // clean hit but high latency
  blocked, // handshake worked, responses look like a stub / block page
  dead, // nothing got through
  error; // the throwaway engine never started

  String get label => switch (this) {
        ProbeVerdict.untested => 'не проверен',
        ProbeVerdict.testing => 'проверка…',
        ProbeVerdict.works => 'работает',
        ProbeVerdict.slow => 'медленный',
        ProbeVerdict.blocked => 'блокировка',
        ProbeVerdict.dead => 'не отвечает',
        ProbeVerdict.error => 'ошибка',
      };

  bool get isDone =>
      this != ProbeVerdict.untested && this != ProbeVerdict.testing;
}

@immutable
class ProbeHit {
  const ProbeHit({
    required this.url,
    required this.ok,
    required this.status,
    required this.latencyMs,
    required this.blocked,
    this.err,
  });

  final String url;
  final bool ok;
  final String status;
  final int latencyMs;
  final bool blocked;
  final String? err;

  factory ProbeHit.fromJson(Map<String, dynamic> j) => ProbeHit(
        url: '${j['url'] ?? ''}',
        ok: j['ok'] == true,
        status: '${j['status'] ?? ''}',
        latencyMs: (j['latency_ms'] as num?)?.toInt() ?? 0,
        blocked: j['blocked'] == true,
        err: (j['err'] as String?)?.isNotEmpty == true ? j['err'] as String : null,
      );
}

@immutable
class NodeProbe {
  const NodeProbe({
    required this.verdict,
    this.bestMs,
    this.hits = const [],
    this.error,
    this.at,
  });

  static const untested = NodeProbe(verdict: ProbeVerdict.untested);
  static const testing = NodeProbe(verdict: ProbeVerdict.testing);

  final ProbeVerdict verdict;
  final int? bestMs;
  final List<ProbeHit> hits;
  final String? error;
  final DateTime? at;

  /// Fast threshold: anything at or under this many ms counts as "works".
  static const _fastMs = 900;

  factory NodeProbe.fromSummary(Map<String, dynamic> s) {
    final err = s['err'] as String?;
    if (err != null && err.isNotEmpty) {
      return NodeProbe(
        verdict: ProbeVerdict.error,
        error: err,
        at: DateTime.now(),
      );
    }
    final ok = s['ok'] == true;
    final reachable = s['reachable'] == true;
    final best = (s['best_ms'] as num?)?.toInt();
    final hits = [
      for (final h in (s['hits'] as List<dynamic>? ?? const []))
        if (h is Map<String, dynamic>) ProbeHit.fromJson(h),
    ];
    final verdict = !reachable
        ? ProbeVerdict.dead
        : !ok
            ? ProbeVerdict.blocked
            : (best != null && best <= _fastMs)
                ? ProbeVerdict.works
                : ProbeVerdict.slow;
    return NodeProbe(
      verdict: verdict,
      bestMs: ok ? best : null,
      hits: hits,
      at: DateTime.now(),
    );
  }

  /// Rank key for sorting a list best-first (lower is better).
  int get rank => switch (verdict) {
        ProbeVerdict.works => bestMs ?? 500,
        ProbeVerdict.slow => 5000 + (bestMs ?? 0),
        ProbeVerdict.blocked => 100000,
        ProbeVerdict.dead => 200000,
        ProbeVerdict.error => 300000,
        ProbeVerdict.testing => 400000,
        ProbeVerdict.untested => 500000,
      };
}

class PreflightNotifier extends Notifier<Map<String, NodeProbe>> {
  @override
  Map<String, NodeProbe> build() => const {};

  NodeProbe of(String nodeId) => state[nodeId] ?? NodeProbe.untested;

  bool get anyTesting =>
      state.values.any((p) => p.verdict == ProbeVerdict.testing);

  Future<void> test(Node node) async {
    if (state[node.id]?.verdict == ProbeVerdict.testing) return;
    state = {...state, node.id: NodeProbe.testing};

    final core = ref.read(nativeCoreProvider);
    final targets = ref.read(settingsProvider).preflightEndpoints;
    Map<String, dynamic>? summary;
    try {
      summary = await core.testNode(node.outbound, targets: targets);
    } on Object catch (e) {
      summary = {'err': '$e'};
    }
    final result = summary == null
        ? const NodeProbe(verdict: ProbeVerdict.error, error: 'ядро недоступно')
        : NodeProbe.fromSummary(summary);
    state = {...state, node.id: result};
  }

  /// Test every node in [nodes], [concurrency] at a time.
  Future<void> testAll(List<Node> nodes, {int concurrency = 3}) async {
    final queue = [...nodes];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        await test(queue.removeAt(0));
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  }

  void clear() => state = const {};

  @visibleForTesting
  void debugPut(String nodeId, NodeProbe probe) =>
      state = {...state, nodeId: probe};
}

final preflightProvider =
    NotifierProvider<PreflightNotifier, Map<String, NodeProbe>>(
  PreflightNotifier.new,
);
