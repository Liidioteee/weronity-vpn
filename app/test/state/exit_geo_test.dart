import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:weronity/core/connection_controller.dart';
import 'package:weronity/domain/node.dart';
import 'package:weronity/state/exit_geo.dart';
import 'package:weronity/state/monitor.dart';
import 'package:weronity/state/preflight.dart';
import 'package:weronity/state/providers.dart';

/// A node's listed country is a GeoIP guess about its entry address; these
/// tests cover replacing it with the country its traffic was *seen* to exit in.

class _FakeBox implements Box<dynamic> {
  final Map<dynamic, dynamic> m = {};
  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      m.containsKey(key) ? m[key] : defaultValue;
  @override
  Future<void> put(dynamic key, dynamic value) async => m[key] = value;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Node _node(String id, {String country = 'US', int ping = 50}) => Node(
      id: id,
      protocol: 'vless',
      transport: 'tcp',
      tag: id,
      endpoint: Endpoint(host: '$id.example', port: 443),
      geo: Geo(country: country, asn: 30058, asOrg: 'FDCservers.net'),
      health: Health(tcpOk: true, tlsOk: true, pingMs: ping, checkedAt: null),
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

ProviderContainer _container([_FakeBox? session]) => ProviderContainer(
      overrides: [
        sessionBoxProvider.overrideWithValue(session ?? _FakeBox()),
        settingsBoxProvider.overrideWithValue(_FakeBox()),
      ],
    );

void main() {
  group('parseTraceCountry', () {
    test('reads the loc line of a real trace body', () {
      const body = 'fl=123abc\nh=www.cloudflare.com\nip=50.7.120.162\n'
          'ts=1.5\ncolo=AMS\nloc=NL\ntls=TLSv1.3\n';
      expect(parseTraceCountry(body), 'NL');
    });

    test('normalises case and line endings', () {
      expect(parseTraceCountry('ip=1.2.3.4\r\nloc=de\r\n'), 'DE');
    });

    test('anything that is not a country is "could not tell"', () {
      expect(parseTraceCountry('colo=AMS\n'), isNull);
      expect(parseTraceCountry('loc=XX\n'), isNull); // unknown
      expect(parseTraceCountry('loc=T1\n'), isNull); // Tor
      expect(parseTraceCountry('loc=NLD\n'), isNull);
      expect(parseTraceCountry('<html>blocked</html>'), isNull);
      expect(parseTraceCountry(''), isNull);
    });
  });

  group('withExitCountry', () {
    test('a seen exit country replaces the listed one', () {
      final fixed = withExitCountry(_node('a'), 'NL');
      expect(fixed.countryCode, 'NL');
      expect(fixed.geo.countryName, isNotEmpty);
      expect(fixed.geo.asn, 30058, reason: 'the ASN still describes the entry');
      expect(fixed.id, 'a');
    });

    test('no observation, or one that agrees, leaves the node as it is', () {
      final n = _node('a');
      expect(identical(withExitCountry(n, null), n), isTrue);
      expect(identical(withExitCountry(n, 'US'), n), isTrue);
    });
  });

  group('ExitGeoNotifier', () {
    test('records country codes and ignores "could not tell"', () {
      final c = _container();
      addTearDown(c.dispose);
      final geo = c.read(exitGeoProvider.notifier);

      geo.record('a', 'nl');
      geo.record('b', null);
      geo.record('c', '');
      geo.record('d', 'XXX');
      expect(c.read(exitGeoProvider), {'a': 'NL'});

      // A later failed lookup must not erase what was established…
      geo.record('a', null);
      expect(c.read(exitGeoProvider)['a'], 'NL');
      // …but a different answer replaces it.
      geo.record('a', 'DE');
      expect(c.read(exitGeoProvider)['a'], 'DE');
    });

    test('survives a restart and drops entries older than a week', () async {
      final box = _FakeBox();
      final first = _container(box);
      first.read(exitGeoProvider.notifier).record('a', 'NL');
      await Future<void>.delayed(const Duration(milliseconds: 2200)); // debounce
      first.dispose();
      expect((box.m['exitgeo.v1'] as Map)['a']['c'], 'NL');

      box.m['exitgeo.v1'] = <dynamic, dynamic>{
        ...box.m['exitgeo.v1'] as Map,
        'old': {
          'c': 'FR',
          'at': DateTime.now()
              .subtract(const Duration(days: 30))
              .toIso8601String(),
        },
        'junk': 'not a map',
      };

      final second = _container(box);
      addTearDown(second.dispose);
      expect(second.read(exitGeoProvider), {'a': 'NL'});
    });
  });

  group('a chosen country means the exit country', () {
    // Two nodes listed as US; one of them really exits in the Netherlands —
    // the case from the bug report (an FDCservers box in Amsterdam).
    final listed = [
      _node('us-real', ping: 80),
      _node('us-fake', ping: 10),
      _node('nl', country: 'NL', ping: 30),
    ];
    List<Node> corrected(Map<String, String> exits) =>
        [for (final n in listed) withExitCountry(n, exits[n.id])];

    test('a relabelled node leaves the country it was listed in', () {
      final nodes = corrected({'us-fake': 'NL'});
      final scope = failoverScope(
        const Selection.country('US'),
        nodes.firstWhere((n) => n.id == 'us-fake'), // the session's node
        nodes,
        const [],
      );
      expect([for (final n in scope) n.id], ['us-real']);

      // …and it now belongs to the country it really exits in.
      final nl = failoverScope(
        const Selection.country('NL'),
        nodes.firstWhere((n) => n.id == 'nl'),
        nodes,
        const [],
      );
      expect([for (final n in nl) n.id], ['us-fake']);
    });

    test('a working node in the wrong country does not win a scan', () async {
      final c = _container();
      addTearDown(c.dispose);
      final pf = c.read(preflightProvider.notifier);
      final geo = c.read(exitGeoProvider.notifier);
      NodeProbe good(int ms) =>
          NodeProbe(verdict: ProbeVerdict.works, bestMs: ms, at: DateTime.now());

      // Both answered; the faster one was seen exiting in NL.
      pf.debugPut('us-fake', good(20));
      pf.debugPut('us-real', good(200));
      geo.record('us-fake', 'NL');
      geo.record('us-real', 'US');

      bool exitsInUs(String id) => c.read(exitGeoProvider)[id] == 'US';

      final found = await pf
          .burstFindGood(['us-fake', 'us-real'], const {}, accept: exitsInUs)
          .timeout(const Duration(seconds: 1));
      expect(found, 'us-real');

      // Without the condition the first working node wins, as before.
      final any = await pf
          .burstFindGood(['us-fake', 'us-real'], const {})
          .timeout(const Duration(seconds: 1));
      expect(any, 'us-fake');
    });

    test('no node exits in the chosen country → the scan finds nothing',
        () async {
      final c = _container();
      addTearDown(c.dispose);
      final pf = c.read(preflightProvider.notifier);
      pf.debugPut(
        'us-fake',
        NodeProbe(verdict: ProbeVerdict.works, bestMs: 20, at: DateTime.now()),
      );
      c.read(exitGeoProvider.notifier).record('us-fake', 'NL');

      final found = await pf
          .burstFindGood(
            ['us-fake'],
            const {},
            accept: (id) => c.read(exitGeoProvider)[id] == 'US',
          )
          .timeout(const Duration(seconds: 1));
      expect(found, isNull);
    });
  });

  test('the session re-checks its exit every few minutes', () {
    expect(exitCheckInterval, lessThanOrEqualTo(const Duration(minutes: 5)));
    expect(exitCheckInterval, greaterThanOrEqualTo(livenessInterval));
  });
}
