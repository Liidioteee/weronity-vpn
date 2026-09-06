import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/custom_keys_repository.dart';
import '../domain/node.dart';
import 'custom_keys.dart';
import 'preflight.dart';
import 'providers.dart';

/// A service commonly blocked/throttled in RU. Its [probeUrl] must also be one
/// of `Settings.preflightEndpoints` so preflight collects a per-service result.
@immutable
class BlockedService {
  const BlockedService(this.key, this.name, this.probeUrl, this.icon);
  final String key;
  final String name;
  final String probeUrl;
  final IconData icon;
}

const kBlockedServices = <BlockedService>[
  BlockedService('youtube', 'YouTube', 'https://www.youtube.com/favicon.ico',
      Icons.smart_display_rounded),
  BlockedService('instagram', 'Instagram',
      'https://www.instagram.com/favicon.ico', Icons.photo_camera_rounded),
  BlockedService(
      'x', 'X (Twitter)', 'https://x.com/favicon.ico', Icons.tag_rounded),
  BlockedService('facebook', 'Facebook',
      'https://www.facebook.com/favicon.ico', Icons.thumb_up_rounded),
  BlockedService('discord', 'Discord',
      'https://discord.com/assets/favicon.ico', Icons.forum_rounded),
  BlockedService('signal', 'Signal', 'https://signal.org/favicon.ico',
      Icons.lock_rounded),
];

BlockedService? blockedServiceForBundle(String bundleId) {
  if (!bundleId.startsWith('auto:')) return null;
  final key = bundleId.substring(5);
  for (final s in kBlockedServices) {
    if (s.key == key) return s;
  }
  return null;
}

/// Auto-generated collections: for each blocked service, the nodes whose
/// preflight probe to that service succeeded, ranked by that probe's latency.
/// Recomputed live from [preflightProvider]; never persisted.
final autoBundlesProvider = Provider<List<KeyBundle>>((ref) {
  final probes = ref.watch(preflightProvider);
  if (probes.isEmpty) return const [];
  final known = {for (final n in ref.watch(nodesProvider)) n.id};

  final out = <KeyBundle>[];
  for (final svc in kBlockedServices) {
    final scored = <(String, int)>[];
    probes.forEach((nodeId, probe) {
      if (!known.contains(nodeId)) return;
      for (final h in probe.hits) {
        if (h.url == svc.probeUrl && h.ok) {
          scored.add((nodeId, h.latencyMs));
          break;
        }
      }
    });
    if (scored.isEmpty) continue;
    scored.sort((a, b) => a.$2.compareTo(b.$2));
    out.add(KeyBundle(
      id: 'auto:${svc.key}',
      name: 'Лучшие для ${svc.name}',
      nodeIds: [for (final s in scored) s.$1],
    ));
  }
  return out;
});

/// User bundles + auto bundles, in that order.
final allBundlesProvider = Provider<List<KeyBundle>>((ref) {
  final user =
      ref.watch(customKeysProvider).valueOrNull?.bundles ?? const <KeyBundle>[];
  return [...user, ...ref.watch(autoBundlesProvider)];
});

/// Live members of [b] drawn from [allNodes], best-first. Auto bundles keep
/// their service-latency order; user bundles fall back to the collector ping.
List<Node> bundleLiveNodes(KeyBundle b, List<Node> allNodes) {
  final byId = {for (final n in allNodes) n.id: n};
  final alive = [
    for (final id in b.nodeIds)
      if (byId[id] case final Node n)
        if (n.health.alive) n,
  ];
  if (b.isAuto) return alive; // already sorted by service latency
  alive.sort((x, y) =>
      (x.health.pingMs ?? 1 << 20).compareTo(y.health.pingMs ?? 1 << 20));
  return alive;
}
