import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/hints.dart';
import '../../app/theme/tokens.dart';
import '../../core/connection_controller.dart';
import '../../core/singbox_bridge.dart';
import '../../data/pool_repository.dart';
import '../../domain/country_names.dart';
import '../../state/bundles.dart';
import '../../state/exit_geo.dart';
import '../../state/monitor.dart';
import '../../state/providers.dart';
import '../common/flag.dart';
import '../common/format.dart';
import '../common/power_button.dart';
import '../common/widgets.dart';
import '../shell/home_shell.dart' show PageBody;

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _toggle(WidgetRef ref) async {
    final controller = ref.read(connectionControllerProvider);
    if (controller.isActive) {
      await controller.disconnect();
      return;
    }

    var resolve = ref.read(resolveSelectionProvider);
    // The plain ranking goes by the collector's ping, which does not mean the
    // node works from here. Find one that actually answers before we connect
    // (and prefer the node that worked last time, if the setting is on).
    if (controller.selection.node == null) {
      final picked =
          await ref.read(connectPickProvider)(controller.selection);
      if (picked != null) resolve = (_) => picked;
    }

    await controller.connect(resolve);
    final active = controller.activeNode;
    if (active != null && controller.status == ConnectionStatus.protected) {
      await ref.read(settingsProvider.notifier).rememberLastGoodNode(active.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(connectionControllerProvider);
    final phase = ref.watch(connectPhaseProvider);
    final notice = ref.watch(connectionNoticeProvider);
    final exitNotice = ref.watch(exitNoticeProvider);
    final poolAsync = ref.watch(poolProvider);

    // Which country to show for the running session: the one its exit was just
    // *seen* in, else the node's country as corrected by earlier checks, else
    // what the node was listed with.
    final active = controller.activeNode;
    final sessionExit = ref.watch(sessionExitProvider);
    final exit = active != null && sessionExit?.nodeId == active.id
        ? sessionExit!.exit
        : null;
    final activeCountry = active == null
        ? null
        : exit?.country ??
            ref.watch(exitGeoProvider.select((m) => m[active.id]?.country)) ??
            active.countryCode;
    final proMode = ref.watch(settingsProvider.select((s) => s.proMode));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Weronity'),
        actions: [
          if (proMode)
            IconButton(
              tooltip: 'Инспектор нод',
              icon: const Icon(Icons.travel_explore_rounded),
              onPressed: () => context.go('/pro'),
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
        child: PageBody(
          child: RefreshIndicator(
            onRefresh: () => ref.read(poolProvider.notifier).refresh(),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                WSpace.lg,
                WSpace.sm,
                WSpace.lg,
                WSpace.xxl,
              ),
              children: [
                // Debug builds without the native core run the demo engine:
                // say so, loudly — nothing is tunnelled.
                if (controller is ConnectionController)
                  const Center(
                    child: Tag(
                      'Демо-режим · ядро не загружено, туннеля нет',
                      color: WColors.danger,
                      icon: Icons.science_rounded,
                    ),
                  ),
                const SizedBox(height: WSpace.xl),
                Center(
                  child: PowerButton(
                    status: phase == null
                        ? controller.status
                        : ConnectionStatus.connecting,
                    flagCode: activeCountry,
                    switching: controller.isSwitching,
                    // Ignore taps while the pre-connect scan runs — a second
                    // press would start a second scan.
                    onTap: () => phase == null ? _toggle(ref) : null,
                  ),
                ),
                const SizedBox(height: WSpace.xl),
                _StatusLine(
                  controller: controller,
                  phase: phase,
                  notice: notice,
                  exitNotice: exitNotice,
                  country: activeCountry,
                  exit: exit,
                ),
                const SizedBox(height: WSpace.xl),
                FadeSlideIn(
                  child: _SelectionCard(controller: controller),
                ),
                const SizedBox(height: WSpace.md),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 60),
                  child: _TrafficCard(controller: controller),
                ),
                const SizedBox(height: WSpace.md),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 120),
                  child: poolAsync.when(
                    data: (snap) => _PoolFreshness(snapshot: snap),
                    loading: () => const SizedBox.shrink(),
                    error: (e, _) => _PoolFreshness.error('$e'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.controller,
    this.phase,
    this.notice,
    this.exitNotice,
    this.country,
    this.exit,
  });
  final ConnectionEngine controller;

  /// The country to show for the session (see `HomeScreen.build`).
  final String? country;

  /// What was observed about this session's exit, once it has been checked.
  final ExitGeo? exit;

  /// Set while the session exits in a country other than the chosen one — see
  /// `exitNoticeProvider`.
  final String? exitNotice;

  /// Set while a pre-connect scan is running — see `connectPhaseProvider`.
  final String? phase;

  /// The monitor's warning about a session that is up but not working — see
  /// `connectionNoticeProvider`.
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final s = phase == null ? controller.status : ConnectionStatus.connecting;
    final color = switch (s) {
      ConnectionStatus.protected => WColors.protected,
      ConnectionStatus.connecting => WColors.connecting,
      ConnectionStatus.error => WColors.danger,
      ConnectionStatus.disconnected =>
        Theme.of(context).colorScheme.onSurfaceVariant,
    };
    final label = phase ??
        (controller.isSwitching ? 'Смена локации…' : s.label);
    final key = ValueKey<String>(
      '$label|${controller.activeNode?.id}|${controller.lastError}|$notice|'
      '$exitNotice|$country|$exit',
    );

    return AnimatedSwitcher(
      duration: WDur.normal,
      switchInCurve: WCurves.enter,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.25),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      child: Column(
        key: key,
        children: [
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(color: color, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: WSpace.xs),
          if (s == ConnectionStatus.protected && controller.activeNode != null)
            Column(
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CountryLabel(
                      country ?? controller.activeNode!.countryCode,
                      flagSize: 18,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    // Green only when independent geolocation sources agree;
                    // a single source is shown without a mark at all.
                    if (exit?.confirmed ?? false)
                      const Padding(
                        padding: EdgeInsets.only(left: WSpace.xs),
                        child: Tooltip(
                          message: 'Страна выхода подтверждена: независимые '
                              'геобазы сходятся',
                          child: Icon(
                            Icons.verified_rounded,
                            size: 15,
                            color: WColors.protected,
                          ),
                        ),
                      )
                    else if (exit?.disputed ?? false)
                      const Padding(
                        padding: EdgeInsets.only(left: WSpace.xs),
                        child: Icon(
                          Icons.help_rounded,
                          size: 15,
                          color: WColors.connecting,
                        ),
                      ),
                    _ElapsedText(controller: controller),
                  ],
                ),
                if (controller case final SingBoxBridge b
                    when b.proxyEndpoint != null) ...[
                  const SizedBox(height: WSpace.xs),
                  Text(
                    b.isVpn
                        ? 'Системный VPN · TUN'
                        : 'SOCKS5 · ${b.proxyEndpoint}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
                if (!controller.activeNode!.isHopSecure) ...[
                  const SizedBox(height: WSpace.sm),
                  HopSecurityTag(controller.activeNode!.hopSecurity),
                ],
                // The sources disagree and nothing else is being said about
                // it (no country was picked): still tell the user, plainly.
                if (exitNotice == null && (exit?.disputed ?? false)) ...[
                  const SizedBox(height: WSpace.xs),
                  Text(
                    'По другим геобазам — '
                    '${countryNameRu(exit!.disputedWith)}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: WColors.connecting),
                  ),
                ],
                if (exitNotice != null) ...[
                  const SizedBox(height: WSpace.sm),
                  Text(
                    exitNotice!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: WColors.connecting),
                  ),
                ],
                if (notice != null) ...[
                  const SizedBox(height: WSpace.sm),
                  Text(
                    notice!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: WColors.connecting),
                  ),
                ],
              ],
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
      ),
    );
  }
}

/// Live session timer, split out so it can tick without re-triggering the
/// status-line [AnimatedSwitcher].
class _ElapsedText extends StatelessWidget {
  const _ElapsedText({required this.controller});
  final ConnectionEngine controller;

  @override
  Widget build(BuildContext context) {
    return Text(
      ' · ${formatDuration(controller.traffic.elapsed)}',
      style: Theme.of(context).textTheme.bodyMedium,
    );
  }
}

class _SelectionCard extends ConsumerWidget {
  const _SelectionCard({required this.controller});
  final ConnectionEngine controller;

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
      leading = const Icon(Icons.bolt_rounded, color: WColors.violetBright, size: 26);
    } else if (sel.bundleId != null) {
      final b = ref
          .watch(allBundlesProvider)
          .where((x) => x.id == sel.bundleId!);
      final all = ref.watch(nodesProvider);
      title = b.isEmpty ? 'Подборка' : b.first.name;
      subtitle = b.isEmpty
          ? 'подборка не найдена'
          : '${bundleLiveNodes(b.first, all).length} живых узлов';
      leading = Icon(
        blockedServiceForBundle(sel.bundleId!)?.icon ??
            Icons.playlist_play_rounded,
        color: WColors.violetBright,
        size: 26,
      );
    } else if (sel.countryCode != null) {
      final c = countries.where((c) => c.code == sel.countryCode);
      title = countryNameRu(sel.countryCode);
      subtitle = c.isEmpty
          ? 'нет узлов'
          : '${c.first.nodeCount} узлов · лучший ${formatPing(c.first.bestPingMs)}';
      leading = FlagView(sel.countryCode, size: 26);
    } else {
      final n = sel.node!;
      title = n.tag.isEmpty ? n.endpoint.host : n.tag;
      subtitle = '${countryNameRu(n.countryCode)} · '
          '${n.protocol.toUpperCase()} · ${formatPing(n.health.pingMs)}';
      leading = FlagView(n.countryCode, size: 26);
    }

    final key = ValueKey<String>(
      '${sel.isAuto}|${sel.countryCode}|${sel.bundleId}|${sel.node?.id}|$subtitle',
    );

    return SectionCard(
      onTap: () => context.push('/locations'),
      child: Row(
        children: [
          AnimatedSwitcher(
            duration: WDur.normal,
            switchInCurve: WCurves.enter,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.6, end: 1).animate(anim),
                child: child,
              ),
            ),
            child: SizedBox(
              key: ValueKey<String>('lead|${sel.isAuto}|${sel.countryCode}|'
                  '${sel.bundleId}|${sel.node?.id}'),
              width: 32,
              child: Center(child: leading),
            ),
          ),
          const SizedBox(width: WSpace.md),
          Expanded(
            child: AnimatedSwitcher(
              duration: WDur.normal,
              switchInCurve: WCurves.enter,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.08, 0),
                    end: Offset.zero,
                  ).animate(anim),
                  child: child,
                ),
              ),
              child: Column(
                key: key,
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
          ),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
  }
}

class _TrafficCard extends StatelessWidget {
  const _TrafficCard({required this.controller});
  final ConnectionEngine controller;

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
