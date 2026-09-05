import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/hints.dart';
import '../../app/theme/tokens.dart';
import '../../core/connection_controller.dart';
import '../../data/pool_repository.dart';
import '../../state/providers.dart';
import '../common/format.dart';
import '../common/power_button.dart';
import '../common/widgets.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _toggle(WidgetRef ref) async {
    final controller = ref.read(connectionControllerProvider);
    final resolve = ref.read(resolveSelectionProvider);
    await controller.toggle(resolve);
    final active = controller.activeNode;
    if (active != null && controller.status == ConnectionStatus.protected) {
      await ref.read(settingsProvider.notifier).rememberLastGoodNode(active.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(connectionControllerProvider);
    final poolAsync = ref.watch(poolProvider);
    final proMode = ref.watch(settingsProvider.select((s) => s.proMode));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Weronity'),
        actions: [
          if (proMode)
            IconButton(
              tooltip: 'Инспектор нод',
              icon: const Icon(Icons.travel_explore_rounded),
              onPressed: () => context.push('/settings'),
            ),
          IconButton(
            tooltip: 'Обновить пул',
            icon: poolAsync.isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
            onPressed: poolAsync.isLoading
                ? null
                : () => ref.read(poolProvider.notifier).refresh(),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(WSpace.lg, WSpace.sm, WSpace.lg, WSpace.xxl),
          children: [
            const SizedBox(height: WSpace.xl),
            Center(
              child: PowerButton(
                status: controller.status,
                onTap: () => _toggle(ref),
              ),
            ),
            const SizedBox(height: WSpace.xl),
            _StatusLine(controller: controller),
            const SizedBox(height: WSpace.xl),
            _SelectionCard(controller: controller),
            const SizedBox(height: WSpace.md),
            _TrafficCard(controller: controller),
            const SizedBox(height: WSpace.md),
            poolAsync.when(
              data: (snap) => _PoolFreshness(snapshot: snap),
              loading: () => const SizedBox.shrink(),
              error: (e, _) => _PoolFreshness.error('$e'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.controller});
  final ConnectionController controller;

  @override
  Widget build(BuildContext context) {
    final s = controller.status;
    final color = switch (s) {
      ConnectionStatus.protected => WColors.protected,
      ConnectionStatus.connecting => WColors.connecting,
      ConnectionStatus.error => WColors.danger,
      ConnectionStatus.disconnected => Theme.of(context).colorScheme.onSurfaceVariant,
    };
    return Column(
      children: [
        Text(
          s.label,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(color: color, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: WSpace.xs),
        if (s == ConnectionStatus.protected && controller.activeNode != null)
          Text(
            '${controller.activeNode!.displayFlag} '
            '${controller.activeNode!.geo.country ?? controller.activeNode!.endpoint.host}'
            ' · ${formatDuration(controller.traffic.elapsed)}',
            style: Theme.of(context).textTheme.bodyMedium,
          )
        else if (s == ConnectionStatus.error && controller.lastError != null)
          Text(
            controller.lastError!,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: WColors.danger),
          ),
      ],
    );
  }
}

class _SelectionCard extends ConsumerWidget {
  const _SelectionCard({required this.controller});
  final ConnectionController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sel = controller.selection;
    final countries = ref.watch(countryOptionsProvider);
    final nodeCount = ref.watch(nodesProvider).where((n) => n.health.alive).length;

    String title;
    String subtitle;
    Widget leading;
    if (sel.isAuto) {
      title = '⚡ Авто: самый быстрый';
      subtitle = '$nodeCount активных узлов';
      leading = const Icon(Icons.bolt_rounded, color: WColors.violetBright);
    } else if (sel.countryCode != null) {
      final c = countries.where((c) => c.code == sel.countryCode);
      title = sel.countryCode!;
      subtitle = c.isEmpty
          ? 'нет узлов'
          : '${c.first.nodeCount} узлов · лучший ${formatPing(c.first.bestPingMs)}';
      leading = Text(c.isEmpty ? '🏳️' : c.first.flag,
          style: const TextStyle(fontSize: 24));
    } else {
      final n = sel.node!;
      title = n.tag.isEmpty ? n.endpoint.host : n.tag;
      subtitle = '${n.protocol.toUpperCase()} · ${formatPing(n.health.pingMs)}';
      leading = Text(n.displayFlag, style: const TextStyle(fontSize: 24));
    }

    return SectionCard(
      onTap: () => context.push('/locations'),
      child: Row(
        children: [
          SizedBox(width: 32, child: Center(child: leading)),
          const SizedBox(width: WSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                    const SizedBox(width: WSpace.sm),
                    hintFor('auto_fastest'),
                  ],
                ),
                Text(subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
  }
}

class _TrafficCard extends StatelessWidget {
  const _TrafficCard({required this.controller});
  final ConnectionController controller;

  @override
  Widget build(BuildContext context) {
    final t = controller.traffic;
    return SectionCard(
      child: Row(
        children: [
          _Metric(
            icon: Icons.south_rounded,
            color: WColors.protected,
            value: formatSpeed(t.downBps),
            caption: 'Скачивание · ${formatBytes(t.downBytes)}',
          ),
          Container(width: 1, height: 40, color: Theme.of(context).colorScheme.outline),
          _Metric(
            icon: Icons.north_rounded,
            color: WColors.info,
            value: formatSpeed(t.upBps),
            caption: 'Отдача · ${formatBytes(t.upBytes)}',
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.icon,
    required this.color,
    required this.value,
    required this.caption,
  });

  final IconData icon;
  final Color color;
  final String value;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: WSpace.xs),
              Text(value, style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 2),
          Text(caption,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _PoolFreshness extends StatelessWidget {
  const _PoolFreshness({required this.snapshot}) : errorText = null;
  const _PoolFreshness.error(this.errorText) : snapshot = null;

  final PoolSnapshot? snapshot;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(color: muted);
    if (errorText != null) {
      return Center(child: Text('Пул: ошибка загрузки', style: style));
    }
    final s = snapshot!;
    final origin = switch (s.origin) {
      PoolOrigin.network => 'сеть',
      PoolOrigin.cache => 'кэш',
      PoolOrigin.bundledAsset => 'встроенный',
    };
    final when = s.origin == PoolOrigin.bundledAsset
        ? 'обновите для актуального списка'
        : 'обновлён ${relativeTime(s.fetchedAt)}';
    return Center(
      child: Text(
        '${s.pool.nodes.length} узлов · $origin · $when',
        style: style,
      ),
    );
  }
}
