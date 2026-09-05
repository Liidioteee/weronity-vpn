import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/tokens.dart';
import '../../state/providers.dart';
import '../common/widgets.dart';
import '../shell/home_shell.dart' show PageBody;
import 'graphs_screen.dart';
import 'logs_screen.dart';
import 'node_inspector_screen.dart';
import 'preflight_screen.dart';
import 'rules_screen.dart';

/// Pro-mode workspace: everything a power user needs, kept out of the Simple UI.
class ProScreen extends ConsumerWidget {
  const ProScreen({super.key});

  static const _tabs = <({String label, IconData icon})>[
    (label: 'Ноды', icon: Icons.travel_explore_rounded),
    (label: 'Логи', icon: Icons.terminal_rounded),
    (label: 'Графики', icon: Icons.show_chart_rounded),
    (label: 'Правила', icon: Icons.rule_rounded),
    (label: 'Проверки', icon: Icons.checklist_rounded),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final proMode = ref.watch(settingsProvider.select((s) => s.proMode));

    if (!proMode) {
      return Scaffold(
        appBar: AppBar(title: const Text('Pro-режим')),
        body: PageBody(
          child: EmptyState(
            icon: Icons.auto_awesome_outlined,
            title: 'Pro-режим выключен',
            subtitle: 'Включите его в настройках, чтобы открыть инспектор нод, '
                'логи ядра, графики сети и редактор правил.',
            action: FilledButton.icon(
              onPressed: () => context.go('/settings'),
              icon: const Icon(Icons.tune_rounded),
              label: const Text('Открыть настройки'),
            ),
          ),
        ),
      );
    }

    return DefaultTabController(
      length: _tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Pro-режим'),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            indicatorColor: WColors.violet,
            dividerColor: Theme.of(context).colorScheme.outline,
            tabs: [
              for (final t in _tabs)
                Tab(
                  height: 46,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(t.icon, size: 16),
                      const SizedBox(width: WSpace.sm),
                      Text(t.label),
                    ],
                  ),
                ),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            NodeInspectorScreen(),
            LogsScreen(),
            GraphsScreen(),
            RulesScreen(),
            PreflightScreen(),
          ],
        ),
      ),
    );
  }
}
