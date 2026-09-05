import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../data/settings_repository.dart';
import '../../state/providers.dart';
import '../common/widgets.dart';

/// Pro → Проверки. Editable list of pre-flight endpoints. In Phase 4 the engine
/// hits each of these through a candidate node before trusting it.
class PreflightScreen extends ConsumerStatefulWidget {
  const PreflightScreen({super.key});

  @override
  ConsumerState<PreflightScreen> createState() => _PreflightScreenState();
}

class _PreflightScreenState extends ConsumerState<PreflightScreen> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  List<String> get _endpoints =>
      ref.read(settingsProvider).preflightEndpoints;

  void _save(List<String> next) =>
      ref.read(settingsProvider.notifier).setPreflightEndpoints(next);

  void _add() {
    var raw = _field.text.trim();
    if (raw.isEmpty) return;
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      raw = 'https://$raw';
    }
    if (_endpoints.contains(raw)) {
      _field.clear();
      return;
    }
    _save([..._endpoints, raw]);
    _field.clear();
  }

  @override
  Widget build(BuildContext context) {
    final endpoints = ref.watch(
      settingsProvider.select((s) => s.preflightEndpoints),
    );
    final isDefault = _listEquals(
      endpoints,
      Settings.defaultPreflightEndpoints,
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        WSpace.lg,
        WSpace.md,
        WSpace.lg,
        WSpace.xxl,
      ),
      children: [
        Text(
          'Узел считается рабочим, если ответ приходит быстрее 500 мс и это '
          'не страница-заглушка блокировки или капча.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: WSpace.md),
        SectionCard(
          padding: const EdgeInsets.symmetric(vertical: WSpace.xs),
          child: Column(
            children: [
              for (var i = 0; i < endpoints.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.link_rounded, size: 18),
                  title: Text(
                    endpoints[i],
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  trailing: IconButton(
                    tooltip: 'Удалить',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => _save(
                      [...endpoints]..removeAt(i),
                    ),
                  ),
                ),
              ],
              if (endpoints.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(WSpace.lg),
                  child: Text('Список пуст — добавьте хотя бы один адрес.'),
                ),
            ],
          ),
        ),
        const SizedBox(height: WSpace.md),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _field,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: 'https://example.com/generate_204',
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
        const SizedBox(height: WSpace.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: isDefault
                ? null
                : () => _save([...Settings.defaultPreflightEndpoints]),
            icon: const Icon(Icons.restart_alt_rounded, size: 16),
            label: const Text('Вернуть стандартные'),
          ),
        ),
      ],
    );
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
