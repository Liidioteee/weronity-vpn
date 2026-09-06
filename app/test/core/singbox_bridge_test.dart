@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/core/connection_controller.dart';
import 'package:weronity/core/native/native_core.dart';
import 'package:weronity/core/singbox_bridge.dart';
import 'package:weronity/data/settings_repository.dart';
import 'package:weronity/domain/node.dart';

Node _n(String id) => Node(
      id: id,
      protocol: 'vless',
      transport: 'tcp',
      tag: id,
      endpoint: Endpoint(host: '$id.example', port: 443),
      geo: const Geo(country: 'DE'),
      health: const Health(tcpOk: true, tlsOk: true, pingMs: 40, checkedAt: null),
      lifetime: Lifetime.zero,
      classification: Classification.empty,
      provenance: Provenance.unknown,
      recommended: false,
      rawUri: '',
      outbound: const {'type': 'vless', 'server': 'x', 'server_port': 443},
    );

SingBoxBridge _bridge({
  ConnectionMode mode = ConnectionMode.proxy,
  int port = 55555,
  List<String>? log,
}) =>
    SingBoxBridge(
      core: NativeCore.instance(),
      modeOf: () => mode,
      portOf: () => port,
      onLog: log == null ? null : (l, t, m) => log.add('$l/$t: $m'),
    );

void main() {
  test('starts in a clean disconnected state', () {
    final b = _bridge();
    addTearDown(b.dispose);
    expect(b.status, ConnectionStatus.disconnected);
    expect(b.isActive, isFalse);
    expect(b.activeNode, isNull);
    expect(b.traffic.upBytes, 0);
    expect(b.history, isEmpty);
    expect(b.proxyEndpoint, isNull);
  });

  test('VPN mode attempts to start; without the core it fails with an '
      'admin-rights hint', () async {
    final b = _bridge(mode: ConnectionMode.vpn);
    addTearDown(b.dispose);
    if (b.core.isAvailable) return; // real core would try to create a TUN

    expect(b.isVpn, isTrue);
    await b.connect((_) => _n('a'));
    expect(b.status, ConnectionStatus.error);
    expect(b.lastError, contains('администратора'));
    expect(b.isActive, isFalse);
  });

  test('proxy connect fails gracefully when the core is unavailable', () async {
    final b = _bridge();
    addTearDown(b.dispose);
    if (b.core.isAvailable) return; // only meaningful without the DLL

    await b.connect((_) => _n('a'));
    expect(b.status, ConnectionStatus.error);
    expect(b.lastError, isNotNull);
    expect(b.isActive, isFalse);
  });

  test('connect with no resolvable node → error', () async {
    final b = _bridge();
    addTearDown(b.dispose);
    if (b.core.isAvailable) return;
    await b.connect((_) => null);
    expect(b.status, ConnectionStatus.error);
    expect(b.lastError, contains('узлов'));
  });

  test('selecting a location while idle just records it', () async {
    final b = _bridge();
    addTearDown(b.dispose);
    final ok = await b.select(const Selection.country('NL'), (_) => null);
    expect(ok, isTrue);
    expect(b.selection.countryCode, 'NL');
  });

  test('disconnect from disconnected is a safe no-op', () async {
    final b = _bridge();
    addTearDown(b.dispose);
    await b.disconnect();
    expect(b.status, ConnectionStatus.disconnected);
  });

  test('satisfies the ConnectionEngine contract', () {
    final b = _bridge();
    addTearDown(b.dispose);
    expect(b, isA<ConnectionEngine>());
  });
}
