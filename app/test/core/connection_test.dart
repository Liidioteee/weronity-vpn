import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/core/connection_controller.dart';
import 'package:weronity/domain/node.dart';

Node _n(String id, {int? ping, bool alive = true}) => Node(
      id: id,
      protocol: 'vless',
      transport: 'tcp',
      tag: id,
      endpoint: Endpoint(host: '$id.net', port: 443),
      geo: const Geo(country: 'DE'),
      health: Health(tcpOk: alive, tlsOk: alive, pingMs: ping, checkedAt: null),
      lifetime: Lifetime.zero,
      classification: Classification.empty,
      provenance: Provenance.unknown,
      recommended: false,
      rawUri: '',
      outbound: const {},
    );

void main() {
  test('pickLowestPing ignores dead nodes', () {
    final best = pickLowestPing([
      _n('a', ping: 200),
      _n('b', ping: 20, alive: false),
      _n('c', ping: 80),
    ]);
    expect(best?.id, 'c');
  });

  test('connect → protected, disconnect → disconnected', () async {
    final c = ConnectionController();
    addTearDown(c.dispose);

    expect(c.status, ConnectionStatus.disconnected);
    await c.connect((_) => _n('a', ping: 50));
    expect(c.status, ConnectionStatus.protected);
    expect(c.activeNode?.id, 'a');
    expect(c.isActive, isTrue);

    await c.disconnect();
    expect(c.status, ConnectionStatus.disconnected);
    expect(c.activeNode, isNull);
    expect(c.traffic.upBytes, 0);
  });

  test('connect with no resolvable node → error', () async {
    final c = ConnectionController();
    addTearDown(c.dispose);
    await c.connect((_) => null);
    expect(c.status, ConnectionStatus.error);
    expect(c.lastError, isNotNull);
  });

  test('selection is remembered', () {
    final c = ConnectionController();
    addTearDown(c.dispose);
    c.select(const Selection.country('NL'));
    expect(c.selection.countryCode, 'NL');
    expect(c.selection.isAuto, isFalse);
  });

  test('toggle flips between connect and disconnect', () async {
    final c = ConnectionController();
    addTearDown(c.dispose);
    await c.toggle((_) => _n('a', ping: 10));
    expect(c.isActive, isTrue);
    await c.toggle((_) => _n('a', ping: 10));
    expect(c.status, ConnectionStatus.disconnected);
  });
}
