import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/data/custom_keys_repository.dart';
import 'package:weronity/domain/node.dart';
import 'package:weronity/state/bundles.dart';
import 'package:weronity/state/preflight.dart';
import 'package:weronity/state/providers.dart';

Node _node(String id, {int ping = 100, bool alive = true}) => Node(
      id: id,
      protocol: 'vless',
      transport: 'tcp',
      tag: id,
      endpoint: Endpoint(host: '$id.example', port: 443),
      geo: const Geo(country: 'US'),
      health: Health(tcpOk: alive, tlsOk: alive, pingMs: ping, checkedAt: null),
      lifetime: Lifetime.zero,
      classification: Classification.empty,
      provenance: Provenance.unknown,
      recommended: false,
      rawUri: '',
      outbound: const {'type': 'vless'},
    );

const _yt = 'https://www.youtube.com/favicon.ico';

NodeProbe _probe(String url, {required bool ok, int ms = 200}) => NodeProbe(
      verdict: ok ? ProbeVerdict.works : ProbeVerdict.blocked,
      bestMs: ok ? ms : null,
      hits: [
        ProbeHit(url: url, ok: ok, status: ok ? '204' : '', latencyMs: ms, blocked: !ok),
      ],
    );

void main() {
  test('bundleLiveNodes keeps auto order, sorts user bundles by ping', () {
    final nodes = [
      _node('a', ping: 300),
      _node('b', ping: 120),
      _node('c', alive: false),
    ];
    const auto =
        KeyBundle(id: 'auto:youtube', name: 'x', nodeIds: ['a', 'b', 'c']);
    expect(bundleLiveNodes(auto, nodes).map((n) => n.id), ['a', 'b']); // order kept, dead dropped

    const user = KeyBundle(id: 'b1', name: 'x', nodeIds: ['a', 'b', 'c']);
    expect(bundleLiveNodes(user, nodes).map((n) => n.id), ['b', 'a']); // by ping
  });

  test('autoBundlesProvider builds a per-service bundle ranked by probe latency',
      () async {
    final nodes = [_node('a'), _node('b'), _node('c')];
    final c = ProviderContainer(overrides: [
      nodesProvider.overrideWithValue(nodes),
    ]);
    addTearDown(c.dispose);

    expect(c.read(autoBundlesProvider), isEmpty); // nothing probed yet

    final pf = c.read(preflightProvider.notifier);
    pf.debugPut('a', _probe(_yt, ok: true, ms: 500));
    pf.debugPut('b', _probe(_yt, ok: true, ms: 120));
    pf.debugPut('c', _probe(_yt, ok: false));

    final bundles = c.read(autoBundlesProvider);
    expect(bundles, hasLength(1));
    expect(bundles.single.id, 'auto:youtube');
    expect(bundles.single.name, 'Лучшие для YouTube');
    expect(bundles.single.nodeIds, ['b', 'a']); // faster first, blocked excluded
  });

  test('blockedServiceForBundle maps auto ids back to the service', () {
    expect(blockedServiceForBundle('auto:youtube')?.name, 'YouTube');
    expect(blockedServiceForBundle('auto:nope'), isNull);
    expect(blockedServiceForBundle('b12345'), isNull);
  });
}
