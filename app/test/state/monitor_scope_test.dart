import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/core/connection_controller.dart';
import 'package:weronity/data/custom_keys_repository.dart';
import 'package:weronity/domain/node.dart';
import 'package:weronity/state/candidates.dart';
import 'package:weronity/state/monitor.dart';

Node _node(
  String id, {
  String country = 'DE',
  int? ping = 100,
  bool alive = true,
  bool recommended = false,
  Map<String, dynamic>? outbound,
  String protocol = 'vless',
}) =>
    Node(
      id: id,
      protocol: protocol,
      transport: 'tcp',
      tag: id,
      endpoint: Endpoint(host: '$id.example', port: 443),
      geo: Geo(country: country),
      health: Health(tcpOk: alive, tlsOk: alive, pingMs: ping, checkedAt: null),
      lifetime: Lifetime.zero,
      classification: Classification.empty,
      provenance: Provenance.unknown,
      recommended: recommended,
      rawUri: '',
      outbound: outbound ??
          const {
            'type': 'vless',
            'tls': {'enabled': true},
          },
    );

Node? _lowestPing(Iterable<Node> nodes) => pickLowestPing(nodes);

Node? Function(Selection) _resolver(List<Node> nodes) => (sel) {
      if (sel.node != null) return sel.node;
      var pool = nodes.where((n) => n.health.alive);
      if (sel.countryCode != null) {
        pool = pool.where((n) => n.countryCode == sel.countryCode);
      }
      return _lowestPing(preferSecure(pool));
    };

void main() {
  final de1 = _node('de1', ping: 40);
  final de2 = _node('de2', ping: 90);
  final deDead = _node('deDead', alive: false);
  final nl1 = _node('nl1', country: 'NL', ping: 20, recommended: true);
  final us1 = _node('us1', country: 'US', ping: 150);
  final nodes = [de1, de2, deDead, nl1, us1];

  group('failoverScope', () {
    test('⚡ Авто may go anywhere: same country, then recommended, then rest',
        () {
      final scope =
          failoverScope(const Selection.auto(), de1, nodes, const []);
      expect([for (final n in scope) n.id], ['de2', 'nl1', 'us1']);
    });

    test('a chosen country is never left', () {
      final scope =
          failoverScope(const Selection.country('DE'), de1, nodes, const []);
      expect([for (final n in scope) n.id], ['de2']);
    });

    test('a country with no other live node yields nothing — not a neighbour',
        () {
      final scope =
          failoverScope(const Selection.country('NL'), nl1, nodes, const []);
      expect(scope, isEmpty);
    });

    test('an explicit node stays inside its own country', () {
      final scope = failoverScope(Selection.node(de1), de1, nodes, const []);
      expect([for (final n in scope) n.id], ['de2']);
    });

    test('a bundle stays inside the bundle, dead node excluded', () {
      const bundle = KeyBundle(
        id: 'b1',
        name: 'mine',
        nodeIds: ['us1', 'de1', 'deDead', 'nl1'],
      );
      final scope = failoverScope(
        const Selection.bundle('b1'),
        de1,
        nodes,
        const [bundle],
      );
      expect({for (final n in scope) n.id}, {'us1', 'nl1'});
    });

    test('an unknown bundle yields nothing', () {
      expect(
        failoverScope(const Selection.bundle('gone'), de1, nodes, const []),
        isEmpty,
      );
    });
  });

  test('failover backoff grows and is capped at two minutes', () {
    expect(failoverBackoff(1), const Duration(seconds: 15));
    expect(failoverBackoff(2), const Duration(seconds: 30));
    expect(failoverBackoff(3), const Duration(seconds: 60));
    expect(failoverBackoff(4), const Duration(seconds: 120));
    expect(failoverBackoff(40), const Duration(seconds: 120));
  });

  group('connectCandidates / idleCheckScope', () {
    final resolve = _resolver(nodes);

    test('an explicit node has nothing to pick from', () {
      expect(
        connectCandidates(Selection.node(de1), nodes, const [], resolve),
        isEmpty,
      );
    });

    test('a country selection only offers that country, best first', () {
      final c = connectCandidates(
        const Selection.country('DE'),
        nodes,
        const [],
        resolve,
      );
      expect([for (final n in c) n.id], ['de1', 'de2']);
    });

    test('⚡ Авто starts with the ranked node and never offers a dead one', () {
      final c =
          connectCandidates(const Selection.auto(), nodes, const [], resolve);
      expect(c.first.id, 'nl1'); // lowest ping overall
      expect([for (final n in c) n.id], isNot(contains('deDead')));
    });

    test('the idle scope is the next connect, not the whole pool', () {
      final scope = idleCheckScope(
        const Selection.country('DE'),
        nodes,
        const [],
        resolve,
        lastGoodNodeId: 'us1',
      );
      // the country's candidates + the node that worked last time
      expect({for (final n in scope) n.id}, {'de1', 'de2', 'us1'});
    });

    test('an explicit node is itself in the idle scope', () {
      final scope =
          idleCheckScope(Selection.node(us1), nodes, const [], resolve);
      expect([for (final n in scope) n.id], ['us1']);
    });
  });

  group('lastGoodNodeFor', () {
    test('⚡ Авто accepts any live node', () {
      expect(lastGoodNodeFor(const Selection.auto(), 'us1', nodes)?.id, 'us1');
    });

    test('a dead or unknown node is not offered', () {
      expect(lastGoodNodeFor(const Selection.auto(), 'deDead', nodes), isNull);
      expect(lastGoodNodeFor(const Selection.auto(), 'nope', nodes), isNull);
      expect(lastGoodNodeFor(const Selection.auto(), null, nodes), isNull);
    });

    test('a country only accepts a node of that country', () {
      expect(
        lastGoodNodeFor(const Selection.country('DE'), 'de2', nodes)?.id,
        'de2',
      );
      expect(
        lastGoodNodeFor(const Selection.country('DE'), 'us1', nodes),
        isNull,
      );
    });

    test('a bundle or an explicit node is left alone', () {
      expect(lastGoodNodeFor(const Selection.bundle('b'), 'de1', nodes), isNull);
      expect(lastGoodNodeFor(Selection.node(us1), 'de1', nodes), isNull);
    });
  });

  group('encryption preference', () {
    final plain = _node(
      'plain',
      ping: 5,
      outbound: const {'type': 'vless'}, // vless without tls = plaintext hop
    );
    final unverified = _node(
      'unverified',
      ping: 6,
      outbound: const {
        'type': 'vless',
        'tls': {'enabled': true, 'insecure': true},
      },
    );
    final secure = _node('secure', ping: 300);

    test('preferSecure keeps only encrypted nodes when there are any', () {
      expect(
        [for (final n in preferSecure([plain, unverified, secure])) n.id],
        ['secure'],
      );
    });

    test('…and falls back to the rest when there are none', () {
      expect(preferSecure([plain, unverified]).length, 2);
    });

    test('backups rank an encrypted node above a faster unencrypted one', () {
      final primary = _node('primary');
      final backups = backupCandidates(
        primary,
        [primary, plain, unverified, secure],
        limit: 10,
      );
      expect(backups.first.id, 'secure');
    });
  });
}
