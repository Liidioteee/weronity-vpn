import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/domain/node.dart';
import 'package:weronity/state/candidates.dart';

Node _node(
  String id, {
  String country = 'DE',
  int? ping = 100,
  bool alive = true,
  bool recommended = false,
}) =>
    Node(
      id: id,
      protocol: 'vless',
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
      outbound: const {'type': 'vless'},
    );

void main() {
  test('backups are ordered same-country, then recommended, then the rest', () {
    final primary = _node('p', ping: 50);
    final pool = [
      primary,
      _node('far-slow', country: 'JP', ping: 400),
      _node('rec', country: 'JP', ping: 300, recommended: true),
      _node('near-slow', ping: 250),
      _node('near-fast', ping: 60),
    ];

    final got = backupCandidates(primary, pool, limit: 10).map((n) => n.id);
    expect(got, ['near-fast', 'near-slow', 'rec', 'far-slow']);
  });

  test('the primary and dead nodes never make the group', () {
    final primary = _node('p');
    final pool = [
      primary,
      _node('dead', alive: false),
      _node('live', ping: 10),
    ];
    expect(
      backupCandidates(primary, pool, limit: 10).map((n) => n.id),
      ['live'],
    );
  });

  // An unmeasured node is not a fast node — it must not push a known-good one
  // out of the group.
  test('nodes with no ping sort last within their tier', () {
    final primary = _node('p');
    final pool = [
      primary,
      _node('unknown', ping: null),
      _node('zero', ping: 0),
      _node('measured', ping: 900),
    ];
    final got = backupCandidates(primary, pool, limit: 10).map((n) => n.id);
    expect(got.first, 'measured');
    expect(got, containsAll(['unknown', 'zero']));
  });

  test('the group is capped at the limit', () {
    final primary = _node('p');
    final pool = [
      primary,
      for (var i = 0; i < 40; i++) _node('n$i', ping: i + 1),
    ];
    final got = backupCandidates(primary, pool, limit: 15);
    expect(got, hasLength(15));
    // The cap keeps the *best* ones, not an arbitrary slice.
    expect(got.first.id, 'n0');
    expect(got.last.id, 'n14');
  });

  test('an empty pool yields no backups rather than throwing', () {
    expect(backupCandidates(_node('p'), const [], limit: 15), isEmpty);
  });
}
