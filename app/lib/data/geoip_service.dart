import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// Offline IPv4 -> ISO-3166 country lookup, backed by a packed asset built by
/// `app/tool/build_geoip.py` (source: sapics/ip-location-db, PDDL / CC0-style).
///
/// Used to give **imported** keys a country (and therefore a flag) — pool nodes
/// already carry geo from the collector. No network calls for the lookup itself;
/// hostnames are resolved once via the OS resolver and cached.
///
/// Asset layout (little-endian):
///   magic     "WGI2"
///   n_cc      uint16                 country codes in the table (index 0 = "")
///   cc_table  n_cc x 2 ASCII bytes
///   count     uint32
///   records   count x (uint32 start_ip, uint16 cc_index), sorted, gap-free —
///             each record covers up to the next record's start_ip - 1.
class GeoIpService {
  GeoIpService._(this._starts, this._codeIndex, this._codes);

  static const _asset = 'assets/geoip/ipv4_country.v2.bin';

  final Uint32List _starts;
  final Uint16List _codeIndex;
  final List<String> _codes;

  final Map<String, String?> _hostCache = <String, String?>{};

  static GeoIpService? _instance;
  static Future<GeoIpService>? _loading;

  /// Loads (and caches) the singleton. Safe to call repeatedly.
  static Future<GeoIpService> instance({AssetBundle? bundle}) {
    if (_instance != null) return Future<GeoIpService>.value(_instance);
    return _loading ??= _load(bundle ?? rootBundle).then((s) {
      _instance = s;
      _loading = null;
      return s;
    });
  }

  static Future<GeoIpService> _load(AssetBundle bundle) async {
    final data = await bundle.load(_asset);
    return parseBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  /// Exposed for tests — parse an in-memory copy of the asset.
  static GeoIpService parseBytes(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    if (bytes.lengthInBytes < 10 ||
        bd.getUint8(0) != 0x57 || // W
        bd.getUint8(1) != 0x47 || // G
        bd.getUint8(2) != 0x49 || // I
        bd.getUint8(3) != 0x32) {
      throw const FormatException('geoip: bad magic');
    }
    var off = 4;
    final nCc = bd.getUint16(off, Endian.little);
    off += 2;
    final codes = List<String>.filled(nCc, '');
    for (var i = 0; i < nCc; i++) {
      final a = bytes[off], b = bytes[off + 1];
      codes[i] = (a == 0) ? '' : String.fromCharCodes(<int>[a, b]);
      off += 2;
    }
    final count = bd.getUint32(off, Endian.little);
    off += 4;
    if (off + count * 6 > bytes.lengthInBytes) {
      throw const FormatException('geoip: truncated records');
    }
    final starts = Uint32List(count);
    final idx = Uint16List(count);
    for (var i = 0; i < count; i++) {
      starts[i] = bd.getUint32(off, Endian.little);
      idx[i] = bd.getUint16(off + 4, Endian.little);
      off += 6;
    }
    return GeoIpService._(starts, idx, codes);
  }

  /// `'1.2.3.4'` -> unsigned 32-bit int, or null if not a dotted IPv4 literal.
  static int? parseV4(String s) {
    final parts = s.split('.');
    if (parts.length != 4) return null;
    var out = 0;
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return null;
      out = (out << 8) | n;
    }
    return out & 0xFFFFFFFF;
  }

  /// Country for a numeric IPv4, or null if unallocated / unknown.
  String? lookupIp(int ip) {
    if (_starts.isEmpty) return null;
    var lo = 0, hi = _starts.length - 1;
    if (ip < _starts[0]) return null;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_starts[mid] <= ip) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final code = _codes[_codeIndex[lo]];
    return code.isEmpty ? null : code;
  }

  /// Country for an IPv4 literal or a hostname. Hostnames are resolved via the
  /// OS resolver once and cached (including negative results).
  Future<String?> lookupHost(String host) async {
    final h = host.trim();
    if (h.isEmpty) return null;

    final literal = parseV4(h);
    if (literal != null) return lookupIp(literal);

    if (_hostCache.containsKey(h)) return _hostCache[h];

    String? cc;
    try {
      final addrs = await InternetAddress.lookup(h)
          .timeout(const Duration(seconds: 4));
      for (final a in addrs) {
        if (a.type == InternetAddressType.IPv4) {
          final ip = parseV4(a.address);
          if (ip != null) {
            cc = lookupIp(ip);
            break;
          }
        }
      }
    } on Object {
      cc = null;
    }
    _hostCache[h] = cc;
    return cc;
  }

  /// Synchronous best-effort: a cached hostname result or an IPv4 literal.
  String? cachedCountry(String host) {
    final h = host.trim();
    final literal = parseV4(h);
    if (literal != null) return lookupIp(literal);
    return _hostCache[h];
  }
}
