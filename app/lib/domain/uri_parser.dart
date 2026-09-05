/// Client-side proxy-URI parser — a Dart port of the collector's parsers, used
/// for user-supplied keys and subscriptions (Manager: "Мои ключи").
///
/// Covers vless / vmess / trojan / hysteria2 / shadowsocks / tuic plus base64
/// and Clash-YAML subscription bodies. Produces [Node]s tagged as imported so
/// they flow through the same filtering / switching machinery as pool nodes.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

import 'node.dart';

class ProxyUriError implements Exception {
  ProxyUriError(this.message);
  final String message;
  @override
  String toString() => 'ProxyUriError: $message';
}

const _knownSsMethods = {
  '2022-blake3-aes-128-gcm',
  '2022-blake3-aes-256-gcm',
  '2022-blake3-chacha20-poly1305',
  'aes-128-gcm',
  'aes-192-gcm',
  'aes-256-gcm',
  'chacha20-ietf-poly1305',
  'xchacha20-ietf-poly1305',
  'chacha20-poly1305',
  'none',
  'plain',
};

const _netMap = {
  'tcp': 'tcp',
  'raw': 'tcp',
  'ws': 'ws',
  'websocket': 'ws',
  'grpc': 'grpc',
  'gun': 'grpc',
  'http': 'h2',
  'h2': 'h2',
  'httpupgrade': 'httpupgrade',
  'xhttp': 'httpupgrade',
  'splithttp': 'httpupgrade',
  'kcp': 'mkcp',
  'mkcp': 'mkcp',
  'quic': 'quic',
};

// --- public API -----------------------------------------------------------

/// Parse a single proxy URI into a [Node]. Returns null on any failure.
Node? parseProxyUri(String uri, {String source = 'custom'}) {
  final trimmed = uri.trim();
  try {
    final scheme = trimmed.split('://').first.toLowerCase();
    final parsed = switch (scheme) {
      'vless' => _vless(trimmed),
      'vmess' => _vmess(trimmed),
      'trojan' => _trojan(trimmed),
      'hysteria2' || 'hy2' => _hysteria2(trimmed),
      'ss' => _shadowsocks(trimmed),
      'tuic' => _tuic(trimmed),
      _ => null,
    };
    return parsed?._toNode(source: source);
  } on ProxyUriError {
    return null;
  } catch (_) {
    return null;
  }
}

/// Extract every supported proxy URI from a blob of text and parse them.
List<String> extractProxyUris(String text) {
  const schemes = ['vless://', 'vmess://', 'trojan://', 'hysteria2://', 'hy2://', 'ss://', 'tuic://'];
  return [
    for (final raw in text.split(RegExp(r'[\r\n]+')))
      if (raw.trim().isNotEmpty &&
          !raw.trimLeft().startsWith('#') &&
          schemes.any((s) => raw.trimLeft().startsWith(s)))
        raw.trim(),
  ];
}

/// Decode a subscription body: a URI list, a base64 blob of one, or Clash YAML.
List<Node> parseSubscription(String body, {required String source}) {
  final text = body.trim();
  if (text.isEmpty) return const [];

  // Clash / mihomo YAML
  if (text.contains('proxies:') &&
      (text.contains('type:') || text.contains('server:'))) {
    final nodes = _parseClash(text, source: source);
    if (nodes.isNotEmpty) return nodes;
  }

  var work = text;
  if (extractProxyUris(work).isEmpty) {
    final decoded = _tryB64(work);
    if (decoded != null) work = decoded;
  }
  return [
    for (final u in extractProxyUris(work))
      if (parseProxyUri(u, source: source) case final Node n) n,
  ];
}

// --- intermediate representation ----------------------------------------

class _Parsed {
  _Parsed({
    required this.protocol,
    required this.transport,
    required this.host,
    required this.port,
    required this.auth,
    required this.tag,
    required this.rawUri,
    Map<String, dynamic>? params,
  }) : params = params ?? {};

  final String protocol;
  final String transport;
  final String host;
  final int port;
  final String auth;
  final String tag;
  final String rawUri;
  final Map<String, dynamic> params;

  String? get _sni => (params['sni'] ?? params['host_header']) as String?;

  NodeSecurity get _security {
    final sec = (params['security'] as String? ?? '').toLowerCase();
    if (sec == 'reality' || params['public_key'] != null) return NodeSecurity.reality;
    if (sec == 'tls' || sec == 'xtls' || protocol == 'hysteria2' || protocol == 'tuic') {
      return NodeSecurity.tls;
    }
    return NodeSecurity.none;
  }

  String get _dedupKey {
    final h = host.toLowerCase().replaceAll(RegExp(r'\.$'), '');
    return '$protocol|$h:$port|$auth|$transport|${_sni ?? ''}';
  }

  String get _id => sha1.convert(utf8.encode(_dedupKey)).toString().substring(0, 12);

  Node _toNode({required String source}) {
    final now = DateTime.now();
    return Node(
      id: _id,
      protocol: protocol,
      transport: transport,
      tag: tag.isEmpty ? '$host:$port' : tag,
      endpoint: Endpoint(host: host, port: port),
      geo: Geo.unknown,
      health: const Health(tcpOk: true, tlsOk: false, pingMs: null, checkedAt: null),
      lifetime: Lifetime(
        firstSeen: now,
        lastSeen: now,
        ageHours: 0,
        klass: LifetimeClass.fresh,
        seenRuns: 1,
        stability: 1,
      ),
      classification: Classification(
        sni: _sni,
        security: _security,
        flow: params['flow'] as String?,
        udp: protocol == 'hysteria2' || protocol == 'tuic',
      ),
      provenance: Provenance(
        source: source,
        sourceFile: '',
        imported: true,
        rawUriSha1: sha1.convert(utf8.encode(rawUri)).toString(),
      ),
      recommended: false,
      rawUri: rawUri,
      outbound: _outbound(),
    );
  }

  Map<String, dynamic> _outbound() {
    final ob = <String, dynamic>{
      'tag': tag.isEmpty ? '$host:$port' : tag,
      'server': host,
      'server_port': port,
    };
    switch (protocol) {
      case 'vless':
        ob['type'] = 'vless';
        ob['uuid'] = params['uuid'];
        if (params['flow'] != null) ob['flow'] = params['flow'];
        ob['packet_encoding'] = 'xudp';
      case 'vmess':
        ob['type'] = 'vmess';
        ob['uuid'] = params['uuid'];
        ob['alter_id'] = params['alter_id'] ?? 0;
        ob['security'] = params['cipher'] ?? 'auto';
      case 'trojan':
        ob['type'] = 'trojan';
        ob['password'] = params['password'];
      case 'shadowsocks':
        ob['type'] = 'shadowsocks';
        ob['method'] = params['method'];
        ob['password'] = params['password'];
      case 'hysteria2':
        ob['type'] = 'hysteria2';
        ob['password'] = params['password'];
        if (params['up_mbps'] != null) ob['up_mbps'] = params['up_mbps'];
        if (params['down_mbps'] != null) ob['down_mbps'] = params['down_mbps'];
        if (params['obfs'] == 'salamander') {
          ob['obfs'] = {'type': 'salamander', 'password': params['obfs_password'] ?? ''};
        }
      case 'tuic':
        ob['type'] = 'tuic';
        ob['uuid'] = params['uuid'];
        ob['password'] = params['password'];
        ob['congestion_control'] = params['congestion_control'] ?? 'bbr';
        ob['udp_relay_mode'] = params['udp_relay_mode'] ?? 'native';
    }
    final tls = _tlsBlock();
    if (tls != null) ob['tls'] = tls;
    final tr = _transportBlock();
    if (tr != null) ob['transport'] = tr;
    return ob;
  }

  Map<String, dynamic>? _tlsBlock() {
    final sec = _security;
    if (sec == NodeSecurity.none && protocol != 'hysteria2' && protocol != 'tuic') {
      return null;
    }
    final tls = <String, dynamic>{'enabled': true};
    if (_sni != null) tls['server_name'] = _sni;
    if (params['allow_insecure'] == true) tls['insecure'] = true;
    final alpn = params['alpn'];
    if (alpn is List && alpn.isNotEmpty) tls['alpn'] = alpn;
    final fp = params['fingerprint'] as String?;
    if (fp != null) tls['utls'] = {'enabled': true, 'fingerprint': fp};
    if (sec == NodeSecurity.reality) {
      tls['reality'] = {
        'enabled': true,
        'public_key': params['public_key'] ?? '',
        if (params['short_id'] != null) 'short_id': params['short_id'],
      };
      tls.putIfAbsent('utls', () => {'enabled': true, 'fingerprint': fp ?? 'chrome'});
    }
    return tls;
  }

  Map<String, dynamic>? _transportBlock() {
    switch (transport) {
      case 'ws':
        return {
          'type': 'ws',
          'path': params['path'] ?? '/',
          if (params['host_header'] != null) 'headers': {'Host': params['host_header']},
        };
      case 'grpc':
        return {'type': 'grpc', 'service_name': params['service_name'] ?? ''};
      case 'httpupgrade':
        return {
          'type': 'httpupgrade',
          'path': params['path'] ?? '/',
          if (params['host_header'] != null) 'host': params['host_header'],
        };
      case 'h2':
        return {
          'type': 'http',
          'path': params['path'] ?? '/',
          if (params['host_header'] != null) 'host': [params['host_header']],
        };
      default:
        return null;
    }
  }
}

// --- per-scheme parsers -------------------------------------------------

/// Percent-decode, tolerating already-decoded text (spaces, Cyrillic, …) which
/// is common in the human-readable `#name` fragment of a pasted key.
String _decode(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

({String userinfo, String host, int port}) _splitAuthority(String rest) {
  final u = Uri.parse('//$rest');
  if (u.host.isEmpty || !u.hasPort) throw ProxyUriError('no host:port in "$rest"');
  return (userinfo: _decode(u.userInfo), host: u.host, port: u.port);
}

(String body, String name) _splitFragment(String uri) {
  final i = uri.indexOf('#');
  if (i < 0) return (uri, '');
  return (uri.substring(0, i), _decode(uri.substring(i + 1)).trim());
}

Map<String, String> _query(String q) {
  if (q.isEmpty) return {};
  return Uri.splitQueryString(q);
}

List<String> _csv(String? v) =>
    (v == null || v.isEmpty) ? const [] : v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

bool _bool(String? v) => const {'1', 'true', 'yes', 'on'}.contains(v?.toLowerCase());

_Parsed _vless(String uri) {
  final (body, name) = _splitFragment(uri);
  var rest = body.substring('vless://'.length);
  String query = '';
  final qi = rest.indexOf('?');
  if (qi >= 0) {
    query = rest.substring(qi + 1);
    rest = rest.substring(0, qi);
  }
  final a = _splitAuthority(rest);
  if (a.userinfo.isEmpty) throw ProxyUriError('vless: empty uuid');
  final q = _query(query);
  final net = (q['type'] ?? 'tcp').toLowerCase();
  final transport = _netMap[net] ?? (throw ProxyUriError('vless: net $net'));
  final security = (q['security'] ?? 'none').toLowerCase();
  final params = <String, dynamic>{
    'uuid': a.userinfo,
    'security': security,
    if (q['flow'] != null && q['flow']!.isNotEmpty) 'flow': q['flow'],
    if ((q['sni'] ?? q['servername']) case final s? when s.isNotEmpty) 'sni': s,
    if (_csv(q['alpn']).isNotEmpty) 'alpn': _csv(q['alpn']),
    if (q['fp'] != null && q['fp']!.isNotEmpty) 'fingerprint': q['fp'],
    'allow_insecure': _bool(q['allowInsecure'] ?? q['insecure']),
  };
  if (security == 'reality') {
    if ((q['pbk'] ?? '').isEmpty) throw ProxyUriError('vless reality: missing pbk');
    params['public_key'] = q['pbk'];
    if ((q['sid'] ?? '').isNotEmpty) params['short_id'] = q['sid'];
  }
  if (transport == 'ws' || transport == 'httpupgrade' || transport == 'h2') {
    params['path'] = q['path'] ?? '/';
    if ((q['host'] ?? '').isNotEmpty) params['host_header'] = q['host'];
  } else if (transport == 'grpc') {
    params['service_name'] = q['serviceName'] ?? q['servicename'] ?? '';
  }
  return _Parsed(
    protocol: 'vless',
    transport: transport,
    host: a.host,
    port: a.port,
    auth: a.userinfo,
    tag: name,
    rawUri: uri,
    params: params,
  );
}

_Parsed _trojan(String uri) {
  final (body, name) = _splitFragment(uri);
  var rest = body.substring('trojan://'.length);
  String query = '';
  final qi = rest.indexOf('?');
  if (qi >= 0) {
    query = rest.substring(qi + 1);
    rest = rest.substring(0, qi);
  }
  final a = _splitAuthority(rest);
  if (a.userinfo.isEmpty) throw ProxyUriError('trojan: empty password');
  final q = _query(query);
  final net = (q['type'] ?? 'tcp').toLowerCase();
  final transport = _netMap[net.isEmpty ? 'tcp' : net] ?? 'tcp';
  final params = <String, dynamic>{
    'password': a.userinfo,
    'security': (q['security'] ?? 'tls').toLowerCase(),
    'sni': (q['sni'] ?? q['servername'])?.isNotEmpty == true ? (q['sni'] ?? q['servername']) : a.host,
    if (_csv(q['alpn']).isNotEmpty) 'alpn': _csv(q['alpn']),
    if ((q['fp'] ?? '').isNotEmpty) 'fingerprint': q['fp'],
    'allow_insecure': _bool(q['allowInsecure'] ?? q['insecure']),
  };
  if (transport == 'ws' || transport == 'httpupgrade' || transport == 'h2') {
    params['path'] = q['path'] ?? '/';
    if ((q['host'] ?? '').isNotEmpty) params['host_header'] = q['host'];
  } else if (transport == 'grpc') {
    params['service_name'] = q['serviceName'] ?? '';
  }
  return _Parsed(
    protocol: 'trojan',
    transport: transport,
    host: a.host,
    port: a.port,
    auth: a.userinfo,
    tag: name,
    rawUri: uri,
    params: params,
  );
}

_Parsed _hysteria2(String uri) {
  final (body, name) = _splitFragment(uri);
  final scheme = body.split('://').first;
  var rest = body.substring('$scheme://'.length);
  String query = '';
  final qi = rest.indexOf('?');
  if (qi >= 0) {
    query = rest.substring(qi + 1);
    rest = rest.substring(0, qi);
  }
  final a = _splitAuthority(rest);
  final q = _query(query);
  final params = <String, dynamic>{
    'password': a.userinfo,
    'security': 'tls',
    if ((q['sni'] ?? q['servername'])?.isNotEmpty == true) 'sni': q['sni'] ?? q['servername'],
    'alpn': _csv(q['alpn']).isEmpty ? ['h3'] : _csv(q['alpn']),
    'allow_insecure': _bool(q['insecure'] ?? q['allowInsecure']),
    'up_mbps': ?_int(q['up'] ?? q['upmbps']),
    'down_mbps': ?_int(q['down'] ?? q['downmbps']),
  };
  final obfs = (q['obfs'] ?? '').toLowerCase();
  if (obfs == 'salamander') {
    params['obfs'] = 'salamander';
    params['obfs_password'] = q['obfs-password'] ?? q['obfsParam'];
  }
  return _Parsed(
    protocol: 'hysteria2',
    transport: 'quic',
    host: a.host,
    port: a.port,
    auth: a.userinfo,
    tag: name,
    rawUri: uri,
    params: params,
  );
}

_Parsed _tuic(String uri) {
  final (body, name) = _splitFragment(uri);
  var rest = body.substring('tuic://'.length);
  String query = '';
  final qi = rest.indexOf('?');
  if (qi >= 0) {
    query = rest.substring(qi + 1);
    rest = rest.substring(0, qi);
  }
  final a = _splitAuthority(rest);
  if (!a.userinfo.contains(':')) throw ProxyUriError('tuic: expected uuid:password');
  final parts = a.userinfo.split(':');
  final q = _query(query);
  return _Parsed(
    protocol: 'tuic',
    transport: 'quic',
    host: a.host,
    port: a.port,
    auth: a.userinfo,
    tag: name,
    rawUri: uri,
    params: {
      'uuid': parts[0],
      'password': parts.sublist(1).join(':'),
      'security': 'tls',
      if ((q['sni'] ?? q['servername'])?.isNotEmpty == true) 'sni': q['sni'] ?? q['servername'],
      'alpn': _csv(q['alpn']).isEmpty ? ['h3'] : _csv(q['alpn']),
      'congestion_control': q['congestion_control'] ?? 'bbr',
      'udp_relay_mode': q['udp_relay_mode'] ?? 'native',
      'allow_insecure': _bool(q['allow_insecure'] ?? q['insecure']),
    },
  );
}

_Parsed _vmess(String uri) {
  final (body, _) = _splitFragment(uri);
  final payload = body.substring('vmess://'.length);
  final Object? obj;
  try {
    obj = jsonDecode(utf8.decode(_b64bytes(payload)));
  } catch (e) {
    throw ProxyUriError('vmess: bad payload: $e');
  }
  if (obj is! Map) throw ProxyUriError('vmess: payload not an object');
  final host = (obj['add'] ?? '').toString().trim();
  if (host.isEmpty) throw ProxyUriError('vmess: missing add');
  final port = int.tryParse('${obj['port']}');
  if (port == null) throw ProxyUriError('vmess: bad port');
  final uuid = (obj['id'] ?? '').toString();
  if (uuid.isEmpty) throw ProxyUriError('vmess: missing id');
  final net = (obj['net'] ?? 'tcp').toString().toLowerCase();
  final transport = _netMap[net] ?? (throw ProxyUriError('vmess: net $net'));
  final tls = (obj['tls'] ?? '').toString().toLowerCase();
  final params = <String, dynamic>{
    'uuid': uuid,
    'alter_id': int.tryParse('${obj['aid'] ?? 0}') ?? 0,
    'cipher': (obj['scy'] ?? 'auto').toString(),
    'security': (tls == 'tls' || tls == 'reality' || tls == 'xtls') ? 'tls' : 'none',
    if ((obj['sni'] ?? obj['host'])?.toString().isNotEmpty == true)
      'sni': (obj['sni'] ?? obj['host']).toString(),
    if (_csv(obj['alpn']?.toString()).isNotEmpty) 'alpn': _csv(obj['alpn']?.toString()),
  };
  if (transport == 'ws' || transport == 'httpupgrade' || transport == 'h2') {
    params['path'] = (obj['path'] ?? '/').toString();
    if ((obj['host'] ?? '').toString().isNotEmpty) params['host_header'] = obj['host'].toString();
  } else if (transport == 'grpc') {
    params['service_name'] = (obj['path'] ?? obj['serviceName'] ?? '').toString();
  }
  return _Parsed(
    protocol: 'vmess',
    transport: transport,
    host: host,
    port: port,
    auth: uuid,
    tag: (obj['ps'] ?? '').toString().trim(),
    rawUri: uri,
    params: params,
  );
}

_Parsed _shadowsocks(String uri) {
  final (body, name) = _splitFragment(uri);
  var rest = body.substring('ss://'.length);
  final qi = rest.indexOf('?');
  if (qi >= 0) rest = rest.substring(0, qi);

  String method;
  String password;
  String host;
  int port;

  if (rest.contains('@')) {
    final at = rest.lastIndexOf('@');
    final userinfo = _decode(rest.substring(0, at));
    final hostport = rest.substring(at + 1);
    (method, password) = _splitMethodPass(userinfo);
    final c = hostport.lastIndexOf(':');
    host = hostport.substring(0, c).replaceAll(RegExp(r'^\[|\]$'), '');
    port = int.parse(hostport.substring(c + 1));
  } else {
    final decoded = utf8.decode(_b64bytes(rest));
    final at = decoded.lastIndexOf('@');
    if (at < 0) throw ProxyUriError('ss legacy: no @');
    final userinfo = decoded.substring(0, at);
    final hostport = decoded.substring(at + 1);
    final ci = userinfo.indexOf(':');
    method = userinfo.substring(0, ci);
    password = userinfo.substring(ci + 1);
    final c = hostport.lastIndexOf(':');
    host = hostport.substring(0, c);
    port = int.parse(hostport.substring(c + 1));
  }
  return _Parsed(
    protocol: 'shadowsocks',
    transport: 'tcp',
    host: host,
    port: port,
    auth: '$method:$password',
    tag: name,
    rawUri: uri,
    params: {'method': method, 'password': password},
  );
}

(String, String) _splitMethodPass(String userinfo) {
  if (userinfo.contains(':') &&
      _knownSsMethods.contains(userinfo.split(':').first.toLowerCase())) {
    final i = userinfo.indexOf(':');
    return (userinfo.substring(0, i), userinfo.substring(i + 1));
  }
  String decoded;
  try {
    decoded = utf8.decode(_b64bytes(userinfo));
  } catch (_) {
    decoded = userinfo;
  }
  if (!decoded.contains(':')) throw ProxyUriError('ss: cannot split method:password');
  final i = decoded.indexOf(':');
  return (decoded.substring(0, i), decoded.substring(i + 1));
}

// --- Clash YAML ---------------------------------------------------------

List<Node> _parseClash(String text, {required String source}) {
  final Object? doc;
  try {
    doc = loadYaml(text);
  } catch (_) {
    return const [];
  }
  if (doc is! Map || doc['proxies'] is! List) return const [];
  const typeMap = {
    'vless': 'vless',
    'vmess': 'vmess',
    'trojan': 'trojan',
    'ss': 'shadowsocks',
    'shadowsocks': 'shadowsocks',
    'hysteria2': 'hysteria2',
    'hy2': 'hysteria2',
    'tuic': 'tuic',
  };
  final out = <Node>[];
  for (final raw in doc['proxies'] as List) {
    if (raw is! Map) continue;
    final ptype = '${raw['type']}'.toLowerCase();
    final protocol = typeMap[ptype];
    if (protocol == null) continue;
    final server = '${raw['server'] ?? ''}'.trim();
    final port = int.tryParse('${raw['port']}');
    if (server.isEmpty || port == null) continue;

    var network = _netMap['${raw['network'] ?? 'tcp'}'.toLowerCase()] ?? 'tcp';
    if (protocol == 'hysteria2' || protocol == 'tuic') network = 'quic';

    final reality = raw['reality-opts'];
    final tlsOn = raw['tls'] == true ||
        protocol == 'hysteria2' ||
        protocol == 'tuic' ||
        protocol == 'trojan';
    final params = <String, dynamic>{
      'security': reality is Map ? 'reality' : (tlsOn ? 'tls' : 'none'),
      if ((raw['sni'] ?? raw['servername'])?.toString().isNotEmpty == true)
        'sni': (raw['sni'] ?? raw['servername']).toString(),
      if (raw['client-fingerprint'] != null) 'fingerprint': '${raw['client-fingerprint']}',
      'allow_insecure': raw['skip-cert-verify'] == true,
    };
    if (reality is Map) {
      params['public_key'] = '${reality['public-key'] ?? ''}';
      if (reality['short-id'] != null) params['short_id'] = '${reality['short-id']}';
    }
    if (network == 'ws') {
      final w = raw['ws-opts'];
      if (w is Map) {
        params['path'] = '${w['path'] ?? '/'}';
        final headers = w['headers'];
        if (headers is Map && (headers['Host'] ?? headers['host']) != null) {
          params['host_header'] = '${headers['Host'] ?? headers['host']}';
        }
      }
    } else if (network == 'grpc') {
      final g = raw['grpc-opts'];
      if (g is Map) params['service_name'] = '${g['grpc-service-name'] ?? ''}';
    }

    final String auth;
    switch (protocol) {
      case 'vless':
        auth = '${raw['uuid'] ?? ''}';
        params['uuid'] = auth;
        if (raw['flow'] != null) params['flow'] = '${raw['flow']}';
      case 'vmess':
        auth = '${raw['uuid'] ?? ''}';
        params['uuid'] = auth;
        params['alter_id'] = int.tryParse('${raw['alterId'] ?? raw['alter-id'] ?? 0}') ?? 0;
        params['cipher'] = '${raw['cipher'] ?? 'auto'}';
      case 'trojan':
        auth = '${raw['password'] ?? ''}';
        params['password'] = auth;
      case 'shadowsocks':
        final method = '${raw['cipher'] ?? ''}';
        final pass = '${raw['password'] ?? ''}';
        params['method'] = method;
        params['password'] = pass;
        auth = '$method:$pass';
      case 'hysteria2':
        auth = '${raw['password'] ?? ''}';
        params['password'] = auth;
        if (raw['obfs'] != null) {
          params['obfs'] = 'salamander';
          params['obfs_password'] = raw['obfs-password'] ?? raw['obfs-param'];
        }
      case 'tuic':
        final uuid = '${raw['uuid'] ?? ''}';
        final pass = '${raw['password'] ?? ''}';
        params['uuid'] = uuid;
        params['password'] = pass;
        auth = '$uuid:$pass';
      default:
        continue;
    }
    final p = _Parsed(
      protocol: protocol,
      transport: network,
      host: server,
      port: port,
      auth: auth,
      tag: '${raw['name'] ?? '$server:$port'}',
      rawUri: 'clash://$protocol/$server:$port',
      params: params,
    );
    out.add(p._toNode(source: source));
  }
  return out;
}

// --- helpers ----------------------------------------------------------

int? _int(String? v) => v == null ? null : int.tryParse(v);

List<int> _b64bytes(String data) {
  var s = data.trim().replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
  s += '=' * ((4 - s.length % 4) % 4);
  return base64.decode(s);
}

String? _tryB64(String data) {
  try {
    final decoded = utf8.decode(_b64bytes(data));
    return decoded.contains('://') ? decoded : null;
  } catch (_) {
    return null;
  }
}
