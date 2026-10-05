import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weronity/core/connection_controller.dart';
import 'package:weronity/data/custom_keys_repository.dart';
import 'package:weronity/data/geoip_service.dart';
import 'package:weronity/data/pool_repository.dart';
import 'package:weronity/data/settings_repository.dart';
import 'package:weronity/domain/node.dart';
import 'package:weronity/state/custom_keys.dart';
import 'package:weronity/state/preflight.dart';
import 'package:weronity/state/providers.dart';

/// Regression tests for the code-review fixes that do not fit an existing file.

class _FakeBox<T> implements Box<T> {
  final Map<dynamic, T> m = {};
  @override
  T? get(dynamic key, {T? defaultValue}) =>
      m.containsKey(key) ? m[key] : defaultValue;
  @override
  Future<void> put(dynamic key, T value) async => m[key] = value;
  @override
  Future<void> putAll(Map<dynamic, T> e) async => m.addAll(e);
  @override
  Future<void> delete(dynamic key) async => m.remove(key);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Node _node(String id, {String country = 'DE'}) => Node(
      id: id,
      protocol: 'vless',
      transport: 'tcp',
      tag: id,
      endpoint: Endpoint(host: '$id.example', port: 443),
      geo: Geo(country: country),
      health: const Health(tcpOk: true, tlsOk: true, pingMs: 50, checkedAt: null),
      lifetime: Lifetime.zero,
      classification: Classification.empty,
      provenance: Provenance.unknown,
      recommended: false,
      rawUri: '',
      outbound: const {
        'type': 'vless',
        'tls': {'enabled': true},
      },
    );

String _poolJson(int nodes) => jsonEncode({
      'schema_version': 1,
      'generated_at': '2026-10-01T00:00:00Z',
      'generator': 'test',
      'stats': {'total': nodes},
      'nodes': [
        for (var i = 0; i < nodes; i++)
          {
            'id': 'n$i',
            'protocol': 'vless',
            'transport': 'tcp',
            'tag': 'n$i',
            'endpoint': {'host': 'h$i.example', 'port': 443},
            'health': {'tcp_ok': true},
            'outbound': {'type': 'vless'},
          },
      ],
    });

class _ThrowingRepo implements CustomKeysRepository {
  @override
  Future<List<CustomKey>> loadKeys() async => [];
  @override
  Future<List<Subscription>> loadSubs() async => [];
  @override
  Future<List<KeyBundle>> loadBundles() async => [];
  @override
  Future<void> saveKeys(List<CustomKey> k) async =>
      throw KeyStorageException('no keyring');
  @override
  Future<void> saveSubs(List<Subscription> s) async =>
      throw KeyStorageException('no keyring');
  @override
  Future<void> saveBundles(List<KeyBundle> b) async =>
      throw KeyStorageException('no keyring');
}

/// Saves slowly, so overlapping mutations really do overlap.
class _SlowRepo implements CustomKeysRepository {
  List<CustomKey> keys = [];
  @override
  Future<List<CustomKey>> loadKeys() async => keys;
  @override
  Future<List<Subscription>> loadSubs() async => [];
  @override
  Future<List<KeyBundle>> loadBundles() async => [];
  @override
  Future<void> saveKeys(List<CustomKey> k) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    keys = k;
  }

  @override
  Future<void> saveSubs(List<Subscription> s) async {}
  @override
  Future<void> saveBundles(List<KeyBundle> b) async {}
}

ProviderContainer _keysContainer(CustomKeysRepository repo) =>
    ProviderContainer(
      overrides: [
        customKeysRepositoryProvider.overrideWithValue(repo),
        geoIpServiceProvider.overrideWith(
          (ref) => Future<GeoIpService>.error(StateError('no geoip in tests')),
        ),
      ],
    );

const _key1 = 'trojan://pw1@a.example.net:443?security=tls#A';
const _key2 = 'trojan://pw2@b.example.net:443?security=tls#B';

void main() {
  group('session restore', () {
    ProviderContainer container(_FakeBox<dynamic> session, List<Node> nodes) =>
        ProviderContainer(
          overrides: [
            sessionBoxProvider.overrideWithValue(session),
            settingsBoxProvider.overrideWithValue(_FakeBox<dynamic>()),
            nodesProvider.overrideWithValue(nodes),
            resolveSelectionProvider.overrideWithValue((_) => null),
          ],
        );

    test('the saved location is re-applied on every start, not just the first',
        () async {
      final session = _FakeBox<dynamic>()
        ..m['selection'] = {'k': 'country', 'v': 'NL'};
      final nodes = [_node('a'), _node('b', country: 'NL')];

      for (var run = 1; run <= 3; run++) {
        final c = container(session, nodes);
        c.read(sessionRestoreProvider);
        await pumpEventQueue();
        expect(
          c.read(connectionControllerProvider).selection.countryCode,
          'NL',
          reason: 'start #$run',
        );
        c.dispose();
      }
    });

    test('a flag left behind by an older build no longer blocks the restore',
        () async {
      final session = _FakeBox<dynamic>()
        ..m['selection'] = {'k': 'country', 'v': 'NL'}
        ..m['selection.restored'] = true;
      final c = container(session, [_node('b', country: 'NL')]);
      addTearDown(c.dispose);

      c.read(sessionRestoreProvider);
      await pumpEventQueue();

      expect(c.read(connectionControllerProvider).selection.countryCode, 'NL');
      expect(session.m.containsKey('selection.restored'), isFalse);
    });
  });

  group('engines', () {
    test('without the core a release build refuses to connect', () async {
      final log = <String>[];
      final e = UnavailableEngine(
        reason: 'dll missing',
        onLog: (l, t, m) => log.add('$l: $m'),
      );
      addTearDown(e.dispose);

      await e.connect((_) => _node('a'));

      expect(e.status, ConnectionStatus.error);
      expect(e.isActive, isFalse);
      expect(e.activeNode, isNull);
      expect(e.lastError, contains('не загружено'));
      expect(log.single, contains('dll missing'));
      expect(await e.switchTo(_node('b')), isFalse);
    });

    test('switchTo moves the session but keeps the selection', () async {
      final c = ConnectionController();
      addTearDown(c.dispose);
      await c.select(const Selection.country('DE'), (_) => null);
      await c.connect((_) => _node('a'));
      expect(c.activeNode?.id, 'a');

      expect(await c.switchTo(_node('b')), isTrue);

      expect(c.activeNode?.id, 'b');
      expect(c.selection.countryCode, 'DE', reason: 'the user chose a country');
      expect(c.selection.node, isNull);
    });

    test('switchTo without a session does nothing', () async {
      final c = ConnectionController();
      addTearDown(c.dispose);
      expect(await c.switchTo(_node('b')), isFalse);
      expect(c.status, ConnectionStatus.disconnected);
    });
  });

  group('hop security', () {
    Node withOutbound(String protocol, Map<String, dynamic> ob) => Node(
          id: 'x',
          protocol: protocol,
          transport: 'tcp',
          tag: 'x',
          endpoint: const Endpoint(host: 'h', port: 1),
          geo: Geo.unknown,
          health:
              const Health(tcpOk: true, tlsOk: false, pingMs: 1, checkedAt: null),
          lifetime: Lifetime.zero,
          classification: Classification.empty,
          provenance: Provenance.unknown,
          recommended: false,
          rawUri: '',
          outbound: ob,
        );

    test('TLS with a verified certificate is encrypted', () {
      final n = withOutbound('vless', const {
        'tls': {'enabled': true},
      });
      expect(n.hopSecurity, HopSecurity.encrypted);
      expect(n.isHopSecure, isTrue);
    });

    test('allowInsecure is flagged', () {
      final n = withOutbound('trojan', const {
        'tls': {'enabled': true, 'insecure': true},
      });
      expect(n.hopSecurity, HopSecurity.unverified);
      expect(n.isHopSecure, isFalse);
    });

    test('vless / trojan without TLS are plaintext', () {
      expect(withOutbound('vless', const {}).hopSecurity, HopSecurity.plaintext);
      expect(
          withOutbound('trojan', const {}).hopSecurity, HopSecurity.plaintext);
    });

    test('shadowsocks and vmess carry their own cipher — unless it is "none"',
        () {
      expect(
        withOutbound('shadowsocks', const {'method': 'aes-256-gcm'}).hopSecurity,
        HopSecurity.encrypted,
      );
      expect(
        withOutbound('shadowsocks', const {'method': 'none'}).hopSecurity,
        HopSecurity.plaintext,
      );
      expect(
        withOutbound('vmess', const {'security': 'auto'}).hopSecurity,
        HopSecurity.encrypted,
      );
      expect(
        withOutbound('vmess', const {'security': 'none'}).hopSecurity,
        HopSecurity.plaintext,
      );
    });
  });

  group('settings', () {
    test('a damaged box falls back to defaults instead of throwing', () {
      final box = _FakeBox<dynamic>()
        ..m.addAll({
          'proMode': 'yes', // wrong type
          'themeMode': 99, // out of range
          'routingMode': -1,
          'proxyPort': 'abc',
          'checkConcurrency': null,
          'directRules': 'not a list',
          'preflightEndpoints': [1, 'https://ok.example', null],
          'autoCheck': 0,
        });

      final s = SettingsRepository(box).load();

      const d = Settings();
      expect(s.proMode, d.proMode);
      expect(s.themeMode, d.themeMode);
      expect(s.routingMode, d.routingMode);
      expect(s.proxyPort, d.proxyPort);
      expect(s.checkConcurrency, d.checkConcurrency);
      expect(s.directRules, isEmpty);
      expect(s.preflightEndpoints, ['https://ok.example']);
      expect(s.autoCheck, d.autoCheck);
    });
  });

  group('pool repository', () {
    PoolRepository repo(_FakeBox<String> cache, String body) => PoolRepository(
          cacheBox: cache,
          client: MockClient((_) async => http.Response.bytes(
                utf8.encode(body),
                200,
              )),
        );

    test('an empty pool from the network never replaces a good cache',
        () async {
      final cache = _FakeBox<String>()..m['pool.json'] = _poolJson(3);
      final snap = await repo(cache, _poolJson(0)).refresh();

      expect(snap.origin, PoolOrigin.cache);
      expect(snap.pool.nodes, hasLength(3));
      expect(NodePool.decode(cache.m['pool.json']!).nodes, hasLength(3));
    });

    test('a real pool is cached', () async {
      final cache = _FakeBox<String>();
      final snap = await repo(cache, _poolJson(2)).refresh();

      expect(snap.origin, PoolOrigin.network);
      expect(snap.pool.nodes, hasLength(2));
      expect(cache.m.containsKey('pool.json'), isTrue);
    });
  });

  group('custom keys', () {
    test('a failed write to the secure store is surfaced, not swallowed',
        () async {
      final c = _keysContainer(_ThrowingRepo());
      addTearDown(c.dispose);
      await c.read(customKeysProvider.future);

      final r = await c.read(customKeysProvider.notifier).addFromText(_key1);

      expect(r.added, 1);
      final data = c.read(customKeysProvider).requireValue;
      expect(data.keys, hasLength(1), reason: 'still usable this session');
      expect(data.storageError, isNotNull);
    });

    test('overlapping mutations do not undo each other', () async {
      final repo = _SlowRepo();
      final c = _keysContainer(repo);
      addTearDown(c.dispose);
      await c.read(customKeysProvider.future);
      final notifier = c.read(customKeysProvider.notifier);

      // Both start before either has saved.
      await Future.wait([
        notifier.addFromText(_key1),
        notifier.addFromText(_key2),
      ]);

      expect(c.read(customKeysProvider).requireValue.keys, hasLength(2));
      expect(repo.keys, hasLength(2));
    });
  });

  group('preflight', () {
    ProviderContainer container() => ProviderContainer(
          overrides: [
            sessionBoxProvider.overrideWithValue(_FakeBox<dynamic>()),
            settingsBoxProvider.overrideWithValue(_FakeBox<dynamic>()),
          ],
        );

    ProbeHit hit(String url) => ProbeHit(
          url: url,
          ok: true,
          status: '204',
          latencyMs: 100,
          blocked: false,
        );

    test('a quick check keeps the per-service hits of an older full probe', () {
      final quick = NodeProbe(
        verdict: ProbeVerdict.works,
        bestMs: 80,
        at: DateTime.now(),
        hits: [hit('https://www.google.com/generate_204')],
      );
      final merged = quick.withOlderHits([
        hit('https://www.google.com/generate_204'),
        hit('https://www.youtube.com/favicon.ico'),
      ]);

      expect(merged.verdict, ProbeVerdict.works);
      expect(merged.bestMs, 80);
      expect([for (final h in merged.hits) h.url], [
        'https://www.google.com/generate_204',
        'https://www.youtube.com/favicon.ico',
      ]);
    });

    test('a burst scan returns a fresh known-good node without waiting',
        () async {
      final c = container();
      addTearDown(c.dispose);
      c.read(preflightProvider.notifier).debugPut(
            'good',
            NodeProbe(verdict: ProbeVerdict.works, bestMs: 120, at: DateTime.now()),
          );

      final found = await c
          .read(preflightProvider.notifier)
          .burstFindGood(['bad', 'good'], const {})
          .timeout(const Duration(seconds: 1));

      expect(found, 'good');
    });

    test('a node that failed in real use stops counting as known-good',
        () async {
      final c = container();
      addTearDown(c.dispose);
      final pf = c.read(preflightProvider.notifier);
      pf.debugPut(
        'a',
        NodeProbe(verdict: ProbeVerdict.works, bestMs: 90, at: DateTime.now()),
      );

      pf.markDead('a');

      expect(c.read(preflightProvider)['a']!.isGood, isFalse);
      final found = await pf
          .burstFindGood(['a'], const {})
          .timeout(const Duration(seconds: 1));
      expect(found, isNull);
    });

    test('a burst scan over nothing completes with null', () async {
      final c = container();
      addTearDown(c.dispose);
      final found = await c
          .read(preflightProvider.notifier)
          .burstFindGood(const [], const {})
          .timeout(const Duration(seconds: 1));
      expect(found, isNull);
    });
  });
}
