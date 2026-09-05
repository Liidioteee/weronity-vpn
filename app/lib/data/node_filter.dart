import '../domain/node.dart';

enum NodeSort {
  pingAsc,
  stabilityDesc,
  ageDesc;

  String get label => switch (this) {
        NodeSort.pingAsc => 'По задержке',
        NodeSort.stabilityDesc => 'По стабильности',
        NodeSort.ageDesc => 'По времени жизни',
      };
}

/// Filter/sort spec used by the Node Inspector (Pro) and the location picker.
class NodeFilter {
  const NodeFilter({
    this.query = '',
    this.countries = const {},
    this.protocols = const {},
    this.securities = const {},
    this.lifetimeClasses = const {},
    this.aliveOnly = true,
    this.recommendedOnly = false,
    this.customOnly = false,
    this.udpOnly = false,
    this.minStability = 0,
    this.maxPingMs = 0, // 0 = no cap
    this.sort = NodeSort.pingAsc,
  });

  final String query;
  final Set<String> countries;
  final Set<String> protocols;
  final Set<NodeSecurity> securities;
  final Set<LifetimeClass> lifetimeClasses;
  final bool aliveOnly;
  final bool recommendedOnly;
  final bool customOnly;
  final bool udpOnly;
  final double minStability;
  final int maxPingMs;
  final NodeSort sort;

  bool get isActive =>
      query.isNotEmpty ||
      countries.isNotEmpty ||
      protocols.isNotEmpty ||
      securities.isNotEmpty ||
      lifetimeClasses.isNotEmpty ||
      recommendedOnly ||
      customOnly ||
      udpOnly ||
      minStability > 0 ||
      maxPingMs > 0 ||
      !aliveOnly;

  NodeFilter copyWith({
    String? query,
    Set<String>? countries,
    Set<String>? protocols,
    Set<NodeSecurity>? securities,
    Set<LifetimeClass>? lifetimeClasses,
    bool? aliveOnly,
    bool? recommendedOnly,
    bool? customOnly,
    bool? udpOnly,
    double? minStability,
    int? maxPingMs,
    NodeSort? sort,
  }) =>
      NodeFilter(
        query: query ?? this.query,
        countries: countries ?? this.countries,
        protocols: protocols ?? this.protocols,
        securities: securities ?? this.securities,
        lifetimeClasses: lifetimeClasses ?? this.lifetimeClasses,
        aliveOnly: aliveOnly ?? this.aliveOnly,
        recommendedOnly: recommendedOnly ?? this.recommendedOnly,
        customOnly: customOnly ?? this.customOnly,
        udpOnly: udpOnly ?? this.udpOnly,
        minStability: minStability ?? this.minStability,
        maxPingMs: maxPingMs ?? this.maxPingMs,
        sort: sort ?? this.sort,
      );

  bool matches(Node n) {
    if (aliveOnly && !n.health.alive) return false;
    if (recommendedOnly && !n.recommended) return false;
    if (customOnly && !n.isCustom) return false;
    if (udpOnly && !n.classification.udp) return false;
    if (countries.isNotEmpty && !countries.contains(n.countryCode)) return false;
    if (protocols.isNotEmpty && !protocols.contains(n.protocol)) return false;
    if (securities.isNotEmpty && !securities.contains(n.classification.security)) {
      return false;
    }
    if (lifetimeClasses.isNotEmpty &&
        !lifetimeClasses.contains(n.lifetime.klass)) {
      return false;
    }
    if (n.lifetime.stability < minStability) return false;
    if (maxPingMs > 0 && (n.health.pingMs ?? 1 << 30) > maxPingMs) return false;
    if (query.isNotEmpty) {
      final q = query.toLowerCase();
      final hay = '${n.tag} ${n.endpoint.host} ${n.geo.asOrg ?? ''} '
              '${n.classification.sni ?? ''} ${n.protocol} ${n.countryCode}'
          .toLowerCase();
      if (!hay.contains(q)) return false;
    }
    return true;
  }

  List<Node> apply(Iterable<Node> nodes) {
    final out = nodes.where(matches).toList();
    out.sort(switch (sort) {
      NodeSort.pingAsc => (a, b) =>
          (a.health.pingMs ?? 1 << 30).compareTo(b.health.pingMs ?? 1 << 30),
      NodeSort.stabilityDesc => (a, b) =>
          b.lifetime.stability.compareTo(a.lifetime.stability),
      NodeSort.ageDesc => (a, b) =>
          b.lifetime.ageHours.compareTo(a.lifetime.ageHours),
    });
    return out;
  }
}

/// One row in the location picker: a country with aggregate stats.
class CountryOption {
  CountryOption({
    required this.code,
    required this.flag,
    required this.nodeCount,
    required this.bestPingMs,
    required this.recommendedCount,
  });

  final String code;
  final String flag;
  final int nodeCount;
  final int? bestPingMs;
  final int recommendedCount;

  static List<CountryOption> from(Iterable<Node> nodes) {
    final byCode = <String, List<Node>>{};
    for (final n in nodes) {
      if (!n.health.alive) continue;
      byCode.putIfAbsent(n.countryCode, () => []).add(n);
    }
    final list = [
      for (final e in byCode.entries)
        CountryOption(
          code: e.key,
          flag: e.value.first.displayFlag,
          nodeCount: e.value.length,
          bestPingMs: e.value
              .map((n) => n.health.pingMs)
              .whereType<int>()
              .fold<int?>(null, (m, p) => m == null || p < m ? p : m),
          recommendedCount: e.value.where((n) => n.recommended).length,
        ),
    ]..sort((a, b) {
        final ap = a.bestPingMs ?? 1 << 30;
        final bp = b.bestPingMs ?? 1 << 30;
        return ap.compareTo(bp);
      });
    return list;
  }
}
