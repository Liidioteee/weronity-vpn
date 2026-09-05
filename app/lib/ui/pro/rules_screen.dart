import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/hints.dart';
import '../../app/theme/tokens.dart';
import '../../data/settings_repository.dart';
import '../../state/providers.dart';
import '../common/widgets.dart';

/// Pro → Правила. Three editable domain buckets (Direct / Proxy / Block) that
/// will feed the sing-box route config in Phase 4.
class RulesScreen extends ConsumerWidget {
  const RulesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        WSpace.lg,
        WSpace.md,
        WSpace.lg,
        WSpace.xxl,
      ),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                'Домены и подсети, для которых нужно переопределить режим '
                'маршрутизации. Применяется в Фазе 4.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            const SizedBox(width: WSpace.sm),
            hintFor('custom_rules'),
          ],
        ),
        const SizedBox(height: WSpace.md),
        for (final bucket in RuleBucket.values)
          Padding(
            padding: const EdgeInsets.only(bottom: WSpace.md),
            child: _BucketCard(
              bucket: bucket,
              entries: settings.rules(bucket),
              onChanged: (list) =>
                  ref.read(settingsProvider.notifier).setRules(bucket, list),
            ),
          ),
      ],
    );
  }
}

class _BucketCard extends StatefulWidget {
  const _BucketCard({
    required this.bucket,
    required this.entries,
    required this.onChanged,
  });

  final RuleBucket bucket;
  final List<String> entries;
  final ValueChanged<List<String>> onChanged;

  @override
  State<_BucketCard> createState() => _BucketCardState();
}

class _BucketCardState extends State<_BucketCard> {
  final _field = TextEditingController();

  Color get _accent => switch (widget.bucket) {
        RuleBucket.direct => WColors.info,
        RuleBucket.proxy => WColors.violet,
        RuleBucket.block => WColors.danger,
      };

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _add() {
    final raw = _field.text.trim().toLowerCase();
    if (raw.isEmpty || widget.entries.contains(raw)) {
      _field.clear();
      return;
    }
    widget.onChanged([...widget.entries, raw]);
    _field.clear();
  }

  void _remove(String value) =>
      widget.onChanged(widget.entries.where((e) => e != value).toList());

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      padding: const EdgeInsets.all(WSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: WSpace.sm),
              Text(
                widget.bucket.label,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Spacer(),
              Text(
                '${widget.entries.length}',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          Text(
            widget.bucket.hint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: WSpace.sm),
          if (widget.entries.isNotEmpty)
            Wrap(
              spacing: WSpace.xs,
              runSpacing: WSpace.xs,
              children: [
                for (final e in widget.entries)
                  InputChip(
                    label: Text(e),
                    onDeleted: () => _remove(e),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          const SizedBox(height: WSpace.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _field,
                  decoration: const InputDecoration(
                    hintText: 'example.com или 10.0.0.0/8',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: WSpace.sm),
              IconButton.filledTonal(
                onPressed: _add,
                icon: const Icon(Icons.add_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
