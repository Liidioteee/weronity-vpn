import 'dart:async';

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

  Map<String, dynamic> toJson() => {
        'url': url,
        'ok': ok,
        'status': status,
        'latency_ms': latencyMs,
        'blocked': blocked,
        if (err != null) 'err': err,
      };
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

  bool get isGood =>
      verdict == ProbeVerdict.works || verdict == ProbeVerdict.slow;

  /// A hit against [url] that succeeded, if the probe recorded one.
  ProbeHit? hitFor(String url) {
    for (final h in hits) {
      if (h.url == url) return h;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'v': verdict.name,
        if (bestMs != null) 'best': bestMs,
        if (error != null) 'err': error,
        if (at != null) 'at': at!.toIso8601String(),
        'hits': [for (final h in hits) h.toJson()],
      };

  factory NodeProbe.fromJson(Map<String, dynamic> j) {
    final v = ProbeVerdict.values.firstWhere(
      (e) => e.name == j['v'],
      orElse: () => ProbeVerdict.untested,
    );
    return NodeProbe(
      verdict: v == ProbeVerdict.testing ? ProbeVerdict.untested : v,
      bestMs: (j['best'] as num?)?.toInt(),
      error: j['err'] as String?,
      at: DateTime.tryParse(j['at']?.toString() ?? ''),
      hits: [
        for (final h in (j['hits'] as List<dynamic>? ?? const []))
          if (h is Map<String, dynamic>) ProbeHit.fromJson(h),
      ],
    );
  }
}

class PreflightNotifier extends Notifier<Map<String, NodeProbe>> {
  static const _boxKey = 'preflight.v1';
  Timer? _saveDebounce;

  @override
  Map<String, NodeProbe> build() {
    ref.onDispose(() => _saveDebounce?.cancel());
    Object? raw;
    try {
      raw = ref.read(sessionBoxProvider).get(_boxKey);
    } on UnimplementedError {
      return const {}; // no session box (e.g. a unit test) — start empty
    }
    if (raw is! Map) return const {};
    try {
      return {
        for (final e in raw.entries)
          if (e.value is Map)
            '${e.key}': NodeProbe.fromJson(
              Map<String, dynamic>.from(e.value as Map),
            ),
      };
    } on Object catch (e) {
      debugPrint('preflight cache load failed: $e');
      return const {};
    }
  }

  void _persist() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), () {
      try {
        ref.read(sessionBoxProvider).put(_boxKey, {
          for (final e in state.entries)
            if (e.value.verdict.isDone) e.key: e.value.toJson(),
        });
      } on Object catch (e) {
        debugPrint('preflight cache save failed: $e');
      }
    });
  }

  NodeProbe of(String nodeId) => state[nodeId] ?? NodeProbe.untested;

  bool get anyTesting =>
      state.values.any((p) => p.verdict == ProbeVerdict.testing);

  /// Node ids whose last result is older than [maxAge] (or never checked).
  Iterable<String> staleAmong(Iterable<String> ids, Duration maxAge) {
    final cutoff = DateTime.now().subtract(maxAge);
    return ids.where((id) {
      final p = state[id];
      if (p == null || !p.verdict.isDone) return true;
      final at = p.at;
      return at == null || at.isBefore(cutoff);
    });
  }

  Future<void> test(Node node) => testRaw(node.id, node.outbound);

  /// The core probe. [outbound] is the sanitised-on-the-Go-side node config.
  /// [timeoutMs] overrides the user's setting — used by the fast burst scan.
  Future<void> testRaw(
    String id,
    Map<String, dynamic> outbound, {
    int? timeoutMs,
  }) async {
    if (state[id]?.verdict == ProbeVerdict.testing) return;
    state = {...state, id: NodeProbe.testing};

    final core = ref.read(nativeCoreProvider);
    final s = ref.read(settingsProvider);
    Map<String, dynamic>? summary;
    try {
      summary = await core.testNode(
        outbound,
        targets: s.preflightEndpoints,
        timeoutMs: timeoutMs ?? s.checkTimeoutMs,
      );
    } on Object catch (e) {
      summary = {'err': '$e'};
    }
    final result = summary == null
        ? const NodeProbe(verdict: ProbeVerdict.error, error: 'ядро недоступно')
        : NodeProbe.fromSummary(summary);
    state = {...state, id: result};
    _persist();
  }

  /// Test every node in [nodes]; [concurrency] defaults to the user's setting.
  Future<void> testAll(List<Node> nodes, {int? concurrency}) async {
    final n = (concurrency ?? ref.read(settingsProvider).checkConcurrency)
        .clamp(1, 20);
    final queue = [...nodes];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        await test(queue.removeAt(0));
      }
    }

    await Future.wait([for (var i = 0; i < n; i++) worker()]);
  }

  /// Race through [candidateIds] with high concurrency and a short timeout;
  /// return the id of the **first** node that comes back good, or null if
  /// [deadline] passes first. Used to find a working node fast when everything
  /// blocked (most of the RU pool) means a serial scan would take forever.
  Future<String?> burstFindGood(
    List<String> candidateIds,
    Map<String, Map<String, dynamic>> outboundById, {
    int timeoutMs = 2500,
    Duration deadline = const Duration(seconds: 25),
  }) async {
    // An already-known fresh-good candidate wins immediately.
    for (final id in candidateIds) {
      final p = state[id];
      if (p != null &&
          p.isGood &&
          (p.at?.isAfter(DateTime.now().subtract(const Duration(minutes: 5))) ??
              false)) {
        return id;
      }
    }

    final n = ref.read(settingsProvider).checkConcurrency.clamp(1, 20);
    final started = DateTime.now();
    final queue = [...candidateIds];
    String? found;

    Future<void> worker() async {
      while (found == null &&
          queue.isNotEmpty &&
          DateTime.now().difference(started) < deadline) {
        final id = queue.removeAt(0);
        final ob = outboundById[id];
        if (ob == null) continue;
        await testRaw(id, ob, timeoutMs: timeoutMs);
        if (found == null && (state[id]?.isGood ?? false)) found = id;
      }
    }

    await Future.wait([for (var i = 0; i < n; i++) worker()]);
    return found;
  }

  void clear() {
    state = const {};
    _persist();
  }

  @visibleForTesting
  void debugPut(String nodeId, NodeProbe probe) =>
      state = {...state, nodeId: probe};
}

final preflightProvider =
    NotifierProvider<PreflightNotifier, Map<String, NodeProbe>>(
  PreflightNotifier.new,
);
