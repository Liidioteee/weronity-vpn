import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/connection_controller.dart';
import '../core/singbox_bridge.dart';
import '../domain/node.dart';
import 'preflight.dart';
import 'providers.dart';

/// Always-on, deliberately gentle background watchdog. While `Settings.autoCheck`
/// is on it:
///   * re-probes the **active** node every tick and, after 3 misses, fails over
///     to the best live alternative (same country first) if `autoSwitch` is on;
///   * otherwise refreshes one *stale* node per tick — prioritising the current
///     selection's country and recommended nodes — so auto-bundles and the
///     backup list stay fresh without a manual "Проверить видимые".
///
/// One probe per ~12 s → ~5 nodes/min, a full 130-node pool covered in ~25 min.
/// Kept alive by a `ref.watch` at the app root.
final monitorProvider = Provider<void>((ref) {
  final enabled = ref.watch(settingsProvider.select((s) => s.autoCheck));
  if (!enabled) return;
  if (!ref.watch(nativeCoreProvider).isAvailable) return;

  final fails = <String, int>{};
  var rr = 0;
  var busy = false;

  Future<void> tick() async {
    if (busy) return;
    busy = true;
    try {
      final pf = ref.read(preflightProvider.notifier);
      if (pf.anyTesting) return; // stay out of the way of a manual sweep

      final nodes = ref.read(nodesProvider);
      if (nodes.isEmpty) return;
      final controller = ref.read(connectionControllerProvider);

      // --- 1. the live connection -------------------------------------
      final active = controller.activeNode;
      if (controller.isActive && active != null) {
        final ok = await _tunnelAlive(controller);
        fails[active.id] = ok ? 0 : (fails[active.id] ?? 0) + 1;
        if (!ok) {
          debugPrint('monitor: active node ${active.id} missed '
              '${fails[active.id]}/3');
        }
        if ((fails[active.id] ?? 0) >= 3) {
          fails[active.id] = 0;
          await _failover(ref, active);
        }
        return; // one action per tick
      }

      // --- 2. keep backups vetted -----------------------------------
      final sel = controller.selection;
      final ordered = <String>{
        for (final n in nodes)
          if (sel.countryCode != null && n.countryCode == sel.countryCode) n.id,
        for (final n in nodes)
          if (n.recommended) n.id,
        for (final n in nodes) n.id,
      }.toList();
      final stale =
          pf.staleAmong(ordered, const Duration(minutes: 8)).toList();
      if (stale.isEmpty) return;
      final id = stale[rr++ % stale.length];
      final node = nodes.firstWhere((n) => n.id == id, orElse: () => nodes.first);
      await pf.testRaw(node.id, node.outbound);
    } on Object catch (e) {
      debugPrint('monitor tick failed: $e');
    } finally {
      busy = false;
    }
  }

  final periodic = Timer.periodic(const Duration(seconds: 12), (_) => tick());
  final kick = Timer(const Duration(seconds: 5), tick);
  ref.onDispose(() {
    periodic.cancel();
    kick.cancel();
  });
});

/// A real request through the current tunnel (HTTP-CONNECT via the local mixed
/// inbound in proxy mode; direct in VPN mode — everything is tunnelled anyway).
Future<bool> _tunnelAlive(ConnectionEngine controller) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6);
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
        .timeout(const Duration(seconds: 8));
    final resp = await req.close().timeout(const Duration(seconds: 8));
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
  final probes = ref.read(preflightProvider);
  Node? pick = _bestOf(
    nodes.where((n) =>
        n.id != dead.id && n.health.alive && n.countryCode == dead.countryCode),
    probes,
  );
  pick ??= _bestOf(
    nodes.where((n) => n.id != dead.id && n.health.alive),
    probes,
  );
  pick ??= resolve(controller.selection);
  if (pick == null || pick.id == dead.id) {
    log.add('error', 'monitor',
        'узел ${_name(dead)} не отвечает — замены не нашлось');
    return;
  }

  log.add('warn', 'monitor',
      'узел ${_name(dead)} не отвечает — переключаюсь на ${_name(pick)}');
  await controller.select(Selection.node(pick), resolve);
  if (!controller.isActive) await controller.connect(resolve);
}

Node? _bestOf(Iterable<Node> cands, Map<String, NodeProbe> probes) {
  final list = cands.toList();
  if (list.isEmpty) return null;
  int score(Node n) {
    final p = probes[n.id];
    if (p != null && p.isGood) return p.bestMs ?? 900;
    return 100000 + (n.health.pingMs ?? 9999);
  }

  list.sort((a, b) => score(a).compareTo(score(b)));
  return list.first;
}

String _name(Node n) => n.tag.isEmpty ? n.endpoint.host : n.tag;
