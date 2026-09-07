import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:weronity/domain/node.dart';
import 'package:weronity/state/monitor.dart';
import 'package:weronity/state/preflight.dart';
import 'package:weronity/state/providers.dart';

class _FakeBox implements Box<dynamic> {
  final Map<dynamic, dynamic> _m = {};
  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      _m.containsKey(key) ? _m[key] : defaultValue;
  @override
  Future<void> put(dynamic key, dynamic value) async => _m[key] = value;
  @override
  Future<void> putAll(Map<dynamic, dynamic> e) async => _m.addAll(e);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Node _node(String id, {int ping = 100}) => Node(
      id: id,
      protocol: 'vless',
      transport: 'tcp',
      tag: id,
      endpoint: Endpoint(host: '$id.example', port: 443),
      geo: const Geo(country: 'DE'),
      health: Health(tcpOk: true, tlsOk: true, pingMs: ping, checkedAt: null),
      lifetime: Lifetime.zero,
      classification: Classification.empty,
      provenance: Provenance.unknown,
      recommended: false,
      rawUri: '',
      outbound: const {'type': 'vless'},
    );

ProviderContainer _container(List<Node> nodes, Node? ranked) => ProviderContainer(
      overrides: [
        sessionBoxProvider.overrideWithValue(_FakeBox()),
        settingsBoxProvider.overrideWithValue(_FakeBox()),
        nodesProvider.overrideWithValue(nodes),
        resolveSelectionProvider.overrideWithValue((_) => ranked),
      ],
    );

void main() {
  test('an empty pool yields no pick rather than an exception', () async {
    final c = _container(const [], null);
    addTearDown(c.dispose);
    expect(await c.read(autoConnectPickProvider)(), isNull);
  });

  // The whole point of 3.3b's pre-connect check: the collector's ping ranking
  // is not proof the node works from here, so a node we recently *proved* good
  // wins over the best-ranked one — and it does so without a scan, which is
  // what makes this path instant.
  test('a fresh good probe beats the ping-ranked node', () async {
    final ranked = _node('ranked', ping: 10);
    final proven = _node('proven', ping: 900);
    final c = _container([ranked, proven], ranked);
    addTearDown(c.dispose);

    c.read(preflightProvider.notifier).debugPut(
          'proven',
          NodeProbe(
            verdict: ProbeVerdict.works,
            bestMs: 300,
            at: DateTime.now(),
          ),
        );

    expect((await c.read(autoConnectPickProvider)())?.id, 'proven');
  });

  test('a stale good probe does not short-circuit the check', () async {
    final ranked = _node('ranked', ping: 10);
    final old = _node('old', ping: 900);
    final c = _container([ranked, old], ranked);
    addTearDown(c.dispose);

    c.read(preflightProvider.notifier).debugPut(
          'old',
          NodeProbe(
            verdict: ProbeVerdict.works,
            bestMs: 300,
            at: DateTime.now().subtract(const Duration(hours: 2)),
          ),
        );

    // Without a native core the scan cannot run, so it degrades to the ranking
    // rather than handing back a two-hour-old result as if it were current.
    final pick = await c.read(autoConnectPickProvider)();
    expect(pick?.id, isNot('old'));
  });

  test('the connect phase is null when nothing is in flight', () {
    final c = _container(const [], null);
    addTearDown(c.dispose);
    expect(c.read(connectPhaseProvider), isNull);
  });
}
