import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';

/// Responsive navigation scaffold: a bottom bar in portrait / on narrow windows,
/// a side rail once the window is wide enough for it.
class HomeShell extends StatelessWidget {
  const HomeShell({required this.shell, super.key});

  static const railBreakpoint = 760.0;

  final StatefulNavigationShell shell;

  void _go(int i) => shell.goBranch(i, initialLocation: i == shell.currentIndex);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= railBreakpoint) {
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: shell.currentIndex,
                  onDestinationSelected: _go,
                  labelType: NavigationRailLabelType.all,
                  groupAlignment: -0.85,
                  destinations: [
                    for (final tab in AppTab.values)
                      NavigationRailDestination(
                        icon: Icon(tab.icon),
                        selectedIcon: Icon(tab.activeIcon),
                        label: Text(tab.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: shell),
              ],
            ),
          );
        }
        return Scaffold(
          body: shell,
          bottomNavigationBar: NavigationBar(
            selectedIndex: shell.currentIndex,
            onDestinationSelected: _go,
            destinations: [
              for (final tab in AppTab.values)
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
