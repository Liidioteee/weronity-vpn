import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/tokens.dart';
import '../../core/connection_controller.dart';
import '../../data/node_filter.dart';
import '../../state/providers.dart';
import '../common/format.dart';
import '../common/widgets.dart';

class LocationsScreen extends ConsumerStatefulWidget {
  const LocationsScreen({super.key});

  @override
  ConsumerState<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends ConsumerState<LocationsScreen> {
  String _query = '';

  void _choose(Selection sel) {
    ref.read(connectionControllerProvider).select(sel);
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(connectionControllerProvider);
    final all = ref.watch(countryOptionsProvider);
    final q = _query.trim().toLowerCase();
    final countries = q.isEmpty
        ? all
        : all.where((c) => c.code.toLowerCase().contains(q)).toList();
    final sel = controller.selection;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Локация'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(WSpace.lg, 0, WSpace.lg, WSpace.sm),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'Поиск страны (код ISO)',
                prefixIcon: Icon(Icons.search_rounded),
                isDense: true,
              ),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(WSpace.lg, WSpace.sm, WSpace.lg, WSpace.xxl),
        children: [
          SectionCard(
            onTap: () => _choose(const Selection.auto()),
            child: Row(
              children: [
                const Icon(Icons.bolt_rounded, color: WColors.violetBright, size: 28),
                const SizedBox(width: WSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('⚡ Авто: самый быстрый',
                          style: Theme.of(context).textTheme.titleMedium),
                      Text(
                        'Выбор и переключение узлов автоматически',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (sel.isAuto)
                  const Icon(Icons.check_circle_rounded, color: WColors.violet),
              ],
            ),
          ),
          const SizedBox(height: WSpace.lg),
          Text('Страны', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: WSpace.sm),
          if (countries.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: WSpace.xxl),
              child: EmptyState(
                icon: Icons.public_off_rounded,
                title: 'Нет доступных локаций',
                subtitle: 'Обновите пул на главном экране',
              ),
            )
          else
            ...countries.map(
              (c) => _CountryTile(
                option: c,
                selected: sel.countryCode == c.code,
                onTap: () => _choose(Selection.country(c.code)),
              ),
            ),
        ],
      ),
    );
  }
}

class _CountryTile extends StatelessWidget {
  const _CountryTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final CountryOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: WSpace.sm),
      child: SectionCard(
        padding: const EdgeInsets.symmetric(horizontal: WSpace.lg, vertical: WSpace.md),
        onTap: onTap,
        child: Row(
          children: [
            Text(option.flag, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: WSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(option.code,
                      style: Theme.of(context).textTheme.titleMedium),
                  Text(
                    '${option.nodeCount} узлов'
                    '${option.recommendedCount > 0 ? ' · ${option.recommendedCount} реком.' : ''}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            _PingPill(ms: option.bestPingMs),
            if (selected) ...[
              const SizedBox(width: WSpace.sm),
              const Icon(Icons.check_circle_rounded, color: WColors.violet),
            ],
          ],
        ),
      ),
    );
  }
}

class _PingPill extends StatelessWidget {
  const _PingPill({required this.ms});
  final int? ms;

  @override
  Widget build(BuildContext context) {
    final color = switch (ms) {
      null => Theme.of(context).colorScheme.onSurfaceVariant,
      < 120 => WColors.protected,
      < 250 => WColors.connecting,
      _ => WColors.danger,
    };
    return Tag(formatPing(ms), color: color, icon: Icons.speed_rounded);
  }
}
