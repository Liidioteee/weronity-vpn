import '../domain/node.dart';

/// Picks the backup nodes that are preloaded into the sing-box selector group
/// alongside the node the user actually chose.
///
/// They exist so a later switch — a manual one, or the background monitor's
/// failover — can be a hot-swap inside the running engine instead of a
/// stop/start. In VPN mode that is the difference between a seamless change and
/// a second of the whole machine having no network, so it is worth carrying a
/// few outbounds that may never be dialed.
///
/// Order matters: the failover path walks the same preference order (same
/// country → recommended → the rest), so the nodes most likely to be needed sit
/// in the group. Within each tier the lowest measured ping wins.
List<Node> backupCandidates(
  Node primary,
  List<Node> pool, {
  required int limit,
}) {
  int tier(Node n) {
    if (n.countryCode == primary.countryCode) return 0;
    if (n.recommended) return 1;
    return 2;
  }

  final ranked = [
    for (final n in pool)
      if (n.id != primary.id && n.health.alive) n,
  ]..sort((a, b) {
      final byTier = tier(a).compareTo(tier(b));
      if (byTier != 0) return byTier;
      return _ping(a).compareTo(_ping(b));
    });

  return ranked.length <= limit ? ranked : ranked.sublist(0, limit);
}

/// Nodes with no measurement sort last rather than first.
int _ping(Node n) {
  final ms = n.health.pingMs;
  return ms == null || ms <= 0 ? 1 << 20 : ms;
}
