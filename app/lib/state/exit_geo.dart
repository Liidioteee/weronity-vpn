import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/country_names.dart';
import '../domain/node.dart';
import 'providers.dart';

/// Where each node's traffic **actually comes out**, as observed from outside —
/// node id → ISO-3166 alpha-2.
///
/// The country a node carries in the pool is a GeoIP guess about its *entry*
/// address. It is wrong whenever the node relays elsewhere or sits behind a
/// CDN, and GeoIP tables disagree about hosting ranges anyway. What the user
/// picked a country for is the exit — so once a probe or a live session has
/// *seen* the exit country, it replaces the guess everywhere: `nodesProvider`
/// applies this map, and the country lists, filters, selection and failover
/// all follow.
///
/// Fed by [PreflightNotifier.testRaw] (every node check) and by the monitor
/// (the node the session is running through). Kept for a week.
class ExitGeoNotifier extends Notifier<Map<String, String>> {
  static const _boxKey = 'exitgeo.v1';
  static const _keepFor = Duration(days: 7);

  final Map<String, DateTime> _seenAt = {};
  Timer? _saveDebounce;

  @override
  Map<String, String> build() {
    ref.onDispose(() => _saveDebounce?.cancel());
    Object? raw;
    try {
      raw = ref.read(sessionBoxProvider).get(_boxKey);
    } on UnimplementedError {
      return const {}; // no session box (e.g. a unit test) — start empty
    }
    if (raw is! Map) return const {};
    final cutoff = DateTime.now().subtract(_keepFor);
    final out = <String, String>{};
    for (final e in raw.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final cc = v['c'];
      final at = DateTime.tryParse('${v['at']}');
      if (cc is! String || !isCountryCode(cc)) continue;
      if (at == null || at.isBefore(cutoff)) continue;
      out['${e.key}'] = cc;
      _seenAt['${e.key}'] = at;
    }
    return out;
  }

  /// Two ASCII capitals — what the probe reports and what the pool uses.
  static bool isCountryCode(String s) =>
      s.length == 2 &&
      s.codeUnits.every((c) => c >= 0x41 && c <= 0x5A); // 'A'..'Z'

  /// Records that [nodeId] was seen exiting in [country]. Anything that is not
  /// a country code (null, empty, "XX") is ignored — "could not tell" must not
  /// erase what an earlier check did establish.
  void record(String nodeId, String? country) {
    final cc = country?.trim().toUpperCase();
    if (cc == null || !isCountryCode(cc)) return;
    _seenAt[nodeId] = DateTime.now();
    if (state[nodeId] != cc) state = {...state, nodeId: cc};
    _persist();
  }

  void _persist() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), () {
      try {
        final cutoff = DateTime.now().subtract(_keepFor);
        ref.read(sessionBoxProvider).put(_boxKey, {
          for (final e in state.entries)
            if (_seenAt[e.key]?.isAfter(cutoff) ?? false)
              e.key: {'c': e.value, 'at': _seenAt[e.key]!.toIso8601String()},
        });
      } on Object catch (e) {
        debugPrint('exit-geo cache save failed: $e');
      }
    });
  }
}

final exitGeoProvider =
    NotifierProvider<ExitGeoNotifier, Map<String, String>>(ExitGeoNotifier.new);

/// [node] with its country replaced by the observed exit [country], when one is
/// known and differs. The ASN stays — it still describes the entry address.
Node withExitCountry(Node node, String? country) {
  if (country == null || country == node.geo.country) return node;
  return node.copyWith(
    geo: Geo(
      country: country,
      countryName: countryNameRu(country),
      asn: node.geo.asn,
      asOrg: node.geo.asOrg,
    ),
  );
}

/// Pulls the requester's country out of a Cloudflare `/cdn-cgi/trace` body (the
/// `loc=NL` line). Reached through the tunnel, the requester is the node's exit
/// address. Returns null for anything that is not a real country code ("XX" =
/// unknown, "T1" = Tor).
String? parseTraceCountry(String body) {
  for (final line in body.split('\n')) {
    final t = line.trim();
    if (!t.startsWith('loc=')) continue;
    final cc = t.substring(4).trim().toUpperCase();
    return ExitGeoNotifier.isCountryCode(cc) && cc != 'XX' ? cc : null;
  }
  return null;
}
