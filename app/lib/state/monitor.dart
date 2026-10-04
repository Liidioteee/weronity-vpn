import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/connection_controller.dart';
import '../core/singbox_bridge.dart';
import '../data/custom_keys_repository.dart';
import '../domain/node.dart';
import 'bundles.dart';
import 'candidates.dart';
import 'preflight.dart';
import 'providers.dart';

/// Always-on background watchdog (while `Settings.autoCheck` is on).
///
/// **Connected:** every ~20 s it makes a real request through the live tunnel.
/// One miss → one quick retry. Still no answer → failover: a *fast burst scan*
/// (high concurrency, short timeout) over the nodes the user's choice allows,
/// and a hot-swap to the first one that answers.
///
/// Failover never leaves the user's choice ([failoverScope]) and never switches
/// blind: if no candidate proves it works, the session stays where it is, the
/// home screen says so ([connectionNoticeProvider]) and the next attempt backs
/// off. That also covers "the internet itself is down" — then nothing answers,
/// so nothing is switched.
///
/// **Idle:** keeps the handful of nodes the next connect would use vetted
/// ([idleCheckScope]) — a few per tick. It deliberately does not walk the whole
/// pool: that is hundreds of connections to proxy servers from the user's own
/// address for nodes they will never use. The full sweep is the manual
/// "Проверить видимые".
final monitorProvider = Provider<void>((ref) {
  final enabled = ref.watch(settingsProvider.select((s) => s.autoCheck));
  if (!enabled) return;
  if (!ref.watch(nativeCoreProvider).isAvailable) return;

  var rr = 0;
  var busy = false;
  String? lastActiveId;
  DateTime? lastLivenessAt;
  // Failover attempts that found nothing, and when the next one may run.
  var misses = 0;
  DateTime? retryFailoverAt;

  void setNotice(String? text) {
    final notice = ref.read(connectionNoticeProvider.notifier);
    if (notice.state != text) notice.state = text;
  }

  Future<void> tick() async {
    if (busy) return;
    busy = true;
    try {
      final pf = ref.read(preflightProvider.notifier);
      final nodes = ref.read(nodesProvider);
      if (nodes.isEmpty) return;
      final controller = ref.read(connectionControllerProvider);

      // --- 1. the live connection ------------------------------------
      final active = controller.activeNode;
      if (controller.status == ConnectionStatus.protected && active != null) {
        final now = DateTime.now();
        final justConnected = active.id != lastActiveId;
        lastActiveId = active.id;
        if (justConnected) {
          misses = 0;
          retryFailoverAt = null;
        }

        final due = justConnected ||
            lastLivenessAt == null ||
            now.difference(lastLivenessAt!) >= livenessInterval;
        final retryDue =
            retryFailoverAt != null && !now.isBefore(retryFailoverAt!);
        if (!due && !retryDue) return;

        // A liveness ping is short — cap the check at ~5 s regardless of the
        // (probe-oriented) checkTimeoutMs setting.
        final pingTimeout = Duration(
          milliseconds:
              ref.read(settingsProvider).checkTimeoutMs.clamp(2000, 6000),
        );
        var ok = await _tunnelAlive(controller, pingTimeout);
        if (!ok && !justConnected) {
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          ok = await _tunnelAlive(controller, pingTimeout);
        }
        lastLivenessAt = DateTime.now();
        if (ok) {
          misses = 0;
          retryFailoverAt = null;
          setNotice(null);
          return;
        }

        final switched = await _failover(ref, active, setNotice);
        if (switched) {
          misses = 0;
          retryFailoverAt = null;
          lastLivenessAt = null; // verify the new node on the next tick
        } else {
          misses++;
          retryFailoverAt = DateTime.now().add(failoverBackoff(misses));
        }
        return; // one action per tick
      }
      lastActiveId = null;
      lastLivenessAt = null;
      misses = 0;
      retryFailoverAt = null;
      setNotice(null);

      if (controller.isActive) return; // connecting — stay out of the way
      if (pf.anyTesting) return; // a manual sweep is running — don't pile on

      // --- 2. keep the next connect's candidates vetted -----------------
      final scope = idleCheckScope(
        controller.selection,
        nodes,
        ref.read(allBundlesProvider),
        ref.read(resolveSelectionProvider),
        lastGoodNodeId: ref.read(settingsProvider).lastGoodNodeId,
      );
      final stale = pf
          .staleAmong([for (final n in scope) n.id], const Duration(minutes: 8))
          .toList();
      if (stale.isEmpty) return;
      final byId = {for (final n in scope) n.id: n};
      final batch = <Node>{
        for (var i = 0; i < 2 && i < stale.length; i++)
          if (byId[stale[(rr++) % stale.length]] case final Node n) n,
      }.toList();
      await pf.testAll(batch, concurrency: 2);
    } on Object catch (e) {
      debugPrint('monitor tick failed: $e');
    } finally {
      busy = false;
    }
  }

  final periodic = Timer.periodic(const Duration(seconds: 7), (_) => tick());
  final kick = Timer(const Duration(seconds: 3), tick);
  ref.onDispose(() {
    periodic.cancel();
    kick.cancel();
  });
});

/// How often a healthy tunnel is re-checked. A miss is retried within seconds;
/// this only paces the "everything is fine" case.
const livenessInterval = Duration(seconds: 20);

/// How long to wait before looking for a replacement again after [misses]
/// searches in a row found nothing: 15 s, 30 s, 60 s, then every 2 min.
Duration failoverBackoff(int misses) {
  const steps = [15, 30, 60, 120];
  return Duration(seconds: steps[(misses - 1).clamp(0, steps.length - 1)]);
}

/// Shown on the home screen while the session is up but its node does not
/// answer and no replacement was found. `null` = nothing to report.
final connectionNoticeProvider = StateProvider<String?>((ref) => null);

/// A real request through the current tunnel (HTTP-CONNECT via the local mixed
/// inbound in proxy mode; direct in VPN mode — everything is tunnelled anyway).
Future<bool> _tunnelAlive(ConnectionEngine controller, Duration timeout) async {
  final client = HttpClient()..connectionTimeout = timeout;
  if (controller is SingBoxBridge && !controller.isVpn) {
    final ep = controller.proxyEndpoint; // "127.0.0.1:<port>"
    if (ep == null) {
      client.close(force: true);
      return false;
    }
    client.findProxy = (_) => 'PROXY $ep';
  }
  try {
    final req = await client
        .getUrl(Uri.parse('https://www.gstatic.com/generate_204'))
        .timeout(timeout);
    final resp = await req.close().timeout(timeout);
    await resp.drain<void>();
    return resp.statusCode >= 200 && resp.statusCode < 400;
  } on Object {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// The nodes a session may move to without betraying what the user picked,
/// best first, [dead] excluded:
///
/// * "⚡ Авто" — anything alive (same country → recommended → the rest);
/// * a country — that country only;
/// * a bundle — the bundle's live members;
/// * one explicit node — its own country.
List<Node> failoverScope(
  Selection selection,
  Node dead,
  List<Node> nodes,
  List<KeyBundle> bundles,
) {
  if (selection.bundleId != null) {
    for (final b in bundles) {
      if (b.id == selection.bundleId) {
        return [
          for (final n in bundleLiveNodes(b, nodes))
            if (n.id != dead.id) n,
        ];
      }
    }
    return const [];
  }
  final ranked = backupCandidates(dead, nodes, limit: nodes.length);
  final country = selection.countryCode ?? selection.node?.countryCode;
  if (country == null) return ranked; // auto
  return [
    for (final n in ranked)
      if (n.countryCode == country) n,
  ];
}

/// Tries to move the session off [dead]. Returns `true` only when it switched
/// to a node that had just proved it works.
Future<bool> _failover(
  Ref ref,
  Node dead,
  void Function(String?) setNotice,
) async {
  final settings = ref.read(settingsProvider);
  final controller = ref.read(connectionControllerProvider);
  final log = ref.read(logControllerProvider);

  // Whatever an earlier probe said, this node has just failed in real use.
  ref.read(preflightProvider.notifier).markDead(dead.id);

  if (!settings.autoSwitch) {
    log.add('warn', 'monitor',
        'узел ${_name(dead)} не отвечает — автопереключение выключено');
    setNotice('Узел не отвечает. Автопереключение выключено — выберите '
        'другой узел или включите его в настройках.');
    return false;
  }

  final scope = failoverScope(
    controller.selection,
    dead,
    ref.read(nodesProvider),
    ref.read(allBundlesProvider),
  );
  final byId = {for (final n in scope) n.id: n};
  // Keep the scan bounded; the list is already best-first.
  final ids = [for (final n in scope.take(_failoverScanWidth)) n.id];

  // 1. an already-known, recently verified backup?
  final probes = ref.read(preflightProvider);
  Node? pick = _firstGood(ids, byId, probes, freshOnly: true);

  // 2. otherwise race the candidates and take the first that answers.
  if (pick == null && ids.isNotEmpty) {
    log.add('warn', 'monitor', 'узел ${_name(dead)} не отвечает — ищу рабочий…');
    final foundId = await ref.read(preflightProvider.notifier).burstFindGood(
          ids,
          {for (final id in ids) id: byId[id]!.outbound},
          timeoutMs: (settings.checkTimeoutMs * 0.6).round().clamp(1500, 4000),
        );
    pick = foundId == null ? null : byId[foundId];
  }

  // 3. nothing proved it works → stay put. A blind switch would just trade one
  //    dead node for another (or, when the internet itself is down, churn
  //    through the pool for nothing).
  if (pick == null) {
    final where = _scopeLabel(controller.selection);
    log.add('error', 'monitor',
        'узел ${_name(dead)} не отвечает — рабочей замены $where не нашлось');
    setNotice('Узел не отвечает, рабочей замены $where не нашлось. '
        'Проверьте интернет или выберите другую локацию.');
    return false;
  }

  // The session may have ended, or the user may have switched, while we looked.
  if (controller.status != ConnectionStatus.protected ||
      controller.activeNode?.id != dead.id) {
    return false;
  }
  log.add('warn', 'monitor',
      'узел ${_name(dead)} не отвечает — переключаюсь на ${_name(pick)}');
  final ok = await controller.switchTo(pick);
  if (ok) setNotice(null);
  return ok;
}

const _failoverScanWidth = 48;

String _scopeLabel(Selection s) {
  if (s.bundleId != null) return 'в подборке';
  if (s.countryCode != null || s.node != null) return 'в этой стране';
  return 'в пуле';
}

/// The best (lowest latency) node among [ids] with a good probe. With
/// [freshOnly] the probe must also be recent enough to act on.
Node? _firstGood(
  List<String> ids,
  Map<String, Node> byId,
  Map<String, NodeProbe> probes, {
  bool freshOnly = false,
}) {
  String? best;
  var bestMs = 1 << 30;
  for (final id in ids) {
    final p = probes[id];
    if (p == null || !p.isGood) continue;
    if (freshOnly && !_isFresh(p)) continue;
    final ms = p.bestMs ?? 900;
    if (ms < bestMs) {
      bestMs = ms;
      best = id;
    }
  }
  return best == null ? null : byId[best];
}

String _name(Node n) => n.tag.isEmpty ? n.endpoint.host : n.tag;

// ---------------------------------------------------------------------------
//  Choosing the node a connect should use
// ---------------------------------------------------------------------------

/// What the app is doing between the user pressing the power button and the
/// engine actually starting, or `null` when nothing is in flight. The home
/// screen shows it — a burst scan can take a few seconds, and a power button
/// that just sits there reads as broken.
final connectPhaseProvider = StateProvider<String?>((ref) => null);

/// The candidates a connect for [selection] may use, best first — also the set
/// the idle monitor keeps vetted. Empty for an explicit node (nothing to pick).
List<Node> connectCandidates(
  Selection selection,
  List<Node> nodes,
  List<KeyBundle> bundles,
  Node? Function(Selection) resolve,
) {
  if (selection.node != null) return const [];
  if (selection.bundleId != null) {
    for (final b in bundles) {
      if (b.id == selection.bundleId) {
        return bundleLiveNodes(b, nodes).take(_scanWidth).toList();
      }
    }
    return const [];
  }
  final first = resolve(selection);
  if (first == null) return const [];
  final backups = backupCandidates(first, nodes, limit: nodes.length);
  final country = selection.countryCode;
  return [
    first,
    ...backups.where((n) => country == null || n.countryCode == country),
  ].take(_scanWidth).toList();
}

/// What the idle monitor re-checks: the candidates of the next connect, the
/// explicitly chosen node if any, and the node that worked last time.
List<Node> idleCheckScope(
  Selection selection,
  List<Node> nodes,
  List<KeyBundle> bundles,
  Node? Function(Selection) resolve, {
  String? lastGoodNodeId,
}) {
  final out = <String, Node>{};
  if (selection.node case final Node n) out[n.id] = n;
  for (final n in connectCandidates(selection, nodes, bundles, resolve)) {
    out[n.id] = n;
  }
  if (lastGoodNodeId != null) {
    for (final n in nodes) {
      if (n.id == lastGoodNodeId && n.health.alive) out[n.id] = n;
    }
  }
  return out.values.toList();
}

/// Chooses the node a connect for the given selection should actually use, or
/// `null` to leave it to the plain ranking (an explicit node, an empty pool).
///
/// `resolveSelectionProvider` ranks by the *collector's* ping, which says the
/// node was reachable from a GitHub runner — not that it works from here. Most
/// of the pool is blocked for a Russian user, so connecting to the
/// lowest-ping node routinely lands on a dead one and the monitor has to fail
/// over a few seconds later. This does that search up front instead:
///
/// 1. with "Возвращаться на прошлый узел" on, the node that worked last time
///    goes first — if it still answers, it is used (the visible IP stays put);
/// 2. a fresh good probe wins outright, no scan;
/// 3. otherwise a short burst scan races the candidates and takes the first
///    node that answers.
///
/// Falls back to the plain ranking when checking is switched off, when nothing
/// answers, or when the deadline passes — a connect attempt on a doubtful node
/// beats refusing to connect at all.
final connectPickProvider =
    Provider<Future<Node?> Function(Selection)>((ref) {
  return (selection) async {
    final resolve = ref.read(resolveSelectionProvider);
    final nodes = ref.read(nodesProvider);
    final candidates = connectCandidates(
      selection,
      nodes,
      ref.read(allBundlesProvider),
      resolve,
    );
    if (candidates.isEmpty) return null;
    final fallback = candidates.first;

    final settings = ref.read(settingsProvider);
    final byId = {for (final n in candidates) n.id: n};
    final last = settings.autoConnectLastNode
        ? lastGoodNodeFor(selection, settings.lastGoodNodeId, nodes)
        : null;
    if (last != null) byId[last.id] = last;
    final ordered = <String>[
      if (last != null) last.id,
      for (final n in candidates)
        if (n.id != last?.id) n.id,
    ];

    // A recent good result means we already know this one works — no scan
    // needed, and this holds even when scanning is unavailable below.
    final probes = ref.read(preflightProvider);
    if (last != null && (probes[last.id]?.isGood ?? false) &&
        _isFresh(probes[last.id])) {
      return last;
    }
    final known = _firstGood(ordered, byId, probes, freshOnly: true);
    if (known != null) return known;

    final canScan =
        settings.autoCheck && ref.read(nativeCoreProvider).isAvailable;
    if (!canScan) return last ?? fallback;

    final log = ref.read(logControllerProvider);
    final phase = ref.read(connectPhaseProvider.notifier);
    final pf = ref.read(preflightProvider.notifier);
    final timeoutMs =
        (settings.checkTimeoutMs * 0.6).round().clamp(1500, 4000);
    phase.state = 'Ищу рабочий узел…';
    log.add('info', 'route', 'проверяю узлы перед подключением…');
    try {
      // The previous node gets a short head start of its own: when it still
      // works (the common case) the connect is one probe away.
      if (last != null) {
        await pf.testRaw(last.id, last.outbound,
            timeoutMs: timeoutMs.clamp(1500, 2500), quick: true);
        if (ref.read(preflightProvider)[last.id]?.isGood ?? false) return last;
      }
      final found = await pf.burstFindGood(
        ordered,
        {for (final id in ordered) id: byId[id]!.outbound},
        timeoutMs: timeoutMs,
        deadline: _scanDeadline,
      );
      if (found != null) return byId[found];
      log.add('warn', 'route',
          'ни один узел не ответил за ${_scanDeadline.inSeconds} с — '
          'пробую лучший по пингу');
      return fallback;
    } finally {
      phase.state = null;
    }
  };
});

/// The "⚡ Авто" case of [connectPickProvider].
final autoConnectPickProvider = Provider<Future<Node?> Function()>(
  (ref) => () => ref.read(connectPickProvider)(const Selection.auto()),
);

/// The node that worked last time, if the user's current [selection] still
/// allows it: any live node for "⚡ Авто", the same country for a country, a
/// member for a bundle.
Node? lastGoodNodeFor(Selection selection, String? lastGoodId, List<Node> nodes) {
  if (lastGoodId == null || selection.node != null) return null;
  Node? last;
  for (final n in nodes) {
    if (n.id == lastGoodId) {
      last = n;
      break;
    }
  }
  if (last == null || !last.health.alive) return null;
  if (selection.countryCode != null &&
      last.countryCode != selection.countryCode) {
    return null;
  }
  // A bundle is an explicit shortlist with its own order — do not jump it.
  if (selection.bundleId != null) return null;
  return last;
}

/// How many nodes the pre-connect scan is allowed to race through, and how long
/// the user waits before we just try the best-ranked one anyway.
const _scanWidth = 24;
const _scanDeadline = Duration(seconds: 9);

bool _isFresh(NodeProbe? p) =>
    p?.at?.isAfter(DateTime.now().subtract(const Duration(minutes: 5))) ?? false;
