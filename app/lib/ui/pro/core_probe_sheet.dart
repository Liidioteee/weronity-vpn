import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../core/connection_controller.dart' show pickLowestPing;
import '../../core/native/native_core.dart';
import '../../domain/country_names.dart';
import '../../domain/node.dart';
import '../../state/providers.dart';
import '../common/flag.dart';
import '../common/widgets.dart';

/// Phase 3.1 verification: boot the real sing-box engine for the fastest live
/// node, entirely separate from the stub `ConnectionController`. Shows the log
/// stream and the built-in self-test (one HTTP request through the loopback
/// SOCKS inbound).
Future<void> showCoreProbeSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _CoreProbeSheet(),
  );
}

class _CoreProbeSheet extends ConsumerStatefulWidget {
  const _CoreProbeSheet();

  @override
  ConsumerState<_CoreProbeSheet> createState() => _CoreProbeSheetState();
}

class _CoreProbeSheetState extends ConsumerState<_CoreProbeSheet> {
  final _core = NativeCore.instance();
  final _log = <String>[];
  Timer? _poll;
  Map<String, dynamic> _stats = const {};
  bool _running = false;
  Node? _node;

  @override
  void dispose() {
    _poll?.cancel();
    if (_core.isRunning()) _core.stop();
    super.dispose();
  }

  final _rng = Random();

  /// A random recommended alive node (so repeated runs try different ones);
  /// falls back to the lowest-ping alive node.
  Node? _pickNode() {
    final alive = ref.read(nodesProvider).where((n) => n.health.alive).toList();
    final recommended = alive.where((n) => n.recommended).toList();
    if (recommended.isNotEmpty) {
      return recommended[_rng.nextInt(recommended.length)];
    }
    return pickLowestPing(alive);
  }

  void _start() {
    final node = _pickNode();
    if (node == null) {
      setState(() => _log.add('нет живых узлов в пуле'));
      return;
    }
    final rc = _core.startNode(node.outbound);
    setState(() {
      _node = node;
      _running = rc == 0;
      _log
        ..clear()
        ..add(rc == 0
            ? 'wrnStart → 0 (движок поднят)'
            : 'wrnStart → $rc (ошибка, см. лог)');
    });
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
    _tick();
  }

  void _tick() {
    if (!mounted) return;
    final events = _core.drainEvents();
    final stats = _core.stats() ?? const {};
    setState(() {
      for (final e in events) {
        _log.add('${e['level'] ?? '?'}/${e['tag'] ?? '?'}: ${e['message'] ?? ''}');
      }
      if (_log.length > 300) _log.removeRange(0, _log.length - 300);
      _stats = stats;
      _running = _core.isRunning();
    });
    if (!_running) _poll?.cancel();
  }

  void _stop() {
    _core.stop();
    _poll?.cancel();
    _tick();
    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final self = (_stats['self_test'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final port = _stats['socks_port'];

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(WSpace.lg, 0, WSpace.lg, WSpace.xl),
        children: [
          Row(
            children: [
              Text('Проверка ядра sing-box',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (_running)
                const _Dot(color: WColors.protected, label: 'работает')
              else
                const _Dot(color: WColors.textMutedDark, label: 'остановлено'),
            ],
          ),
          const SizedBox(height: WSpace.xs),
          Text(
            'Запускает настоящий движок для самого быстрого узла из пула и '
            'делает один тестовый запрос через локальный SOCKS. Не влияет на '
            'основное подключение.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: WSpace.md),
          if (_node != null)
            SectionCard(
              padding: const EdgeInsets.all(WSpace.md),
              child: Row(
                children: [
                  FlagView(_node!.countryCode, size: 24),
                  const SizedBox(width: WSpace.sm),
                  Expanded(
                    child: Text(
                      '${_node!.tag.isEmpty ? _node!.endpoint.host : _node!.tag}'
                      ' · ${countryNameRu(_node!.countryCode)}'
                      ' · ${_node!.protocol.toUpperCase()}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: WSpace.sm),
          Wrap(
            spacing: WSpace.md,
            runSpacing: WSpace.xs,
            children: [
              _Stat('SOCKS', port == null ? '—' : '127.0.0.1:$port'),
              _Stat('uptime', '${_stats['uptime_ms'] ?? 0} мс'),
              _Stat(
                'self-test',
                (self['done'] == true)
                    ? '${self['ok'] == true ? 'ok' : 'fail'} · '
                        '${self['latency_ms'] ?? '?'} мс · ${self['status'] ?? ''}'
                    : (_running ? 'идёт…' : '—'),
              ),
            ],
          ),
          const SizedBox(height: WSpace.md),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _running ? null : _start,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Запустить'),
                ),
              ),
              const SizedBox(width: WSpace.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _running ? _stop : null,
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('Остановить'),
                ),
              ),
            ],
          ),
          const SizedBox(height: WSpace.md),
          Container(
            constraints: const BoxConstraints(minHeight: 120, maxHeight: 280),
            width: double.infinity,
            padding: const EdgeInsets.all(WSpace.sm),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(WRadius.md),
              border: Border.all(color: Theme.of(context).colorScheme.outline),
            ),
            child: _log.isEmpty
                ? Text('лог пуст',
                    style: Theme.of(context).textTheme.bodySmall)
                : SingleChildScrollView(
                    reverse: true,
                    child: Text(
                      _log.join('\n'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontFamilyFallback: ['Consolas', 'Menlo', 'monospace'],
                        fontSize: 11,
                        height: 1.45,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: WSpace.xs),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      );
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )),
          Text(value, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}
