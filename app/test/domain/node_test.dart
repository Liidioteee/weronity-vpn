import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/domain/node.dart';

const _poolJson = '''
{
  "schema_version": 1,
  "generated_at": "2026-09-05T15:00:00Z",
  "generator": "weronity-collector/0.1.0",
  "stats": {
    "total": 2,
    "by_protocol": {"vless": 1, "hysteria2": 1},
    "by_country": {"DE": 1, "US": 1},
    "by_lifetime": {"fresh": 1, "long_lived": 1}
  },
  "nodes": [
    {
      "id": "aaa111",
      "protocol": "vless",
      "transport": "tcp",
      "tag": "DE-Reality",
      "endpoint": {"host": "de.example.net", "port": 443, "resolved_ip": "1.2.3.4"},
      "geo": {"country": "DE", "flag": "\\ud83c\\udde9\\ud83c\\uddea", "asn": 24940, "as_org": "Hetzner"},
      "health": {"tcp_ok": true, "tls_ok": true, "ping_ms": 90, "checked_at": "2026-09-05T15:00:00Z"},
      "lifetime": {"first_seen": "2026-09-01T00:00:00Z", "last_seen": "2026-09-05T15:00:00Z",
        "age_hours": 111, "class": "long_lived", "seen_runs": 40, "stability": 0.95},
      "classification": {"sni": "www.apple.com", "security": "reality", "flow": "xtls-rprx-vision",
        "cdn": false, "ipv6": false, "udp": false},
      "provenance": {"source": "github:x", "source_file": "a.txt", "imported": false, "raw_uri_sha1": "d"},
      "recommended": true,
      "raw_uri": "vless://u@de.example.net:443",
      "outbound": {"type": "vless", "server": "de.example.net", "server_port": 443, "uuid": "u"}
    },
    {
      "id": "bbb222",
      "protocol": "hysteria2",
      "transport": "quic",
      "tag": "US-Hy2",
      "endpoint": {"host": "us.example.net", "port": 8443},
      "geo": {"country": "US", "flag": "\\ud83c\\uddfa\\ud83c\\uddf8"},
      "health": {"tcp_ok": false, "tls_ok": false, "ping_ms": null, "checked_at": "2026-09-05T15:00:00Z"},
      "lifetime": {"first_seen": "2026-09-05T00:00:00Z", "last_seen": "2026-09-05T15:00:00Z",
        "age_hours": 15, "class": "fresh", "seen_runs": 1, "stability": 0.1},
      "classification": {"security": "tls", "cdn": true, "ipv6": false, "udp": true},
      "provenance": {"source": "custom", "source_file": "", "imported": true, "raw_uri_sha1": "e"},
      "recommended": false,
      "raw_uri": "hysteria2://p@us.example.net:8443",
      "outbound": {"type": "hysteria2", "server": "us.example.net", "server_port": 8443, "password": "p"}
    }
  ]
}
''';

void main() {
  test('decodes a full pool', () {
    final pool = NodePool.decode(_poolJson);
    expect(pool.schemaVersion, 1);
    expect(pool.nodes, hasLength(2));
    expect(pool.stats.total, 2);
    expect(pool.stats.byCountry['DE'], 1);
  });

  test('maps enums and nested objects', () {
    final n = NodePool.decode(_poolJson).nodes.first;
    expect(n.classification.security, NodeSecurity.reality);
    expect(n.lifetime.klass, LifetimeClass.longLived);
    expect(n.lifetime.stability, closeTo(0.95, 1e-9));
    expect(n.geo.asOrg, 'Hetzner');
    expect(n.health.alive, isTrue);
    expect(n.recommended, isTrue);
    expect(n.isCustom, isFalse);
  });

  test('flags custom (imported) nodes and dead health', () {
    final n = NodePool.decode(_poolJson).nodes[1];
    expect(n.isCustom, isTrue);
    expect(n.health.alive, isFalse);
    expect(n.classification.udp, isTrue);
    expect(n.classification.cdn, isTrue);
    expect(n.health.pingMs, isNull);
  });

  test('degrades gracefully on malformed nodes', () {
    final pool = NodePool.fromJson({
      'nodes': [
        {'id': 'x'}, // almost everything missing
        'not a map',
        {'id': 'y', 'endpoint': {'host': 'h', 'port': '443'}},
      ],
    });
    expect(pool.nodes, hasLength(2));
    expect(pool.nodes[0].protocol, '');
    expect(pool.nodes[0].geo.country, isNull);
    expect(pool.nodes[1].endpoint.port, 443); // string port coerced
  });

  test('round-trips through toJson', () {
    final n = NodePool.decode(_poolJson).nodes.first;
    final again = Node.fromJson(n.toJson());
    expect(again.id, n.id);
    expect(again.classification.security, NodeSecurity.reality);
    expect(again.lifetime.klass, LifetimeClass.longLived);
    expect(again.outbound['type'], 'vless');
  });
}
