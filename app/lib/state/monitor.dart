import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/connection_controller.dart';
import '../core/singbox_bridge.dart';
import '../data/custom_keys_repository.dart';
import '../domain/country_names.dart';
import '../domain/node.dart';
import 'bundles.dart';
import 'candidates.dart';
import 'custom_keys.dart' show geoIpServiceProvider;
import 'exit_geo.dart';
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
/// **Connected, and the tunnel is fine:** on connect, after every switch and
/// then every few minutes it asks, through the tunnel, which country the
/// traffic actually comes out in ([exitCheckInterval]) — from several
/// geolocation sources, because they disagree about leased address space. The
/// node's listed country is only a GeoIP guess about its entry address. The
/// answer corrects the node everywhere ([exitGeoProvider]) and the home screen
/// shows it. If the user picked a country and the exit is somewhere else — or
/// the sources cannot agree that it is there — the session moves to a node
/// whose exit in that country is undisputed; if there is none it stays put and
/// says so ([exitNoticeProvider]).
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
  DateTime? lastExitCheckAt;
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
          lastExitCheckAt = null; // a different node — its exit is unverified
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
          // The tunnel works — is it coming out where the user thinks it is?
          if (lastExitCheckAt == null ||
              DateTime.now().difference(lastExitCheckAt!) >=
                  exitCheckInterval) {
            lastExitCheckAt = DateTime.now();
            await _verifyExit(ref, controller, active, pingTimeout);
          }
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
      lastExitCheckAt = null;
      misses = 0;
      retryFailoverAt = null;
      setNotice(null);
      _clearExitState(ref);

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

/// How often a healthy session re-checks which country it exits in (it is also
/// checked right after connecting and after every switch).
const exitCheckInterval = Duration(minutes: 3);

/// Shown on the home screen while the session is up but its node does not
/// answer and no replacement was found. `null` = nothing to report.
final connectionNoticeProvider = StateProvider<String?>((ref) => null);

/// What was last *seen* about the running session's exit, with the node it was
/// seen through. The home screen shows this country — with a "verified" mark
/// when the sources agree, a warning when they do not — instead of the node's
/// listed one. `null` until the first check of a session.
final sessionExitProvider =
    StateProvider<({String nodeId, ExitGeo exit})?>((ref) => null);

/// Shown on the home screen while the session's exit is not (or not certainly)
/// in the country the user picked and no better node was found.
final exitNoticeProvider = StateProvider<String?>((ref) => null);

void _clearExitState(Ref ref) {
  if (ref.read(sessionExitProvider) != null) {
    ref.read(sessionExitProvider.notifier).state = null;
  }
  if (ref.read(exitNoticeProvider) != null) {
    ref.read(exitNoticeProvider.notifier).state = null;
  }
}

/// An [HttpClient] whose requests go through the current tunnel: via the local
/// mixed inbound in proxy mode; direct in VPN mode — everything is tunnelled
/// anyway. `null` when the proxy endpoint is not known yet.
HttpClient? _tunnelClient(ConnectionEngine controller, Duration timeout) {
  final client = HttpClient()..connectionTimeout = timeout;
  if (controller is SingBoxBridge && !controller.isVpn) {
    final ep = controller.proxyEndpoint; // "127.0.0.1:<port>"
    if (ep == null) {
      client.close(force: true);
      return null;
    }
    client.findProxy = (_) => 'PROXY $ep';
  }
  return client;
}

/// Fetches a small text body through the tunnel; null on any failure.
Future<String?> _getThroughTunnel(
  ConnectionEngine controller,
  String url,
  Duration timeout,
) async {
  final client = _tunnelClient(controller, timeout);
  if (client == null) return null;
  try {
    final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
    final resp = await req.close().timeout(timeout);
    if (resp.statusCode != 200) {
      await resp.drain<void>();
      return null;
    }
    return await resp
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .timeout(timeout);
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Asks, through the tunnel, where the session's traffic comes out — two
/// online sources in parallel plus the bundled table for the exit address.
/// `null` = nobody could tell — never treated as a mismatch.
Future<ExitGeo?> _observeExit(
  Ref ref,
  ConnectionEngine controller,
  Duration timeout,
) async {
  final answers = await Future.wait([
    _getThroughTunnel(controller, exitTraceUrl, timeout),
    _getThroughTunnel(controller, exitSecondOpinionUrl, timeout),
  ]);
  final trace = answers[0];
  final second = answers[1];
  return ExitGeo.fromOpinions([
    if (trace != null) parseTraceCountry(trace),
    if (second != null) parseCountryIs(second),
    if (trace != null)
      offlineCountry(
        ref.read(geoIpServiceProvider).valueOrNull,
        parseTraceIp(trace),
      ),
  ]);
}

/// Checks where the session through [active] really exits, records it, and —
/// when the user picked a country and this is not it — tries to move the
/// session to a node that does exit there.
Future<void> _verifyExit(
  Ref ref,
  ConnectionEngine controller,
  Node active,
  Duration timeout,
) async {
  final seen = await _observeExit(ref, controller, timeout);
  if (seen == null) return; // could not tell: say nothing, change nothing
  // The session may have ended or moved while we asked.
  if (controller.status != ConnectionStatus.protected ||
      controller.activeNode?.id != active.id) {
    return;
  }

  ref.read(exitGeoProvider.notifier).record(active.id, seen);
  ref.read(sessionExitProvider.notifier).state = (nodeId: active.id, exit: seen);

  final exitNotice = ref.read(exitNoticeProvider.notifier);
  final wanted = controller.selection.countryCode;
  if (wanted == null || seen.confirms(wanted)) {
    if (exitNotice.state != null) exitNotice.state = null;
    return;
  }

  final log = ref.read(logControllerProvider);
  final wantedName = countryNameRu(wanted);
  // Either the exit is plainly somewhere else, or it is in the right country
  // by some databases and not by others — to a site using one of the others
  // the user is not where they asked to be.
  final String problem;
  if (seen.country != wanted) {
    problem = 'выход в интернет — «${countryNameRu(seen.country)}», '
        'а не «$wantedName»';
  } else {
    problem = 'геобазы расходятся: выход в «$wantedName» по одним данным и в '
        '«${countryNameRu(seen.disputedWith)}» по другим';
  }
  log.add('warn', 'monitor',
      'узел ${_name(active)}: $problem — ищу узел с бесспорным выходом в '
      '«$wantedName»');

  final moved = await _relocate(ref, active, wanted);
  if (moved) {
    exitNotice.state = null;
    return;
  }
  final why = ref.read(settingsProvider).autoSwitch
      ? 'узлов с бесспорным выходом в «$wantedName» не найдено'
      : 'автопереключение выключено';
  log.add('warn', 'monitor', 'остаюсь на узле ${_name(active)}: $why');
  exitNotice.state =
      '${problem[0].toUpperCase()}${problem.substring(1)}. '
      '${why[0].toUpperCase()}${why.substring(1)}.';
}

/// Moves the session to a node that has been *seen* exiting in [wanted] with no
/// source disagreeing. Unlike a failover, the current node works — so only a
/// verified match is worth the switch; a node whose exit is merely listed as
/// [wanted] is exactly what just turned out to be wrong.
Future<bool> _relocate(Ref ref, Node active, String wanted) async {
  final settings = ref.read(settingsProvider);
  if (!settings.autoSwitch) return false;
  final controller = ref.read(connectionControllerProvider);

  // Read the node list *now*: the record above has just moved [active] out of
  // [wanted], and every probe below moves more mislabelled nodes out too.
  final scope = failoverScope(
    controller.selection,
    active,
    ref.read(nodesProvider),
    ref.read(allBundlesProvider),
  );
  final byId = {for (final n in scope) n.id: n};
  final ids = [for (final n in scope.take(_failoverScanWidth)) n.id];
  if (ids.isEmpty) return false;

  bool exitsInWanted(String id) =>
      ref.read(exitGeoProvider)[id]?.confirms(wanted) ?? false;

  Node? pick = _firstGood(
    [for (final id in ids) if (exitsInWanted(id)) id],
    byId,
    ref.read(preflightProvider),
    freshOnly: true,
  );
  if (pick == null) {
    final foundId = await ref.read(preflightProvider.notifier).burstFindGood(
          ids,
          {for (final id in ids) id: byId[id]!.outbound},
          timeoutMs: (settings.checkTimeoutMs * 0.6).round().clamp(1500, 4000),
          accept: exitsInWanted,
        );
    pick = foundId == null ? null : byId[foundId];
  }
  if (pick == null) return false;

  if (controller.status != ConnectionStatus.protected ||
      controller.activeNode?.id != active.id) {
    return false;
  }
  ref.read(logControllerProvider).add('info', 'monitor',
      'переключаюсь на ${_name(pick)} — выход в «${countryNameRu(wanted)}» подтверждён');
  return controller.switchTo(pick);
}

/// A real request through the current tunnel.
Future<bool> _tunnelAlive(ConnectionEngine controller, Duration timeout) async {
  final client = _tunnelClient(controller, timeout);
  if (client == null) return false;
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
          accept: _exitAllowedBy(ref, controller.selection),
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

/// For a country selection: a node whose check has just shown it exits
/// somewhere else — or that the geolocation sources cannot agree on — is not an
/// acceptable pick, however well it works. A node whose exit could not be
/// determined at all keeps the benefit of the doubt: the session re-checks it
/// once connected. Any other selection accepts everything.
bool Function(String id)? _exitAllowedBy(Ref ref, Selection selection) {
  final wanted = selection.countryCode;
  if (wanted == null) return null;
  return (id) {
    final seen = ref.read(exitGeoProvider)[id];
    return seen == null || seen.confirms(wanted);
  };
}

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
        final allowed = _exitAllowedBy(ref, selection);
        if ((ref.read(preflightProvider)[last.id]?.isGood ?? false) &&
            (allowed == null || allowed(last.id))) {
          return last;
        }
      }
      final found = await pf.burstFindGood(
        ordered,
        {for (final id in ordered) id: byId[id]!.outbound},
        timeoutMs: timeoutMs,
        deadline: _scanDeadline,
        accept: _exitAllowedBy(ref, selection),
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
