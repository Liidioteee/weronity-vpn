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

  test('selecting a location while idle just records it', () async {
    final c = ConnectionController();
    addTearDown(c.dispose);
    final ok = await c.select(const Selection.country('NL'), (_) => null);
    expect(ok, isTrue);
    expect(c.selection.countryCode, 'NL');
    expect(c.selection.isAuto, isFalse);
  });

  test('changing location while connected hot-swaps the active node', () async {
    final c = ConnectionController();
    addTearDown(c.dispose);
    await c.connect((_) => _n('de', ping: 30));
    expect(c.activeNode?.id, 'de');

    final ok = await c.select(
      const Selection.country('NL'),
      (sel) => sel.countryCode == 'NL' ? _n('nl', ping: 40) : null,
    );
    expect(ok, isTrue);
    expect(c.status, ConnectionStatus.protected); // session never dropped
    expect(c.activeNode?.id, 'nl');
    expect(c.selection.countryCode, 'NL');
  });

  test('switching to a location with no node keeps the current session', () async {
    final c = ConnectionController();
    addTearDown(c.dispose);
    await c.connect((_) => _n('de', ping: 30));

    final ok = await c.select(const Selection.country('ZZ'), (_) => null);
    expect(ok, isFalse);
    expect(c.status, ConnectionStatus.protected);
    expect(c.activeNode?.id, 'de');
  });

  test('toggle flips between connect and disconnect', () async {
    final c = ConnectionController();
    addTearDown(c.dispose);
    await c.toggle((_) => _n('a', ping: 10));
    expect(c.isActive, isTrue);
    await c.toggle((_) => _n('a', ping: 10));
    expect(c.status, ConnectionStatus.disconnected);
  });

  test('debugTick fills the traffic history; disconnect clears it', () async {
    final c = ConnectionController();
    addTearDown(c.dispose);
    await c.connect((_) => _n('a', ping: 50));

    expect(c.history, isEmpty);
    for (var i = 0; i < 5; i++) {
      c.debugTick();
    }
    expect(c.history, hasLength(5));
    expect(c.history.last.pingMs, inInclusiveRange(35, 65)); // 50 ± 15
    expect(c.traffic.downBytes, greaterThan(0));

    await c.disconnect();
    expect(c.history, isEmpty);
  });

  test('history is capped at historyCapacity', () async {
    final c = ConnectionController();
    addTearDown(c.dispose);
    await c.connect((_) => _n('a', ping: 20));
    for (var i = 0; i < ConnectionController.historyCapacity + 50; i++) {
      c.debugTick();
    }
    expect(c.history, hasLength(ConnectionController.historyCapacity));
  });

  test('connect / disconnect emit core log lines through onLog', () async {
    final logs = <String>[];
    final c = ConnectionController(
      onLog: (level, tag, message) => logs.add('$level/$tag: $message'),
    );
    addTearDown(c.dispose);

    await c.connect((_) => _n('a', ping: 40));
    expect(logs.where((l) => l.startsWith('info/core')), isNotEmpty);
    expect(logs.any((l) => l.contains('соединение установлено')), isTrue);

    await c.disconnect();
    expect(logs.any((l) => l.contains('туннель закрыт')), isTrue);
  });

  test('a failed connect logs an error line', () async {
    final logs = <String>[];
    final c = ConnectionController(
      onLog: (level, tag, message) => logs.add('$level/$tag'),
    );
    addTearDown(c.dispose);
    await c.connect((_) => null);
    expect(logs, contains('error/core'));
  });

  test('hot-swap logs route lines; a dead target logs a warning', () async {
    final logs = <String>[];
    final c = ConnectionController(
      onLog: (level, tag, message) => logs.add('$level/$tag: $message'),
    );
    addTearDown(c.dispose);
    await c.connect((_) => _n('de', ping: 30));

    await c.select(
      const Selection.country('NL'),
      (sel) => sel.countryCode == 'NL' ? _n('nl', ping: 40) : null,
    );
    expect(logs.any((l) => l.contains('переключение завершено')), isTrue);

    await c.select(const Selection.country('ZZ'), (_) => null);
    expect(logs.any((l) => l.startsWith('warn/route')), isTrue);
  });
}
