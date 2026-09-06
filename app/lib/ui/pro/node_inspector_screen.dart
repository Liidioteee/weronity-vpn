import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../core/connection_controller.dart';
import '../../data/node_filter.dart';
import '../../domain/country_names.dart';
import '../../domain/node.dart';
import '../../state/preflight.dart';
import '../../state/providers.dart';
import '../common/flag.dart';
import '../common/format.dart';
import '../common/widgets.dart';

/// Pro → Ноды. A filter surface over [filterProvider] plus a per-node sheet that
/// exposes the raw sing-box `outbound` and a "connect to this node" action.
class NodeInspectorScreen extends ConsumerWidget {
  const NodeInspectorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(nodesProvider);
    final shown = ref.watch(filteredNodesProvider);
    final filter = ref.watch(filterProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        WSpace.lg,
        WSpace.md,
        WSpace.lg,
        WSpace.xxl,
      ),
      children: [
        _FilterPanel(all: all, filter: filter, shownCount: shown.length),
        const SizedBox(height: WSpace.sm),
        _PreflightBar(nodes: shown),
        const SizedBox(height: WSpace.md),
        if (shown.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: WSpace.xl),
            child: EmptyState(
              icon: Icons.filter_alt_off_rounded,
              title: 'Под фильтр ничего не подходит',
              subtitle: 'Ослабьте условия или сбросьте фильтр.',
            ),
          )
        else
          for (var i = 0; i < shown.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: WSpace.sm),
              child: FadeSlideIn(
                delay: Duration(milliseconds: 12 * (i < 12 ? i : 12)),
                child: _NodeRow(
                  node: shown[i],
                  onTap: () => _showNodeSheet(context, ref, shown[i]),
                ),
              ),
            ),
      ],
    );
  }
}

class _FilterPanel extends ConsumerWidget {
  const _FilterPanel({
    required this.all,
    required this.filter,
    required this.shownCount,
  });

  final List<Node> all;
  final NodeFilter filter;
  final int shownCount;

  void _update(WidgetRef ref, NodeFilter Function(NodeFilter) f) =>
      ref.read(filterProvider.notifier).update(f);

  Set<T> _toggled<T>(Set<T> set, T value) {
    final next = {...set};
    if (!next.remove(value)) next.add(value);
    return next;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final protocols = (all.map((n) => n.protocol).toSet().toList()..sort());
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return SectionCard(
      padding: const EdgeInsets.all(WSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '$shownCount из ${all.length}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Spacer(),
              if (filter.isActive)
                TextButton.icon(
                  onPressed: () => ref.read(filterProvider.notifier).reset(),
                  icon: const Icon(Icons.restart_alt_rounded, size: 16),
                  label: const Text('Сброс'),
                ),
            ],
          ),
          const SizedBox(height: WSpace.xs),
          Row(
            children: [
              _Label('Сортировка', muted),
              const SizedBox(width: WSpace.md),
              DropdownButton<NodeSort>(
                value: filter.sort,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: [
                  for (final s in NodeSort.values)
                    DropdownMenuItem(value: s, child: Text(s.label)),
                ],
                onChanged: (v) =>
                    v == null ? null : _update(ref, (f) => f.copyWith(sort: v)),
              ),
            ],
          ),
          const SizedBox(height: WSpace.sm),
          _ChipRow(
            children: [
              _Chip(
                label: 'Рекомендованные',
                selected: filter.recommendedOnly,
                onTap: () => _update(
                  ref,
                  (f) => f.copyWith(recommendedOnly: !f.recommendedOnly),
                ),
              ),
              _Chip(
                label: 'Только свои',
                selected: filter.customOnly,
                onTap: () => _update(
                  ref,
                  (f) => f.copyWith(customOnly: !f.customOnly),
                ),
              ),
              _Chip(
                label: 'UDP',
                selected: filter.udpOnly,
                onTap: () =>
                    _update(ref, (f) => f.copyWith(udpOnly: !f.udpOnly)),
              ),
              _Chip(
                label: 'С мёртвыми',
                selected: !filter.aliveOnly,
                onTap: () =>
                    _update(ref, (f) => f.copyWith(aliveOnly: !f.aliveOnly)),
              ),
            ],
          ),
          if (protocols.length > 1) ...[
            const SizedBox(height: WSpace.sm),
            _Label('Протокол', muted),
            _ChipRow(
              children: [
                for (final p in protocols)
                  _Chip(
                    label: p.toUpperCase(),
                    selected: filter.protocols.contains(p),
                    onTap: () => _update(
                      ref,
                      (f) => f.copyWith(
                        protocols: _toggled(f.protocols, p),
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: WSpace.sm),
          _Label('Шифрование', muted),
          _ChipRow(
            children: [
              for (final s in NodeSecurity.values)
                _Chip(
                  label: s.label,
                  selected: filter.securities.contains(s),
                  onTap: () => _update(
                    ref,
                    (f) => f.copyWith(securities: _toggled(f.securities, s)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: WSpace.sm),
          _Label('Время жизни', muted),
          _ChipRow(
            children: [
              for (final k in LifetimeClass.values)
                _Chip(
                  label: k.label,
                  selected: filter.lifetimeClasses.contains(k),
                  onTap: () => _update(
                    ref,
                    (f) => f.copyWith(
                      lifetimeClasses: _toggled(f.lifetimeClasses, k),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: WSpace.sm),
          OutlinedButton.icon(
            onPressed: () => _pickCountries(context, ref),
            icon: const Icon(Icons.public_rounded, size: 18),
            label: Text(
              filter.countries.isEmpty
                  ? 'Любая страна'
                  : '${filter.countries.length} стран выбрано',
            ),
          ),
          const SizedBox(height: WSpace.sm),
          _SliderRow(
            label: 'Мин. стабильность',
            value: filter.minStability,
            max: 1,
            display: filter.minStability == 0
                ? 'выкл'
                : filter.minStability.toStringAsFixed(2),
            onChanged: (v) => _update(ref, (f) => f.copyWith(minStability: v)),
          ),
          _SliderRow(
            label: 'Макс. пинг',
            value: filter.maxPingMs.toDouble(),
            max: 1000,
            divisions: 20,
            display: filter.maxPingMs == 0 ? 'выкл' : '${filter.maxPingMs} мс',
            onChanged: (v) =>
                _update(ref, (f) => f.copyWith(maxPingMs: v.round())),
          ),
        ],
      ),
    );
  }

  Future<void> _pickCountries(BuildContext context, WidgetRef ref) async {
    final options = ref.read(countryOptionsProvider);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, scroll) => Consumer(
          builder: (context, ref, _) {
            final selected = ref.watch(
              filterProvider.select((f) => f.countries),
            );
            return ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(
                WSpace.lg,
                0,
                WSpace.lg,
                WSpace.xl,
              ),
              children: [
                Row(
                  children: [
                    Text(
                      'Страны',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    if (selected.isNotEmpty)
                      TextButton(
                        onPressed: () => _update(
                          ref,
                          (f) => f.copyWith(countries: const {}),
                        ),
                        child: const Text('Очистить'),
                      ),
                  ],
                ),
                for (final o in options)
                  CheckboxListTile(
                    value: selected.contains(o.code),
                    onChanged: (_) => _update(
                      ref,
                      (f) => f.copyWith(countries: _toggled(f.countries, o.code)),
                    ),
                    title: CountryLabel(o.code, flagSize: 20),
                    subtitle: Text(
                      '${o.nodeCount} узлов · лучший ${formatPing(o.bestPingMs)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: WSpace.xs),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: color, letterSpacing: 1),
        ),
      );
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: WSpace.xs,
        runSpacing: WSpace.xs,
        children: children,
      );
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onTap(),
      visualDensity: VisualDensity.compact,
      labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: selected
                ? Colors.white
                : Theme.of(context).colorScheme.onSurface,
          ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.max,
    required this.display,
    required this.onChanged,
    this.divisions,
  });

  final String label;
  final double value;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;
  final int? divisions;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(0, max),
            max: max,
            divisions: divisions,
            label: display,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            display,
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    );
  }
}

/// A row of preflight controls above the node list.
class _PreflightBar extends ConsumerWidget {
  const _PreflightBar({required this.nodes});
  final List<Node> nodes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final probes = ref.watch(preflightProvider);
    final busy = probes.values.any((p) => p.verdict == ProbeVerdict.testing);
    final done = nodes.where((n) => probes[n.id]?.verdict.isDone ?? false).length;
    final core = ref.watch(nativeCoreProvider);

    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: (!core.isAvailable || nodes.isEmpty || busy)
                ? null
                : () => ref
                    .read(preflightProvider.notifier)
                    .testAll(List<Node>.from(nodes)),
            icon: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_tethering_rounded, size: 16),
            label: Text(busy
                ? 'Проверка… ($done/${nodes.length})'
                : 'Проверить видимые (${nodes.length})'),
          ),
        ),
        if (probes.isNotEmpty) ...[
          const SizedBox(width: WSpace.sm),
          IconButton(
            tooltip: 'Сбросить результаты',
            icon: const Icon(Icons.clear_rounded, size: 18),
            onPressed: busy
                ? null
                : () => ref.read(preflightProvider.notifier).clear(),
          ),
        ],
      ],
    );
  }
}

Color verdictColor(ProbeVerdict v) => switch (v) {
      ProbeVerdict.works => WColors.protected,
      ProbeVerdict.slow => WColors.connecting,
      ProbeVerdict.blocked => WColors.connecting,
      ProbeVerdict.dead => WColors.danger,
      ProbeVerdict.error => WColors.danger,
      ProbeVerdict.testing => WColors.connecting,
      ProbeVerdict.untested => WColors.danger,
    };

/// Small verdict pill: a dot + "works · 240 ms" etc.
class _VerdictChip extends StatelessWidget {
  const _VerdictChip(this.probe);
  final NodeProbe probe;

  @override
  Widget build(BuildContext context) {
    final v = probe.verdict;
    final label = switch (v) {
      ProbeVerdict.works || ProbeVerdict.slow =>
        '${v.label} · ${probe.bestMs ?? '–'} мс',
      _ => v.label,
    };
    final color = verdictColor(v);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (v == ProbeVerdict.testing)
          const SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.6),
          )
        else
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        const SizedBox(width: WSpace.xs),
        Text(
          label,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: color),
        ),
      ],
    );
  }
}

class _NodeRow extends ConsumerWidget {
  const _NodeRow({required this.node, required this.onTap});
  final Node node;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final probe = ref.watch(preflightProvider.select((m) => m[node.id]));
    return SectionCard(
      padding: const EdgeInsets.symmetric(
        horizontal: WSpace.md,
        vertical: WSpace.md,
      ),
      onTap: onTap,
      child: Row(
        children: [
          FlagView(node.countryCode, size: 26),
          const SizedBox(width: WSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  node.tag.isEmpty ? node.endpoint.host : node.tag,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  '${countryNameRu(node.countryCode)} · '
                  '${node.protocol.toUpperCase()} · '
                  '${node.classification.security.label}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: WSpace.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatPing(node.health.pingMs),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: node.health.alive ? WColors.protected : muted,
                    ),
              ),
              if (probe != null) ...[
                const SizedBox(height: 3),
                _VerdictChip(probe),
              ] else if (!node.health.alive)
                Text(
                  'офлайн',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: WColors.danger),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> _showNodeSheet(
  BuildContext context,
  WidgetRef ref,
  Node node,
) async {
  final json = const JsonEncoder.withIndent('  ').convert(node.outbound);
  final messenger = ScaffoldMessenger.of(context);

  Future<void> connectHere() async {
    final controller = ref.read(connectionControllerProvider);
    final resolve = ref.read(resolveSelectionProvider);
    await controller.select(Selection.node(node), resolve);
    if (!controller.isActive) await controller.connect(resolve);
    await ref.read(settingsProvider.notifier).rememberLastGoodNode(node.id);
    if (context.mounted) Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Узел ${node.tag.isEmpty ? node.endpoint.host : node.tag} выбран',
        ),
      ),
    );
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(
          WSpace.lg,
          0,
          WSpace.lg,
          WSpace.xl,
        ),
        children: [
          Row(
            children: [
              FlagView(node.countryCode, size: 34),
              const SizedBox(width: WSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      node.tag.isEmpty ? node.endpoint.host : node.tag,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      countryNameRu(node.countryCode),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: WSpace.md),
          NodeTags(node),
          const SizedBox(height: WSpace.lg),
          _StatsTable(node: node),
          const SizedBox(height: WSpace.lg),
          Text(
            'sing-box outbound',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: WSpace.xs),
          _JsonBox(json: json),
          const SizedBox(height: WSpace.md),
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: json));
              messenger.showSnackBar(
                const SnackBar(content: Text('JSON скопирован')),
              );
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Копировать JSON'),
          ),
          const SizedBox(height: WSpace.sm),
          _NodeSheetPreflight(node: node),
          const SizedBox(height: WSpace.sm),
          FilledButton.icon(
            onPressed: connectHere,
            icon: const Icon(Icons.bolt_rounded),
            label: const Text('Подключиться к этому узлу'),
          ),
        ],
      ),
    ),
  );
}

/// "Тест" button + per-target results inside the node sheet.
class _NodeSheetPreflight extends ConsumerWidget {
  const _NodeSheetPreflight({required this.node});
  final Node node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final probe = ref.watch(preflightProvider.select((m) => m[node.id]));
    final core = ref.watch(nativeCoreProvider);
    final testing = probe?.verdict == ProbeVerdict.testing;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: WSpace.md,
          runSpacing: WSpace.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              // The app theme forces button width to infinity — pin it back so
              // it can sit in a Wrap next to the verdict chip.
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 40),
              ),
              onPressed: (!core.isAvailable || testing)
                  ? null
                  : () => ref.read(preflightProvider.notifier).test(node),
              icon: testing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering_rounded, size: 16),
              label: Text(testing ? 'Проверка…' : 'Тест'),
            ),
            if (probe != null && probe.verdict.isDone) _VerdictChip(probe),
          ],
        ),
        if (probe != null && probe.error != null)
          Padding(
            padding: const EdgeInsets.only(top: WSpace.xs),
            child: Text(
              probe.error!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: WColors.danger),
            ),
          ),
        if (probe != null && probe.hits.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: WSpace.sm),
            child: Column(
              children: [
                for (final h in probe.hits)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Icon(
                          h.ok
                              ? Icons.check_circle_rounded
                              : (h.blocked
                                  ? Icons.block_rounded
                                  : Icons.cancel_rounded),
                          size: 14,
                          color: h.ok
                              ? WColors.protected
                              : (h.blocked
                                  ? WColors.connecting
                                  : WColors.danger),
                        ),
                        const SizedBox(width: WSpace.sm),
                        Expanded(
                          child: Text(
                            Uri.tryParse(h.url)?.host ?? h.url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        Text(
                          h.err != null
                              ? 'сбой'
                              : (h.status.isNotEmpty
                                  ? '${h.status.split(' ').first} · ${h.latencyMs} мс'
                                  : '${h.latencyMs} мс'),
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _StatsTable extends StatelessWidget {
  const _StatsTable({required this.node});
  final Node node;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      ('Адрес', '${node.endpoint.host}:${node.endpoint.port}'),
      if (node.endpoint.resolvedIp != null)
        ('IP', node.endpoint.resolvedIp!),
      ('Протокол', node.protocol.toUpperCase()),
      ('Транспорт', node.transport),
      ('Шифрование', node.classification.security.label),
      if (node.classification.sni != null)
        ('SNI', node.classification.sni!),
      if (node.classification.flow != null)
        ('Flow', node.classification.flow!),
      if (node.geo.asOrg != null)
        ('Сеть', 'AS${node.geo.asn ?? '?'} · ${node.geo.asOrg}'),
      ('Пинг', formatPing(node.health.pingMs)),
      ('Стабильность', node.lifetime.stability.toStringAsFixed(2)),
      ('Возраст', formatAge(node.lifetime.ageHours)),
      ('Проверок', '${node.lifetime.seenRuns}'),
      ('Класс жизни', node.lifetime.klass.label),
      ('Источник', node.provenance.source),
    ];

    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 120,
                  child: Text(
                    k,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: muted),
                  ),
                ),
                Expanded(
                  child: Text(
                    v,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _JsonBox extends StatelessWidget {
  const _JsonBox({required this.json});
  final String json;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      width: double.infinity,
      padding: const EdgeInsets.all(WSpace.md),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(WRadius.md),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Scrollbar(
        child: SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              json,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: ['Consolas', 'Menlo', 'monospace'],
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
