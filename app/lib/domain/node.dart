import 'dart:convert';

/// Client-side mirror of `nodes_pool.json` (see collector `docs/pool-schema.md`).
///
/// Models are immutable and parsed defensively — a malformed field degrades to a
/// sensible default rather than throwing, so one bad node never breaks the pool.

enum LifetimeClass {
  fresh,
  shortLived,
  longLived;

  static LifetimeClass parse(String? raw) => switch (raw) {
        'fresh' => LifetimeClass.fresh,
        'short_lived' => LifetimeClass.shortLived,
        'long_lived' => LifetimeClass.longLived,
        _ => LifetimeClass.fresh,
      };

  /// Wire value used in `nodes_pool.json` (snake_case).
  String get wire => switch (this) {
        LifetimeClass.fresh => 'fresh',
        LifetimeClass.shortLived => 'short_lived',
        LifetimeClass.longLived => 'long_lived',
      };

  String get label => switch (this) {
        LifetimeClass.fresh => 'Новый',
        LifetimeClass.shortLived => 'Недолгий',
        LifetimeClass.longLived => 'Долгоживущий',
      };
}

enum NodeSecurity {
  reality,
  tls,
  none;

  static NodeSecurity parse(String? raw) => switch (raw) {
        'reality' => NodeSecurity.reality,
        'tls' => NodeSecurity.tls,
        _ => NodeSecurity.none,
      };

  String get label => switch (this) {
        NodeSecurity.reality => 'Reality',
        NodeSecurity.tls => 'TLS',
        NodeSecurity.none => 'нет',
      };
}

class Endpoint {
  const Endpoint({required this.host, required this.port, this.resolvedIp});

  final String host;
  final int port;
  final String? resolvedIp;

  factory Endpoint.fromJson(Map<String, dynamic> j) => Endpoint(
        host: (j['host'] ?? '').toString(),
        port: _int(j['port']),
        resolvedIp: j['resolved_ip'] as String?,
      );
}

class Geo {
  const Geo({
    this.country,
    this.countryName,
    this.flag,
    this.asn,
    this.asOrg,
    this.city,
  });

  final String? country;
  final String? countryName;
  final String? flag;
  final int? asn;
  final String? asOrg;
  final String? city;

  factory Geo.fromJson(Map<String, dynamic> j) => Geo(
        country: j['country'] as String?,
        countryName: j['country_name'] as String?,
        flag: j['flag'] as String?,
        asn: j['asn'] == null ? null : _int(j['asn']),
        asOrg: j['as_org'] as String?,
        city: j['city'] as String?,
      );

  static const unknown = Geo();
}

class Health {
  const Health({
    required this.tcpOk,
    required this.tlsOk,
    required this.pingMs,
    required this.checkedAt,
  });

  final bool tcpOk;
  final bool tlsOk;
  final int? pingMs;
  final DateTime? checkedAt;

  bool get alive => tcpOk;

  factory Health.fromJson(Map<String, dynamic> j) => Health(
        tcpOk: j['tcp_ok'] == true,
        tlsOk: j['tls_ok'] == true,
        pingMs: j['ping_ms'] == null ? null : _int(j['ping_ms']),
        checkedAt: DateTime.tryParse(j['checked_at']?.toString() ?? ''),
      );
}

class Lifetime {
  const Lifetime({
    required this.firstSeen,
    required this.lastSeen,
    required this.ageHours,
    required this.klass,
    required this.seenRuns,
    required this.stability,
  });

  final DateTime? firstSeen;
  final DateTime? lastSeen;
  final int ageHours;
  final LifetimeClass klass;
  final int seenRuns;
  final double stability;

  factory Lifetime.fromJson(Map<String, dynamic> j) => Lifetime(
        firstSeen: DateTime.tryParse(j['first_seen']?.toString() ?? ''),
        lastSeen: DateTime.tryParse(j['last_seen']?.toString() ?? ''),
        ageHours: _int(j['age_hours']),
        klass: LifetimeClass.parse(j['class'] as String?),
        seenRuns: _int(j['seen_runs']),
        stability: _double(j['stability']),
      );

  static const zero = Lifetime(
    firstSeen: null,
    lastSeen: null,
    ageHours: 0,
    klass: LifetimeClass.fresh,
    seenRuns: 0,
    stability: 0,
  );
}

class Classification {
  const Classification({
    this.sni,
    this.security = NodeSecurity.none,
    this.flow,
    this.cdn = false,
    this.ipv6 = false,
    this.udp = false,
  });

  final String? sni;
  final NodeSecurity security;
  final String? flow;
  final bool cdn;
  final bool ipv6;
  final bool udp;

  factory Classification.fromJson(Map<String, dynamic> j) => Classification(
        sni: j['sni'] as String?,
        security: NodeSecurity.parse(j['security'] as String?),
        flow: j['flow'] as String?,
        cdn: j['cdn'] == true,
        ipv6: j['ipv6'] == true,
        udp: j['udp'] == true,
      );

  static const empty = Classification();
}

class Provenance {
  const Provenance({
    required this.source,
    required this.sourceFile,
    required this.imported,
    required this.rawUriSha1,
  });

  final String source;
  final String sourceFile;
  final bool imported;
  final String rawUriSha1;

  bool get isCustom => imported;

  factory Provenance.fromJson(Map<String, dynamic> j) => Provenance(
        source: (j['source'] ?? 'unknown').toString(),
        sourceFile: (j['source_file'] ?? '').toString(),
        imported: j['imported'] == true,
        rawUriSha1: (j['raw_uri_sha1'] ?? '').toString(),
      );

  static const unknown =
      Provenance(source: 'unknown', sourceFile: '', imported: false, rawUriSha1: '');
}

class Node {
  const Node({
    required this.id,
    required this.protocol,
    required this.transport,
    required this.tag,
    required this.endpoint,
    required this.geo,
    required this.health,
    required this.lifetime,
    required this.classification,
    required this.provenance,
    required this.recommended,
    required this.rawUri,
    required this.outbound,
  });

  final String id;
  final String protocol;
  final String transport;
  final String tag;
  final Endpoint endpoint;
  final Geo geo;
  final Health health;
  final Lifetime lifetime;
  final Classification classification;
  final Provenance provenance;
  final bool recommended;
  final String rawUri;
  final Map<String, dynamic> outbound;

  bool get isCustom => provenance.isCustom;
  String get countryCode => geo.country ?? '??';
  String get displayFlag => geo.flag ?? '🏳️';

  /// Narrow copy — currently only [geo] needs overriding (imported keys get a
  /// country resolved offline after parsing). Extend as needed.
  Node copyWith({Geo? geo}) => Node(
        id: id,
        protocol: protocol,
        transport: transport,
        tag: tag,
        endpoint: endpoint,
        geo: geo ?? this.geo,
        health: health,
        lifetime: lifetime,
        classification: classification,
        provenance: provenance,
        recommended: recommended,
        rawUri: rawUri,
        outbound: outbound,
      );

  factory Node.fromJson(Map<String, dynamic> j) => Node(
        id: (j['id'] ?? '').toString(),
        protocol: (j['protocol'] ?? '').toString(),
        transport: (j['transport'] ?? '').toString(),
        tag: (j['tag'] ?? '').toString(),
        endpoint: Endpoint.fromJson(_map(j['endpoint'])),
        geo: j['geo'] == null ? Geo.unknown : Geo.fromJson(_map(j['geo'])),
        health: Health.fromJson(_map(j['health'])),
        lifetime: j['lifetime'] == null
            ? Lifetime.zero
            : Lifetime.fromJson(_map(j['lifetime'])),
        classification: j['classification'] == null
            ? Classification.empty
            : Classification.fromJson(_map(j['classification'])),
        provenance: j['provenance'] == null
            ? Provenance.unknown
            : Provenance.fromJson(_map(j['provenance'])),
        recommended: j['recommended'] == true,
        rawUri: (j['raw_uri'] ?? '').toString(),
        outbound: _map(j['outbound']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'protocol': protocol,
        'transport': transport,
        'tag': tag,
        'endpoint': {
          'host': endpoint.host,
          'port': endpoint.port,
          'resolved_ip': endpoint.resolvedIp,
        },
        'geo': {
          'country': geo.country,
          'country_name': geo.countryName,
          'flag': geo.flag,
          'asn': geo.asn,
          'as_org': geo.asOrg,
          'city': geo.city,
        },
        'health': {
          'tcp_ok': health.tcpOk,
          'tls_ok': health.tlsOk,
          'ping_ms': health.pingMs,
          'checked_at': health.checkedAt?.toIso8601String(),
        },
        'lifetime': {
          'first_seen': lifetime.firstSeen?.toIso8601String(),
          'last_seen': lifetime.lastSeen?.toIso8601String(),
          'age_hours': lifetime.ageHours,
          'class': lifetime.klass.wire,
          'seen_runs': lifetime.seenRuns,
          'stability': lifetime.stability,
        },
        'classification': {
          'sni': classification.sni,
          'security': classification.security.name,
          'flow': classification.flow,
          'cdn': classification.cdn,
          'ipv6': classification.ipv6,
          'udp': classification.udp,
        },
        'provenance': {
          'source': provenance.source,
          'source_file': provenance.sourceFile,
          'imported': provenance.imported,
          'raw_uri_sha1': provenance.rawUriSha1,
        },
        'recommended': recommended,
        'raw_uri': rawUri,
        'outbound': outbound,
      };
}

class PoolStats {
  const PoolStats({
    required this.total,
    required this.byProtocol,
    required this.byCountry,
    required this.byLifetime,
  });

  final int total;
  final Map<String, int> byProtocol;
  final Map<String, int> byCountry;
  final Map<String, int> byLifetime;

  factory PoolStats.fromJson(Map<String, dynamic> j) => PoolStats(
        total: _int(j['total']),
        byProtocol: _intMap(j['by_protocol']),
        byCountry: _intMap(j['by_country']),
        byLifetime: _intMap(j['by_lifetime']),
      );

  static const empty =
      PoolStats(total: 0, byProtocol: {}, byCountry: {}, byLifetime: {});
}

class NodePool {
  const NodePool({
    required this.schemaVersion,
    required this.generatedAt,
    required this.generator,
    required this.stats,
    required this.nodes,
  });

  final int schemaVersion;
  final DateTime? generatedAt;
  final String generator;
  final PoolStats stats;
  final List<Node> nodes;

  bool get isEmpty => nodes.isEmpty;

  factory NodePool.fromJson(Map<String, dynamic> j) {
    final rawNodes = (j['nodes'] as List<dynamic>? ?? const []);
    return NodePool(
      schemaVersion: _int(j['schema_version']),
      generatedAt: DateTime.tryParse(j['generated_at']?.toString() ?? ''),
      generator: (j['generator'] ?? '').toString(),
      stats: j['stats'] == null
          ? PoolStats.empty
          : PoolStats.fromJson(_map(j['stats'])),
      nodes: [
        for (final n in rawNodes)
          if (n is Map<String, dynamic>) Node.fromJson(n),
      ],
    );
  }

  factory NodePool.decode(String source) =>
      NodePool.fromJson(jsonDecode(source) as Map<String, dynamic>);

  static const empty = NodePool(
    schemaVersion: 1,
    generatedAt: null,
    generator: '',
    stats: PoolStats.empty,
    nodes: [],
  );
}

// --- parsing helpers -------------------------------------------------------

Map<String, dynamic> _map(Object? v) =>
    v is Map<String, dynamic> ? v : const {};

int _int(Object? v) => switch (v) {
      int() => v,
      num() => v.toInt(),
      String() => int.tryParse(v) ?? 0,
      _ => 0,
    };

double _double(Object? v) => switch (v) {
      num() => v.toDouble(),
      String() => double.tryParse(v) ?? 0,
      _ => 0,
    };

Map<String, int> _intMap(Object? v) => v is Map
    ? {for (final e in v.entries) e.key.toString(): _int(e.value)}
    : const {};
