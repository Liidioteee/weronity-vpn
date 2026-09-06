import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:weronity/core/connection_controller.dart';
import 'package:weronity/domain/node.dart';
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
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test('NodeProbe survives a JSON round-trip; testing downgrades to untested',
      () {
    const p = NodeProbe(
      verdict: ProbeVerdict.slow,
      bestMs: 1300,
      hits: [
        ProbeHit(
            url: 'https://x/', ok: true, status: '204', latencyMs: 1300, blocked: false),
        ProbeHit(url: 'https://y/', ok: false, status: '', latencyMs: 0, blocked: true),
      ],
    );
    final back = NodeProbe.fromJson(p.toJson());
    expect(back.verdict, ProbeVerdict.slow);
    expect(back.bestMs, 1300);
    expect(back.hits, hasLength(2));
    expect(back.hitFor('https://x/')?.ok, isTrue);

    final wasTesting = NodeProbe.fromJson(NodeProbe.testing.toJson());
    expect(wasTesting.verdict, ProbeVerdict.untested);
  });

  test('PreflightNotifier loads cached results from the session box', () {
    final box = _FakeBox();
    box._m['preflight.v1'] = {
      'n1': const NodeProbe(verdict: ProbeVerdict.works, bestMs: 200).toJson(),
      'n2': const NodeProbe(verdict: ProbeVerdict.dead).toJson(),
    };
    final c = ProviderContainer(
      overrides: [sessionBoxProvider.overrideWithValue(box)],
    );
    addTearDown(c.dispose);

    final state = c.read(preflightProvider);
    expect(state['n1']?.verdict, ProbeVerdict.works);
    expect(state['n1']?.bestMs, 200);
    expect(state['n2']?.verdict, ProbeVerdict.dead);
  });

  test('burstFindGood returns an already-known fresh good node immediately', () async {
    final box = _FakeBox();
    final c = ProviderContainer(
      overrides: [sessionBoxProvider.overrideWithValue(box)],
    );
    addTearDown(c.dispose);
    final n = c.read(preflightProvider.notifier);
    n.debugPut(
      'n2',
      NodeProbe(
          verdict: ProbeVerdict.works, bestMs: 150, at: DateTime.now()),
    );
    n.debugPut(
      'n1',
      NodeProbe(
          verdict: ProbeVerdict.works, bestMs: 900, at: DateTime.now()),
    );

    final id = await n.burstFindGood(
      ['n1', 'n2', 'n3'],
      const {'n1': {}, 'n2': {}, 'n3': {}},
    );
    // first fresh-good in the candidate order wins (n1 before n2 here)
    expect(id, 'n1');
  });

  test('staleAmong flags never-checked and old ids', () {
    final box = _FakeBox();
    final c = ProviderContainer(
      overrides: [sessionBoxProvider.overrideWithValue(box)],
    );
    addTearDown(c.dispose);
    final n = c.read(preflightProvider.notifier);
    n.debugPut(
      'fresh',
      NodeProbe(verdict: ProbeVerdict.works, at: DateTime.now()),
    );
    n.debugPut(
      'old',
      NodeProbe(
        verdict: ProbeVerdict.works,
        at: DateTime.now().subtract(const Duration(hours: 2)),
      ),
    );
    final stale =
        n.staleAmong(['fresh', 'old', 'never'], const Duration(minutes: 10));
    expect(stale.toSet(), {'old', 'never'});
  });

  test('selectionToJson / selectionFromJson round-trip', () {
    const n = Node(
      id: 'abc',
      protocol: 'vless',
      transport: 'tcp',
      tag: 'abc',
      endpoint: Endpoint(host: 'h', port: 1),
      geo: Geo.unknown,
      health: Health(tcpOk: true, tlsOk: true, pingMs: 1, checkedAt: null),
      lifetime: Lifetime.zero,
      classification: Classification.empty,
      provenance: Provenance.unknown,
      recommended: false,
      rawUri: '',
      outbound: {},
    );
    expect(selectionFromJson(selectionToJson(const Selection.auto()), []).isAuto,
        isTrue);
    expect(
        selectionFromJson(selectionToJson(const Selection.country('DE')), [])
            .countryCode,
        'DE');
    expect(
        selectionFromJson(selectionToJson(const Selection.bundle('b1')), [])
            .bundleId,
        'b1');
    expect(selectionFromJson(selectionToJson(const Selection.node(n)), [n]).node?.id,
        'abc');
    // node id that no longer exists → auto
    expect(selectionFromJson(selectionToJson(const Selection.node(n)), []).isAuto,
        isTrue);
  });
}
