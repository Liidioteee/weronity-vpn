import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/theme/tokens.dart';
import '../../state/providers.dart';

/// Responsive navigation scaffold: a bottom bar in portrait / on narrow windows,
/// a side rail once the window is wide enough for it. The Pro destination only
/// appears while Pro-mode is on.
class HomeShell extends ConsumerWidget {
  const HomeShell({required this.shell, super.key});

  static const railBreakpoint = 760.0;

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final proMode = ref.watch(settingsProvider.select((s) => s.proMode));
    final tabs = [
      for (final t in AppTab.values)
        if (t != AppTab.pro || proMode) t,
    ];

    // Pro was switched off while its tab was open — bounce back Home.
    if (!proMode && shell.currentIndex >= tabs.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) shell.goBranch(0);
      });
    }
    final selectedIndex = shell.currentIndex.clamp(0, tabs.length - 1);

    void go(int i) =>
        shell.goBranch(i, initialLocation: i == shell.currentIndex);

    final body = _BranchSwitcher(index: selectedIndex, child: shell);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= railBreakpoint) {
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: selectedIndex,
                  onDestinationSelected: go,
                  labelType: NavigationRailLabelType.all,
                  groupAlignment: -0.85,
                  destinations: [
                    for (final tab in tabs)
                      NavigationRailDestination(
                        icon: Icon(tab.icon),
                        selectedIcon: Icon(tab.activeIcon),
                        label: Text(tab.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            ),
          );
        }
        return Scaffold(
          body: body,
          bottomNavigationBar: NavigationBar(
            selectedIndex: selectedIndex,
            onDestinationSelected: go,
            destinations: [
              for (final tab in tabs)
                NavigationDestination(
                  icon: Icon(tab.icon),
                  selectedIcon: Icon(tab.activeIcon),
                  label: tab.label,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Cross-fades + gently slides between navigation branches so switching tabs
/// feels soft instead of an instant cut.
class _BranchSwitcher extends StatelessWidget {
  const _BranchSwitcher({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: WDur.page,
      switchInCurve: WCurves.enter,
      switchOutCurve: WCurves.exit,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.topCenter,
        children: [
          ...previousChildren,
          ?currentChild,
        ],
      ),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.018),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey<int>(index), child: child),
    );
  }
}

/// Centres page content and caps its width so screens stay readable when the
/// window is stretched wide. Use as the direct child of a Scaffold body.
class PageBody extends StatelessWidget {
  const PageBody({required this.child, this.maxWidth = 560, super.key});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
