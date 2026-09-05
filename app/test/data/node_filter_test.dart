import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/data/node_filter.dart';
import 'package:weronity/domain/node.dart';

Node _node({
  required String id,
  String protocol = 'vless',
  String country = 'DE',
  bool alive = true,
  int? ping = 100,
  bool recommended = false,
  bool custom = false,
  bool udp = false,
  double stability = 0.5,
  NodeSecurity security = NodeSecurity.reality,
  LifetimeClass klass = LifetimeClass.fresh,
  String tag = 'node',
}) {
  return Node(
    id: id,
    protocol: protocol,
    transport: 'tcp',
    tag: tag,
    endpoint: Endpoint(host: '$id.example.net', port: 443),
    geo: Geo(country: country, flag: '🏳️', asOrg: 'ACME'),
    health: Health(
      tcpOk: alive,
      tlsOk: alive,
      pingMs: ping,
      checkedAt: DateTime(2026),
    ),
    lifetime: Lifetime(
      firstSeen: DateTime(2026),
      lastSeen: DateTime(2026),
      ageHours: 10,
      klass: klass,
      seenRuns: 1,
      stability: stability,
    ),
    classification: Classification(security: security, udp: udp),
    provenance: Provenance(
      source: custom ? 'custom' : 'github',
      sourceFile: '',
      imported: custom,
      rawUriSha1: '',
    ),
    recommended: recommended,
    rawUri: 'vless://$id',
    outbound: const {},
  );
}

void main() {
  final nodes = [
    _node(id: 'a', ping: 60, recommended: true, stability: 0.9),
    _node(id: 'b', country: 'US', ping: 200, protocol: 'hysteria2', udp: true),
    _node(id: 'c', country: 'US', ping: 30, alive: false),
    _node(id: 'd', country: 'NL', ping: 120, custom: true, tag: 'my-key'),
  ];

  test('aliveOnly is the default and drops dead nodes', () {
    const f = NodeFilter();
    expect(f.apply(nodes).map((n) => n.id), ['a', 'd', 'b']);
  });

  test('sorts by ascending ping by default', () {
    final out = const NodeFilter().apply(nodes);
    expect(out.first.id, 'a');
    expect(out.last.id, 'b');
  });

  test('country filter', () {
    const f = NodeFilter(countries: {'US'});
    expect(f.apply(nodes).map((n) => n.id), ['b']); // c is dead
  });

  test('recommendedOnly / customOnly / udpOnly', () {
    expect(const NodeFilter(recommendedOnly: true).apply(nodes).map((n) => n.id),
        ['a']);
    expect(
        const NodeFilter(customOnly: true).apply(nodes).map((n) => n.id), ['d']);
    expect(const NodeFilter(udpOnly: true).apply(nodes).map((n) => n.id), ['b']);
  });

  test('maxPingMs cap and minStability', () {
    expect(const NodeFilter(maxPingMs: 100).apply(nodes).map((n) => n.id), ['a']);
    expect(const NodeFilter(minStability: 0.8).apply(nodes).map((n) => n.id),
        ['a']);
  });

  test('free-text query matches tag / host / org / country', () {
    expect(const NodeFilter(query: 'my-key').apply(nodes).map((n) => n.id), ['d']);
    expect(const NodeFilter(query: 'nl').apply(nodes).map((n) => n.id), ['d']);
  });

  test('isActive reflects any non-default constraint', () {
    expect(const NodeFilter().isActive, isFalse);
    expect(const NodeFilter(recommendedOnly: true).isActive, isTrue);
    expect(const NodeFilter(aliveOnly: false).isActive, isTrue);
  });

  test('CountryOption aggregates alive nodes and finds best ping', () {
    final options = CountryOption.from(nodes);
    expect(options.map((o) => o.code), ['DE', 'NL', 'US']); // sorted by best ping
    final us = options.firstWhere((o) => o.code == 'US');
    expect(us.nodeCount, 1); // dead node excluded
    expect(us.bestPingMs, 200);
    final de = options.firstWhere((o) => o.code == 'DE');
    expect(de.recommendedCount, 1);
  });
}
