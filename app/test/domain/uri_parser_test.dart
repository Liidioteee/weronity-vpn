import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/domain/node.dart';
import 'package:weronity/domain/uri_parser.dart';

const _vlessReality =
    'vless://f8738084-d3e4-457b-a15e-10d85709681f@ex.net:443?type=tcp&security=reality'
    '&pbk=PUBKEY&sid=a1b2c3&fp=chrome&sni=www.apple.com&flow=xtls-rprx-vision#DE-Reality';
const _vlessWs =
    'vless://uuid-2@cdn.example:443?type=ws&security=tls&sni=cdn.example&host=cdn.example&path=%2Fws#NL-WS';
const _trojanGrpc =
    'trojan://Tr0j4nP4ss@tj.example:443?type=grpc&security=tls&serviceName=svc&sni=tj.example#FR-Trojan';
const _hy2 =
    'hysteria2://pw@au.example:443?insecure=1&sni=speed.example&obfs=salamander&obfs-password=s3cr3t&up=10&down=50#AU-Hy2';
const _ssSip002 = 'ss://YWVzLTI1Ni1nY206c2VjcmV0@ss.example:8388#SG-SS';
const _ss2022 = 'ss://2022-blake3-aes-128-gcm:c2hvcnRrZXk=@ss2.example:443#SE-SS';
const _tuic =
    'tuic://b7f1c2a9-d4e5-4a6b-8c7d-0e1f2a3b4c5d:pw@tu.example:2053?sni=tu.example&congestion_control=bbr#FI-TUIC';
// vmess base64 of a small JSON
final _vmess = 'vmess://${base64.encode(utf8.encode(jsonEncode({
      'v': '2',
      'ps': 'JP-VMess',
      'add': 'jp.example',
      'port': '443',
      'id': 'vmess-uuid',
      'aid': '0',
      'net': 'ws',
      'path': '/vm',
      'host': 'jp.example',
      'tls': 'tls',
    })))}';

void main() {
  test('vless reality → node + outbound', () {
    final n = parseProxyUri(_vlessReality)!;
    expect(n.protocol, 'vless');
    expect(n.transport, 'tcp');
    expect(n.classification.security, NodeSecurity.reality);
    expect(n.classification.flow, 'xtls-rprx-vision');
    expect(n.isCustom, isTrue);
    expect(n.provenance.source, 'custom');
    expect(n.outbound['type'], 'vless');
    expect(n.outbound['uuid'], 'f8738084-d3e4-457b-a15e-10d85709681f');
    expect((n.outbound['tls'] as Map)['reality'], {'enabled': true, 'public_key': 'PUBKEY', 'short_id': 'a1b2c3'});
  });

  test('vless ws transport block', () {
    final n = parseProxyUri(_vlessWs)!;
    expect(n.transport, 'ws');
    expect(n.outbound['transport'], {'type': 'ws', 'path': '/ws', 'headers': {'Host': 'cdn.example'}});
  });

  test('trojan grpc', () {
    final n = parseProxyUri(_trojanGrpc)!;
    expect(n.protocol, 'trojan');
    expect(n.outbound['password'], 'Tr0j4nP4ss');
    expect(n.outbound['transport'], {'type': 'grpc', 'service_name': 'svc'});
  });

  test('hysteria2 with salamander obfs', () {
    final n = parseProxyUri(_hy2)!;
    expect(n.protocol, 'hysteria2');
    expect(n.transport, 'quic');
    expect(n.classification.udp, isTrue);
    expect(n.outbound['up_mbps'], 10);
    expect(n.outbound['obfs'], {'type': 'salamander', 'password': 's3cr3t'});
    expect((n.outbound['tls'] as Map)['insecure'], true);
  });

  test('shadowsocks SIP002 and 2022 forms', () {
    final a = parseProxyUri(_ssSip002)!;
    expect(a.outbound['method'], 'aes-256-gcm');
    expect(a.outbound['password'], 'secret');
    final b = parseProxyUri(_ss2022)!;
    expect(b.outbound['method'], '2022-blake3-aes-128-gcm');
    expect(b.outbound['password'], 'c2hvcnRrZXk=');
  });

  test('tuic v5', () {
    final n = parseProxyUri(_tuic)!;
    expect(n.protocol, 'tuic');
    expect(n.outbound['uuid'], 'b7f1c2a9-d4e5-4a6b-8c7d-0e1f2a3b4c5d');
    expect(n.outbound['password'], 'pw');
    expect(n.outbound['congestion_control'], 'bbr');
  });

  test('vmess base64 json', () {
    final n = parseProxyUri(_vmess)!;
    expect(n.protocol, 'vmess');
    expect(n.transport, 'ws');
    expect(n.endpoint.host, 'jp.example');
    expect(n.outbound['uuid'], 'vmess-uuid');
    expect(n.classification.security, NodeSecurity.tls);
  });

  test('garbage returns null', () {
    expect(parseProxyUri('wireguard://nope'), isNull);
    expect(parseProxyUri('vless://'), isNull);
    expect(parseProxyUri('not a uri at all'), isNull);
  });

  test('stable id is deterministic across cosmetic differences', () {
    final a = parseProxyUri('vless://u@Host.Example:443?type=tcp&security=tls&sni=a.com#one')!;
    final b = parseProxyUri('vless://u@host.example.:443?type=tcp&security=tls&sni=a.com#two')!;
    expect(a.id, b.id);
  });

  test('extractProxyUris pulls URIs out of a mixed blob', () {
    const text = '# header\n$_vlessReality\njunk line\n$_hy2\n';
    expect(extractProxyUris(text), [_vlessReality, _hy2]);
  });

  test('parseSubscription decodes a base64 list', () {
    const list = '$_vlessReality\n$_trojanGrpc\n$_tuic';
    final blob = base64.encode(utf8.encode(list));
    final nodes = parseSubscription(blob, source: 'subscription:test');
    expect(nodes.map((n) => n.protocol).toSet(), {'vless', 'trojan', 'tuic'});
    expect(nodes.every((n) => n.provenance.source == 'subscription:test'), isTrue);
  });

  test('parseSubscription reads a Clash YAML proxies list', () {
    const yaml = '''
proxies:
  - name: DE-Reality
    type: vless
    server: reality.example
    port: 443
    uuid: clash-uuid
    network: tcp
    tls: true
    servername: www.apple.com
    reality-opts:
      public-key: PK
      short-id: ab
  - name: SG-SS
    type: ss
    server: ss.example
    port: 8388
    cipher: aes-256-gcm
    password: p
  - name: broken
    type: vmess
''';
    final nodes = parseSubscription(yaml, source: 'subscription:clash');
    expect(nodes.length, 2);
    final v = nodes.firstWhere((n) => n.protocol == 'vless');
    expect(v.classification.security, NodeSecurity.reality);
    expect((v.outbound['tls'] as Map)['reality'], containsPair('public_key', 'PK'));
  });
}
