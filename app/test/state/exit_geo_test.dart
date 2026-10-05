import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:weronity/core/connection_controller.dart';
import 'package:weronity/data/geoip_service.dart';
import 'package:weronity/domain/node.dart';
import 'package:weronity/state/exit_geo.dart';
import 'package:weronity/state/monitor.dart';
import 'package:weronity/state/preflight.dart';
import 'package:weronity/state/providers.dart';

/// A node's listed country is a GeoIP guess about its entry address; these
/// tests cover replacing it with the country its traffic was *seen* to exit in
/// — and not promising a country the geolocation sources cannot agree on.

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

const _us = ExitGeo(country: 'US', sources: 3);
const _nl = ExitGeo(country: 'NL', sources: 3);

void main() {
  group('reading the sources', () {
    const trace = 'fl=123abc\nh=www.cloudflare.com\nip=45.207.207.25\n'
        'ts=1.5\ncolo=LAX\nloc=US\ntls=TLSv1.3\n';

    test('country and address from a trace body', () {
      expect(parseTraceCountry(trace), 'US');
      expect(parseTraceIp(trace), '45.207.207.25');
      expect(parseTraceCountry('ip=1.2.3.4\r\nloc=de\r\n'), 'DE');
    });

    test('anything that is not a country is "could not tell"', () {
      expect(parseTraceCountry('colo=AMS\n'), isNull);
      expect(parseTraceCountry('loc=XX\n'), isNull); // unknown
      expect(parseTraceCountry('loc=T1\n'), isNull); // Tor
      expect(parseTraceCountry('loc=NLD\n'), isNull);
      expect(parseTraceCountry('<html>blocked</html>'), isNull);
      expect(parseTraceCountry(''), isNull);
      expect(parseTraceIp('loc=US\n'), isNull);
    });

    test('the second opinion', () {
      expect(parseCountryIs('{"ip":"45.207.207.25","country":"SC"}'), 'SC');
      expect(parseCountryIs('{"ip":"1.2.3.4","country":"us"}'), 'US');
      expect(parseCountryIs('{"ip":"1.2.3.4"}'), isNull);
      expect(parseCountryIs('{"country":"XX"}'), isNull);
      expect(parseCountryIs('<html>rate limited</html>'), isNull);
      expect(parseCountryIs(''), isNull);
    });

    test('the bundled table gives a third opinion for an IPv4 exit', () {
      final table = GeoIpService.parseBytes(
        File('assets/geoip/ipv4_country.v2.bin').readAsBytesSync(),
      );
      expect(offlineCountry(table, '45.207.207.25'), 'US');
      expect(offlineCountry(table, '2a00:1450:4001::1'), isNull); // IPv6
      expect(offlineCountry(table, null), isNull);
      expect(offlineCountry(null, '8.8.8.8'), isNull);
    });
  });

  group('ExitGeo.fromOpinions', () {
    test('sources that agree confirm the country', () {
      final g = ExitGeo.fromOpinions(['US', 'us', 'US'])!;
      expect(g.country, 'US');
      expect(g.disputed, isFalse);
      expect(g.confirmed, isTrue);
      expect(g.confirms('US'), isTrue);
      expect(g.confirms('NL'), isFalse);
    });

    // The reported case: a Los Angeles server on address space leased from a
    // Seychelles-registered owner. Two databases say US, the one most websites
    // use says SC — the user cannot be promised "США".
    test('sources that disagree make the country disputed', () {
      final g = ExitGeo.fromOpinions(['US', 'SC', 'US'])!;
      expect(g.country, 'US', reason: 'the majority');
      expect(g.disputedWith, 'SC');
      expect(g.disputed, isTrue);
      expect(g.confirmed, isFalse);
      expect(g.confirms('US'), isFalse);
    });

    test('a tie goes to the source asked first', () {
      final g = ExitGeo.fromOpinions(['US', 'SC'])!;
      expect(g.country, 'US');
      expect(g.disputedWith, 'SC');
    });

    test('one source alone is an answer, but not a confirmation', () {
      final g = ExitGeo.fromOpinions(['NL', null, 'XX'])!;
      expect(g.country, 'NL');
      expect(g.sources, 1);
      expect(g.disputed, isFalse);
      expect(g.confirmed, isFalse, reason: 'no green mark on a single source');
      expect(g.confirms('NL'), isTrue, reason: 'still usable to pick a node');
    });

    test('nobody answered → nothing to say', () {
      expect(ExitGeo.fromOpinions([null, '', 'XX', 'T1', 'NLD']), isNull);
      expect(ExitGeo.fromOpinions(const []), isNull);
    });

    test('a probe summary adds up to the same picture', () {
      final table = GeoIpService.parseBytes(
        File('assets/geoip/ipv4_country.v2.bin').readAsBytesSync(),
      );
      final g = exitGeoFromProbe(
        {
          'exit_country': 'US',
          'exit_country_alt': 'SC',
          'exit_ip': '45.207.207.25',
        },
        table,
      )!;
      expect(g.country, 'US');
      expect(g.disputedWith, 'SC');
      expect(g.sources, 3);
      expect(exitGeoFromProbe({'ok': true}, table), isNull);
      expect(exitGeoFromProbe(null, table), isNull);
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
    test('records observations and ignores "could not tell"', () {
      final c = _container();
      addTearDown(c.dispose);
      final geo = c.read(exitGeoProvider.notifier);

      geo.record('a', _nl);
      geo.record('b', null);
      expect(c.read(exitGeoProvider), {'a': _nl});

      // A later failed lookup must not erase what was established…
      geo.record('a', null);
      expect(c.read(exitGeoProvider)['a'], _nl);
      // …but a different answer replaces it.
      geo.record('a', const ExitGeo(country: 'DE', sources: 2));
      expect(c.read(exitGeoProvider)['a']!.country, 'DE');
    });

    test('a poorer look at the same country does not hide a known dispute', () {
      final c = _container();
      addTearDown(c.dispose);
      final geo = c.read(exitGeoProvider.notifier);
      const disputed = ExitGeo(country: 'US', disputedWith: 'SC', sources: 3);

      geo.record('a', disputed);
      // Next time the second source did not answer: one voice, "US".
      geo.record('a', const ExitGeo(country: 'US'));

      expect(c.read(exitGeoProvider)['a'], disputed);
    });

    test('survives a restart and drops entries older than a week', () async {
      final box = _FakeBox();
      final first = _container(box);
      first.read(exitGeoProvider.notifier)
        ..record('a', _nl)
        ..record('b', const ExitGeo(country: 'US', disputedWith: 'SC', sources: 3));
      await Future<void>.delayed(const Duration(milliseconds: 2200)); // debounce
      first.dispose();

      box.m['exitgeo.v2'] = <dynamic, dynamic>{
        ...box.m['exitgeo.v2'] as Map,
        'old': {
          'c': 'FR',
          'n': 2,
          'at': DateTime.now()
              .subtract(const Duration(days: 30))
              .toIso8601String(),
        },
        'junk': 'not a map',
      };

      final second = _container(box);
      addTearDown(second.dispose);
      final restored = second.read(exitGeoProvider);
      expect(restored.keys, unorderedEquals(['a', 'b']));
      expect(restored['a'], _nl);
      expect(restored['b']!.disputedWith, 'SC');
    });
  });

  group('a chosen country means the exit country', () {
    // Two nodes listed as US; one of them really exits in the Netherlands —
    // the first case from the bug report (an FDCservers box in Amsterdam).
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

    NodeProbe good(int ms) =>
        NodeProbe(verdict: ProbeVerdict.works, bestMs: ms, at: DateTime.now());

    test('a working node in the wrong country does not win a scan', () async {
      final c = _container();
      addTearDown(c.dispose);
      final pf = c.read(preflightProvider.notifier);
      final geo = c.read(exitGeoProvider.notifier);

      // Both answered; the faster one was seen exiting in NL.
      pf.debugPut('us-fake', good(20));
      pf.debugPut('us-real', good(200));
      geo.record('us-fake', _nl);
      geo.record('us-real', _us);

      bool exitsInUs(String id) =>
          c.read(exitGeoProvider)[id]?.confirms('US') ?? false;

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

    test('a node the sources cannot agree on does not win either', () async {
      final c = _container();
      addTearDown(c.dispose);
      final pf = c.read(preflightProvider.notifier);
      final geo = c.read(exitGeoProvider.notifier);

      pf.debugPut('us-disputed', good(20));
      pf.debugPut('us-real', good(200));
      geo.record(
        'us-disputed',
        const ExitGeo(country: 'US', disputedWith: 'SC', sources: 3),
      );
      geo.record('us-real', _us);

      final found = await pf
          .burstFindGood(
            ['us-disputed', 'us-real'],
            const {},
            accept: (id) => c.read(exitGeoProvider)[id]?.confirms('US') ?? false,
          )
          .timeout(const Duration(seconds: 1));
      expect(found, 'us-real');
    });

    test('no node exits in the chosen country → the scan finds nothing',
        () async {
      final c = _container();
      addTearDown(c.dispose);
      final pf = c.read(preflightProvider.notifier);
      pf.debugPut('us-fake', good(20));
      c.read(exitGeoProvider.notifier).record('us-fake', _nl);

      final found = await pf
          .burstFindGood(
            ['us-fake'],
            const {},
            accept: (id) => c.read(exitGeoProvider)[id]?.confirms('US') ?? false,
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
