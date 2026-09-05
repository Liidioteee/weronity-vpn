import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../ui/keys/keys_screen.dart';
import '../ui/pro/pro_screen.dart';
import '../ui/settings/settings_screen.dart';
import '../ui/shell/home_shell.dart';
import '../ui/simple/home_screen.dart';
import '../ui/simple/locations_screen.dart';
import 'theme/tokens.dart';

final router = GoRouter(
  initialLocation: '/',
  routes: [
    StatefulShellRoute(
      builder: (context, state, shell) => HomeShell(shell: shell),
      navigatorContainerBuilder: (context, shell, children) =>
          _AnimatedBranchContainer(
        currentIndex: shell.currentIndex,
        children: children,
      ),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const HomeScreen(),
              routes: [
                GoRoute(
                  path: 'locations',
                  builder: (context, state) => const LocationsScreen(),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/keys',
              builder: (context, state) => const KeysScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              builder: (context, state) => const SettingsScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/pro',
              builder: (context, state) => const ProScreen(),
            ),
          ],
        ),
      ],
    ),
  ],
);

/// Keeps every branch navigator mounted (state preserved) and cross-fades
/// between them when the tab changes. Replaces the default IndexedStack so the
/// switch feels soft — and, unlike wrapping the shell in an `AnimatedSwitcher`,
/// it never duplicates the shell's GlobalKey.
class _AnimatedBranchContainer extends StatelessWidget {
  const _AnimatedBranchContainer({
    required this.currentIndex,
    required this.children,
  });

  final int currentIndex;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        for (var i = 0; i < children.length; i++)
          _Branch(active: i == currentIndex, child: children[i]),
      ],
    );
  }
}

class _Branch extends StatelessWidget {
  const _Branch({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: active ? 1 : 0,
      duration: WDur.page,
      curve: active ? WCurves.enter : WCurves.exit,
      child: IgnorePointer(
        ignoring: !active,
        child: TickerMode(
          enabled: active,
          child: _Slide(active: active, child: child),
        ),
      ),
    );
  }
}

/// A whisper of upward motion on the incoming branch.
class _Slide extends StatelessWidget {
  const _Slide({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: active ? Offset.zero : const Offset(0, 0.012),
      duration: WDur.page,
      curve: WCurves.enter,
      child: child,
    );
  }
}

/// Tabs shown in the bottom navigation bar. [pro] is only surfaced when the
/// Pro-mode toggle is on (see `HomeShell`).
enum AppTab {
  home(Icons.shield_outlined, Icons.shield_rounded, 'Главная', '/'),
  keys(Icons.vpn_key_outlined, Icons.vpn_key_rounded, 'Ключи', '/keys'),
  settings(Icons.tune_outlined, Icons.tune_rounded, 'Настройки', '/settings'),
  pro(Icons.auto_awesome_outlined, Icons.auto_awesome_rounded, 'Pro', '/pro');

  const AppTab(this.icon, this.activeIcon, this.label, this.location);

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final String location;
}
