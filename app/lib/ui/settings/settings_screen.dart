import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/hints.dart';
import '../../app/theme/tokens.dart';
import '../../core/native/native_core.dart';
import '../../data/settings_repository.dart';
import '../../state/providers.dart';
import '../common/info_hint.dart';
import '../common/widgets.dart';
import '../pro/core_probe_sheet.dart';
import '../shell/home_shell.dart' show PageBody;

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: PageBody(
        child: ListView(
        padding: const EdgeInsets.fromLTRB(WSpace.lg, WSpace.sm, WSpace.lg, WSpace.xxl),
        children: [
          _Group(
            title: 'Режим',
            children: [
              _SwitchRow(
                labelKey: 'pro_mode',
                label: 'Pro-режим',
                value: s.proMode,
                onChanged: notifier.setProMode,
              ),
            ],
          ),
          _Group(
            title: 'Подключение',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  WSpace.lg,
                  WSpace.lg,
                  WSpace.lg,
                  WSpace.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LabeledHint('Режим работы',
                        hint: hintRecord('connection_mode'),
                        style: Theme.of(context).textTheme.bodyLarge),
                    const SizedBox(height: WSpace.md),
                    SegmentedButton<ConnectionMode>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: ConnectionMode.proxy,
                          label: Text('Прокси'),
                          icon: Icon(Icons.lan_rounded, size: 18),
                        ),
                        ButtonSegment(
                          value: ConnectionMode.vpn,
                          label: Text('VPN (TUN)'),
                          icon: Icon(Icons.vpn_lock_rounded, size: 18),
                        ),
                      ],
                      selected: {s.connectionMode},
                      onSelectionChanged: (v) =>
                          notifier.setConnectionMode(v.first),
                    ),
                    if (s.connectionMode == ConnectionMode.vpn)
                      Padding(
                        padding: const EdgeInsets.only(top: WSpace.sm),
                        child: Text(
                          'Режим VPN (TUN) появится в Фазе 3.3. Сейчас '
                          'подключение работает только через прокси.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: WColors.connecting,
                              ),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(),
              ListTile(
                enabled: s.connectionMode == ConnectionMode.proxy,
                title: LabeledHint('Порт прокси',
                    hint: hintRecord('proxy_port')),
                subtitle: Text(
                  '127.0.0.1:${s.proxyPort}  ·  SOCKS5 / HTTP',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                trailing: const Icon(Icons.edit_rounded, size: 18),
                onTap: s.connectionMode == ConnectionMode.proxy
                    ? () => _editProxyPort(context, ref, s.proxyPort)
                    : null,
              ),
            ],
          ),
          _Group(
            title: 'Оформление',
            children: [
              Padding(
                padding: const EdgeInsets.all(WSpace.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Тема', style: Theme.of(context).textTheme.bodyLarge),
                    const SizedBox(height: WSpace.md),
                    SegmentedButton<ThemeMode>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: Text('Тёмная'),
                          icon: Icon(Icons.dark_mode_rounded, size: 18),
                        ),
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: Text('Светлая'),
                          icon: Icon(Icons.light_mode_rounded, size: 18),
                        ),
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: Text('Авто'),
                          icon: Icon(Icons.brightness_auto_rounded, size: 18),
                        ),
                      ],
                      selected: {s.themeMode},
                      onSelectionChanged: (v) => notifier.setThemeMode(v.first),
                    ),
                  ],
                ),
              ),
            ],
          ),
          _Group(
            title: 'Маршрутизация',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(WSpace.lg, WSpace.lg, WSpace.lg, WSpace.sm),
                child: LabeledHint(
                  'Режим маршрутизации',
                  hint: hintRecord('routing_mode'),
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
              RadioGroup<RoutingMode>(
                groupValue: s.routingMode,
                onChanged: (v) => v == null ? null : notifier.setRoutingMode(v),
                child: Column(
                  children: [
                    for (final mode in RoutingMode.values)
                      RadioListTile<RoutingMode>(
                        value: mode,
                        title: Text(mode.label),
                        subtitle: Text(
                          switch (mode) {
                            RoutingMode.smart =>
                              'РФ-ресурсы напрямую, заблокированные — через VPN',
                            RoutingMode.global => 'Весь трафик через туннель',
                            RoutingMode.splitTunnel => 'Выбор приложений вручную',
                          },
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          _Group(
            title: 'Приватность и сеть',
            children: [
              _SwitchRow(
                labelKey: 'adblock',
                label: 'Блокировка рекламы',
                value: s.adBlock,
                onChanged: notifier.setAdBlock,
              ),
              const Divider(),
              _SwitchRow(
                labelKey: 'auto_last_node',
                label: 'Возвращаться на прошлый узел',
                value: s.autoConnectLastNode,
                onChanged: notifier.setAutoConnectLastNode,
              ),
              const Divider(),
              ListTile(
                title: LabeledHint('Источник пула узлов',
                    hint: hintRecord('pool_source')),
                subtitle: Text(
                  s.poolUrlOverride?.isNotEmpty == true
                      ? s.poolUrlOverride!
                      : 'по умолчанию',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                trailing: const Icon(Icons.edit_rounded, size: 18),
                onTap: () => _editPoolUrl(context, ref, s.poolUrlOverride),
              ),
              const Divider(),
              ListTile(
                title: LabeledHint('Проверочные адреса',
                    hint: hintRecord('preflight_endpoints')),
                subtitle: Text('${s.preflightEndpoints.length} адресов',
                    style: Theme.of(context).textTheme.bodySmall),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _showEndpoints(context, s.preflightEndpoints),
              ),
            ],
          ),
          _Group(
            title: 'О приложении',
            children: [
              ListTile(
                leading: const Icon(Icons.privacy_tip_outlined),
                title: LabeledHint('Политика нулевых логов',
                    hint: hintRecord('zero_log')),
                subtitle: Text('Персональные данные не собираются',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
              const Divider(),
              Builder(
                builder: (context) {
                  final core = ref.watch(nativeCoreProvider);
                  final ok = core.state == NativeCoreState.ok;
                  return ListTile(
                    leading: Icon(
                      ok ? Icons.memory_rounded : Icons.memory_outlined,
                      color: ok ? WColors.protected : null,
                    ),
                    title: const Text('Нативное ядро'),
                    subtitle: Text(
                      ok
                          ? '${core.version()}'
                          : 'не подключено — используется заглушка (Фаза 3)',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    trailing: ok
                        ? const Icon(Icons.play_circle_outline_rounded)
                        : null,
                    onTap: ok ? () => showCoreProbeSheet(context) : null,
                  );
                },
              ),
              const Divider(),
              const ListTile(
                leading: Icon(Icons.balance_rounded),
                title: Text('Лицензия'),
                subtitle: Text('GNU GPL v3.0 · 100% Free & Open Source'),
              ),
              const Divider(),
              const ListTile(
                leading: Icon(Icons.info_outline_rounded),
                title: Text('Версия'),
                subtitle: Text('0.1.0 (Фаза 2 — интерфейс, ядро в разработке)'),
              ),
            ],
          ),
        ],
        ),
      ),
    );
  }

  Future<void> _editPoolUrl(
    BuildContext context,
    WidgetRef ref,
    String? current,
  ) async {
    final controller = TextEditingController(text: current ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Источник пула'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://…/nodes_pool.json',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Сбросить'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (result == null) return;
    await ref
        .read(settingsProvider.notifier)
        .setPoolUrlOverride(result.isEmpty ? null : result);
  }

  Future<void> _editProxyPort(
    BuildContext context,
    WidgetRef ref,
    int current,
  ) async {
    final controller = TextEditingController(text: '$current');
    final result = await showDialog<int?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Порт локального прокси'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '1024–65535'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(controller.text.trim())),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (result == null) return;
    await ref.read(settingsProvider.notifier).setProxyPort(result);
  }

  void _showEndpoints(BuildContext context, List<String> endpoints) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(WSpace.xl, WSpace.sm, WSpace.xl, WSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Проверочные адреса',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: WSpace.md),
              for (final e in endpoints)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.link_rounded, size: 16),
                      const SizedBox(width: WSpace.sm),
                      Expanded(child: Text(e, style: Theme.of(context).textTheme.bodySmall)),
                    ],
                  ),
                ),
              const SizedBox(height: WSpace.md),
              Text(
                'Редактирование списка — во вкладке Pro → «Проверки».',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: WSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(WSpace.xs, 0, 0, WSpace.sm),
            child: Text(
              title.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    letterSpacing: 1,
                  ),
            ),
          ),
          SectionCard(
            padding: EdgeInsets.zero,
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.labelKey,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String labelKey;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      title: LabeledHint(label, hint: hintRecord(labelKey)),
    );
  }
}
