import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/geoip_service.dart';
import '../domain/country_names.dart';
import '../domain/node.dart';
import 'providers.dart';

/// Where a node's traffic comes out, as seen from outside.
///
/// "Which country is this address in" has no single answer: every geolocation
/// database makes its own guess, and for leased address space they disagree
/// (the same Los Angeles server is "US" to one and "Seychelles" — where the
/// block's owner is registered — to another). A website decides with whichever
/// database it happens to use. So one source saying "US" is not enough to
/// promise the user the US: we ask several and keep track of whether they
/// agree.
@immutable
class ExitGeo {
  const ExitGeo({required this.country, this.disputedWith, this.sources = 1});

  /// The country most sources named (ISO-3166 alpha-2); the first one asked
  /// wins a tie.
  final String country;

  /// A different country another source named, or null when they all agree.
  final String? disputedWith;

  /// How many sources answered at all.
  final int sources;

  bool get disputed => disputedWith != null;

  /// At least two independent sources, and none disagrees.
  bool get confirmed => !disputed && sources >= 2;

  /// Good enough to tell the user they exit in [wanted]: that is the country,
  /// and no source says otherwise.
  bool confirms(String wanted) => country == wanted && !disputed;

  /// Combines per-source answers, in order of trust. Anything that is not a
  /// country code ("could not tell") is skipped; null when nobody answered.
  static ExitGeo? fromOpinions(Iterable<String?> opinions) {
    final seen = <String>[
      for (final o in opinions)
        if (o != null && isCountryCode(o.trim().toUpperCase()))
          o.trim().toUpperCase(),
    ];
    if (seen.isEmpty) return null;
    var best = seen.first;
    var bestVotes = 0;
    for (final cc in seen.toSet()) {
      final votes = seen.where((s) => s == cc).length;
      if (votes > bestVotes) {
        best = cc;
        bestVotes = votes;
      }
    }
    String? other;
    for (final cc in seen) {
      if (cc != best) {
        other = cc;
        break;
      }
    }
    return ExitGeo(country: best, disputedWith: other, sources: seen.length);
  }

  /// Two ASCII capitals, and not the "unknown" placeholder.
  static bool isCountryCode(String s) =>
      s.length == 2 &&
      s != 'XX' &&
      s.codeUnits.every((c) => c >= 0x41 && c <= 0x5A); // 'A'..'Z'

  @override
  bool operator ==(Object other) =>
      other is ExitGeo &&
      other.country == country &&
      other.disputedWith == disputedWith &&
      other.sources == sources;

  @override
  int get hashCode => Object.hash(country, disputedWith, sources);

  @override
  String toString() => disputed
      ? 'ExitGeo($country, disputed with $disputedWith, $sources sources)'
      : 'ExitGeo($country, $sources sources)';
}

/// Where each node's traffic **actually comes out** — node id → [ExitGeo].
///
/// The country a node carries in the pool is a GeoIP guess about its *entry*
/// address. It is wrong whenever the node relays elsewhere or sits behind a
/// CDN. What the user picked a country for is the exit — so once a probe or a
/// live session has *seen* the exit country, it replaces the guess everywhere:
/// `nodesProvider` applies this map, and the country lists, filters, selection
/// and failover all follow.
///
/// Fed by [PreflightNotifier.testRaw] (every node check) and by the monitor
/// (the node the session is running through). Kept for a week.
class ExitGeoNotifier extends Notifier<Map<String, ExitGeo>> {
  static const _boxKey = 'exitgeo.v2';
  static const _keepFor = Duration(days: 7);

  final Map<String, DateTime> _seenAt = {};
  Timer? _saveDebounce;

  @override
  Map<String, ExitGeo> build() {
    ref.onDispose(() => _saveDebounce?.cancel());
    Object? raw;
    try {
      raw = ref.read(sessionBoxProvider).get(_boxKey);
    } on UnimplementedError {
      return const {}; // no session box (e.g. a unit test) — start empty
    }
    if (raw is! Map) return const {};
    final cutoff = DateTime.now().subtract(_keepFor);
    final out = <String, ExitGeo>{};
    for (final e in raw.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final cc = v['c'];
      final other = v['d'];
      final n = v['n'];
      final at = DateTime.tryParse('${v['at']}');
      if (cc is! String || !ExitGeo.isCountryCode(cc)) continue;
      if (at == null || at.isBefore(cutoff)) continue;
      out['${e.key}'] = ExitGeo(
        country: cc,
        disputedWith:
            other is String && ExitGeo.isCountryCode(other) ? other : null,
        sources: n is int && n > 0 ? n : 1,
      );
      _seenAt['${e.key}'] = at;
    }
    return out;
  }

  /// Records what a check saw for [nodeId]. `null` ("could not tell") is
  /// ignored — it must not erase what an earlier check did establish. Neither
  /// does a poorer observation of the same country: when one source failed to
  /// answer this time, the fuller picture from before stands.
  void record(String nodeId, ExitGeo? seen) {
    if (seen == null) return;
    _seenAt[nodeId] = DateTime.now();
    final old = state[nodeId];
    final poorer = old != null &&
        seen.country == old.country &&
        seen.sources < old.sources;
    if (!poorer && old != seen) state = {...state, nodeId: seen};
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
              e.key: {
                'c': e.value.country,
                if (e.value.disputedWith != null) 'd': e.value.disputedWith,
                'n': e.value.sources,
                'at': _seenAt[e.key]!.toIso8601String(),
              },
        });
      } on Object catch (e) {
        debugPrint('exit-geo cache save failed: $e');
      }
    });
  }
}

final exitGeoProvider =
    NotifierProvider<ExitGeoNotifier, Map<String, ExitGeo>>(ExitGeoNotifier.new);

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

// ---- reading the sources ----------------------------------------------------

/// Cloudflare's `/cdn-cgi/trace`: plain `key=value` lines about the requester,
/// by Cloudflare's own data. Reached through the tunnel, the requester is the
/// node's exit address.
const exitTraceUrl = 'https://www.cloudflare.com/cdn-cgi/trace';

/// `{"ip":"…","country":"NL"}` by MaxMind GeoLite2 — the database most websites
/// use to decide where a visitor is.
const exitSecondOpinionUrl = 'https://api.country.is/';

String? _traceField(String body, String key) {
  for (final line in body.split('\n')) {
    final t = line.trim();
    if (t.startsWith('$key=')) return t.substring(key.length + 1).trim();
  }
  return null;
}

/// The requester's country (`loc=NL`) from a trace body, or null for anything
/// that is not a real country code ("XX" = unknown, "T1" = Tor).
String? parseTraceCountry(String body) {
  final cc = _traceField(body, 'loc')?.toUpperCase();
  return cc != null && ExitGeo.isCountryCode(cc) ? cc : null;
}

/// The requester's address (`ip=…`) from a trace body.
String? parseTraceIp(String body) {
  final ip = _traceField(body, 'ip');
  return ip == null || ip.isEmpty ? null : ip;
}

/// The country from a `{"ip":…,"country":"NL"}` answer.
String? parseCountryIs(String body) {
  try {
    final json = jsonDecode(body);
    final cc = json is Map ? '${json['country'] ?? ''}'.toUpperCase() : '';
    return ExitGeo.isCountryCode(cc) ? cc : null;
  } on FormatException {
    return null;
  }
}

/// What the bundled offline table (DB-IP Lite, IPv4 only) says about [ip] — a
/// third opinion that costs no request.
String? offlineCountry(GeoIpService? table, Object? ip) {
  if (table == null || ip is! String) return null;
  final v4 = GeoIpService.parseV4(ip.trim());
  return v4 == null ? null : table.lookupIp(v4);
}

/// The [ExitGeo] a node probe's summary (`wrnTestNode` with `exit_geo`) adds up
/// to, or null when it learned nothing.
ExitGeo? exitGeoFromProbe(Map<String, dynamic>? summary, GeoIpService? table) {
  if (summary == null) return null;
  String? str(String key) => summary[key] is String ? summary[key] as String : null;
  return ExitGeo.fromOpinions([
    str('exit_country'),
    str('exit_country_alt'),
    offlineCountry(table, summary['exit_ip']),
  ]);
}
