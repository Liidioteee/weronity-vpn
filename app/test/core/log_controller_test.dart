import 'package:flutter_test/flutter_test.dart';
import 'package:weronity/core/log_controller.dart';

void main() {
  test('parses level strings, unknown falls back to info', () {
    expect(LogLevel.parse('DEBUG'), LogLevel.debug);
    expect(LogLevel.parse('warning'), LogLevel.warn);
    expect(LogLevel.parse('err'), LogLevel.error);
    expect(LogLevel.parse('whatever'), LogLevel.info);
  });

  test('ring buffer keeps only the last [capacity] lines', () {
    final log = LogController(capacity: 5);
    for (var i = 0; i < 20; i++) {
      log.add('info', 'test', 'line $i');
    }
    expect(log.length, 5);
    expect(log.lines.first.message, 'line 15');
    expect(log.lines.last.message, 'line 19');
  });

  test('clear empties the buffer and notifies once', () {
    final log = LogController();
    var notifications = 0;
    log.addListener(() => notifications++);

    log.add('info', 'core', 'hi');
    expect(log.length, 1);
    log.clear();
    expect(log.length, 0);
    log.clear(); // no-op, must not notify again
    expect(notifications, 2); // one add, one clear
  });

  test('dump renders every line as timestamp + level + tag + message', () {
    final log = LogController();
    log.add('warn', 'route', 'switching');
    final line = log.dump();
    expect(line, contains('WARN'));
    expect(line, contains('[route]'));
    expect(line, contains('switching'));
  });
}
