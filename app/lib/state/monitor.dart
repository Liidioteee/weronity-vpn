import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/connection_controller.dart';
import '../core/singbox_bridge.dart';
import '../domain/node.dart';
import 'preflight.dart';
import 'providers.dart';

/// Always-on background watchdog (while `Settings.autoCheck` is on).
///
/// **Connected:** every ~7 s it makes a real request through the live tunnel.
/// One miss → one quick retry (~1.5 s). Still no answer → immediate failover.
/// A node that just became active and can't do even one request is switched
/// away with no retry. Failover finds a replacement with a *fast burst scan*
/// (high concurrency, short timeout) and jumps to the first node that answers,
/// same country first — most of the RU pool is blocked, so a serial search
/// would take many minutes.
///
/// **Idle:** refreshes a few stale nodes per tick (selection's country and
/// recommended nodes first) so auto-bundles and the backup list stay current
/// without a manual "Проверить видимые" and without Pro mode.
final monitorProvider = Provider<void>((ref) {
  final enabled = ref.watch(settingsProvider.select((s) => s.autoCheck));
  if (!enabled) return;
  if (!ref.watch(nativeCoreProvider).isAvailable) return;

  var rr = 0;
  var busy = false;
  var failingOver = false;
  String? lastActiveId;

  Future<void> tick() async {
    if (busy || failingOver) return;
    busy = true;
    try {
      final pf = ref.read(preflightProvider.notifier);
      final nodes = ref.read(nodesProvider);
      if (nodes.isEmpty) return;
      final controller = ref.read(connectionControllerProvider);

      // --- 1. the live connection ------------------------------------
      final active = controller.activeNode;
      if (controller.isActive && active != null) {
        final justConnected = active.id != lastActiveId;
        lastActiveId = active.id;
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
        if (!ok) {
          failingOver = true;
          try {
            await _failover(ref, active);
          } finally {
            failingOver = false;
            lastActiveId = ref.read(connectionControllerProvider).activeNode?.id;
          }
        }
        return; // one action per tick
      }
      lastActiveId = null;

      if (pf.anyTesting) return; // a manual sweep is running — don't pile on

      // --- 2. keep backups vetted ---------------------------------
      final sel = controller.selection;
      final ordered = <String>{
        for (final n in nodes)
          if (sel.countryCode != null && n.countryCode == sel.countryCode) n.id,
        for (final n in nodes)
          if (n.recommended) n.id,
        for (final n in nodes) n.id,
      }.toList();
      final stale = pf.staleAmong(ordered, const Duration(minutes: 8)).toList();
      if (stale.isEmpty) return;
      final byId = {for (final n in nodes) n.id: n};
      // 2 at a time — still light in the background, full pool in ~13 min
      final batch = <Node>{
        for (var i = 0; i < 2 && stale.isNotEmpty; i++)
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

Future<void> _failover(Ref ref, Node dead) async {
  final settings = ref.read(settingsProvider);
  final resolve = ref.read(resolveSelectionProvider);
  final controller = ref.read(connectionControllerProvider);
  final log = ref.read(logControllerProvider);

  if (!settings.autoSwitch) {
    log.add('warn', 'monitor',
        'узел ${_name(dead)} не отвечает — автопереключение выключено');
    return;
  }

  final nodes = ref.read(nodesProvider);
  final byId = {for (final n in nodes) n.id: n};
  final probes = ref.read(preflightProvider);

  // Candidate order: same country → recommended → the rest, minus the dead one.
  final candidates = <String>{
    for (final n in nodes)
      if (n.id != dead.id && n.health.alive && n.countryCode == dead.countryCode)
        n.id,
    for (final n in nodes)
      if (n.id != dead.id && n.health.alive && n.recommended) n.id,
    for (final n in nodes)
      if (n.id != dead.id && n.health.alive) n.id,
  }.toList();

  // 1. an already-known good backup?
  Node? pick = _firstGood(candidates, byId, probes);

  // 2. otherwise race the pool with a fast burst and take the first good one.
  if (pick == null) {
    log.add('warn', 'monitor',
        'узел ${_name(dead)} не отвечает — ищу рабочий…');
    final foundId = await ref.read(preflightProvider.notifier).burstFindGood(
          candidates,
          {for (final id in candidates) id: byId[id]!.outbound},
          timeoutMs: (settings.checkTimeoutMs * 0.6).round().clamp(1500, 4000),
        );
    pick = foundId == null ? null : byId[foundId];
  }

  // 3. last resort — best by ping.
  pick ??= _firstGood(candidates, byId, ref.read(preflightProvider)) ??
      (candidates.isEmpty ? null : byId[candidates.first]);

  if (pick == null || pick.id == dead.id) {
    log.add('error', 'monitor',
        'узел ${_name(dead)} не отвечает — рабочей замены не нашлось');
    return;
  }

  log.add('warn', 'monitor',
      'узел ${_name(dead)} не отвечает — переключаюсь на ${_name(pick)}');
  await controller.select(Selection.node(pick), resolve);
  if (!controller.isActive) await controller.connect(resolve);
}

Node? _firstGood(
  List<String> ids,
  Map<String, Node> byId,
  Map<String, NodeProbe> probes,
) {
  String? best;
  var bestMs = 1 << 30;
  for (final id in ids) {
    final p = probes[id];
    if (p == null || !p.isGood) continue;
    final ms = p.bestMs ?? 900;
    if (ms < bestMs) {
      bestMs = ms;
      best = id;
    }
  }
  return best == null ? null : byId[best];
}

String _name(Node n) => n.tag.isEmpty ? n.endpoint.host : n.tag;
