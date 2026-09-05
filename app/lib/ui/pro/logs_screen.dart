import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/hints.dart';
import '../../app/theme/tokens.dart';
import '../../core/log_controller.dart';
import '../../state/providers.dart';

/// Pro → Логи. Console view of the core log ring buffer with level filters.
/// Phase 2 feeds it synthetic lines; Phase 3 pipes sing-box's real stream here.
class LogsScreen extends ConsumerStatefulWidget {
  const LogsScreen({super.key});

  @override
  ConsumerState<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends ConsumerState<LogsScreen> {
  final _scroll = ScrollController();
  final _levels = {...LogLevel.values};
  bool _follow = true;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _jumpToEnd() {
    if (!_follow || !_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final log = ref.watch(logControllerProvider);
    final messenger = ScaffoldMessenger.of(context);
    final lines =
        log.lines.where((l) => _levels.contains(l.level)).toList(growable: false);
    _jumpToEnd();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            WSpace.md,
            WSpace.sm,
            WSpace.md,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: WSpace.xs,
                  children: [
                    for (final lvl in LogLevel.values)
                      FilterChip(
                        label: Text(lvl.label),
                        selected: _levels.contains(lvl),
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        onSelected: (on) => setState(() {
                          if (on) {
                            _levels.add(lvl);
                          } else {
                            _levels.remove(lvl);
                          }
                        }),
                        labelStyle: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(
                              color: _levels.contains(lvl)
                                  ? Colors.white
                                  : lvl.color,
                            ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: WSpace.xs),
                child: hintFor('core_logs'),
              ),
              IconButton(
                tooltip: _follow ? 'Не прокручивать' : 'Прокручивать к новым',
                onPressed: () => setState(() => _follow = !_follow),
                icon: Icon(
                  _follow
                      ? Icons.vertical_align_bottom_rounded
                      : Icons.pause_circle_outline_rounded,
                ),
              ),
              IconButton(
                tooltip: 'Копировать всё',
                onPressed: lines.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(
                          ClipboardData(text: log.dump(lines)),
                        );
                        messenger.showSnackBar(
                          const SnackBar(content: Text('Логи скопированы')),
                        );
                      },
                icon: const Icon(Icons.copy_all_rounded),
              ),
              IconButton(
                tooltip: 'Очистить',
                onPressed: log.length == 0 ? null : log.clear,
                icon: const Icon(Icons.delete_sweep_rounded),
              ),
            ],
          ),
        ),
        const Divider(height: WSpace.md),
        Expanded(
          child: lines.isEmpty
              ? Center(
                  child: Text(
                    'Пока пусто — подключитесь, чтобы увидеть работу ядра.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              : Scrollbar(
                  controller: _scroll,
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(
                      WSpace.md,
                      0,
                      WSpace.md,
                      WSpace.lg,
                    ),
                    itemCount: lines.length,
                    itemBuilder: (context, i) => _LogRow(line: lines[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.line});
  final LogLine line;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    const mono = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: ['Consolas', 'Menlo', 'monospace'],
      fontSize: 12,
      height: 1.5,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: RichText(
        text: TextSpan(
          style: mono.copyWith(color: Theme.of(context).colorScheme.onSurface),
          children: [
            TextSpan(text: '${line.clock}  ', style: mono.copyWith(color: muted)),
            TextSpan(
              text: line.level.label.padRight(5),
              style: mono.copyWith(
                color: line.level.color,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(text: '  [${line.tag}] ', style: mono.copyWith(color: muted)),
            TextSpan(text: line.message),
          ],
        ),
      ),
    );
  }
}
