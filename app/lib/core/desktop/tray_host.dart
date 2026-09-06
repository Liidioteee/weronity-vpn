import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/router.dart' show rootNavigatorKey;
import '../../data/settings_repository.dart';
import '../../state/providers.dart';

bool get _isDesktop => Platform.isWindows || Platform.isLinux;

/// Call once, before `runApp`, on desktop. Makes the window ask us before it
/// closes so we can hide-to-tray instead.
Future<void> initDesktopWindow() async {
  if (!_isDesktop) return;
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
}

/// Wraps the app: owns the system-tray icon and decides what the window's
/// close button does (ask / minimise to tray / quit). A no-op off desktop.
class TrayHost extends ConsumerStatefulWidget {
  const TrayHost({required this.child, super.key});
  final Widget child;

  @override
  ConsumerState<TrayHost> createState() => _TrayHostState();
}

class _TrayHostState extends ConsumerState<TrayHost>
    with WindowListener, TrayListener {
  static const _iconPath = 'assets/tray/tray_icon.ico';
  bool _quitting = false;

  @override
  void initState() {
    super.initState();
    if (_isDesktop) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      unawaited(_setupTray());
    }
  }

  @override
  void dispose() {
    if (_isDesktop) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  Future<void> _setupTray() async {
    try {
      await trayManager.setIcon(_iconPath);
      await trayManager.setToolTip('Weronity');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Показать Weronity'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Выход'),
      ]));
    } on Object catch (e) {
      debugPrint('tray setup failed: $e');
    }
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    if (_quitting) return;
    _quitting = true;
    // Tear the tunnel down cleanly first — a half-torn TUN leaks routes.
    try {
      final engine = ref.read(connectionControllerProvider);
      if (engine.isActive) await engine.disconnect();
    } on Object catch (_) {}
    try {
      await trayManager.destroy();
    } on Object catch (_) {}
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  Future<void> _askOnClose() async {
    var remember = false;
    final navCtx = rootNavigatorKey.currentContext;
    if (navCtx == null) {
      // No UI to ask through — fall back to hide-to-tray.
      await windowManager.hide();
      return;
    }
    final choice = await showDialog<WindowCloseAction>(
      context: navCtx,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Закрыть Weronity?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Свернуть в трей — приложение продолжит работать в фоне '
                '(подключение не разрывается). Выйти — полностью закрыть.',
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: remember,
                onChanged: (v) => setLocal(() => remember = v ?? false),
                title: const Text('Запомнить выбор'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, WindowCloseAction.quit),
              child: const Text('Выйти'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, WindowCloseAction.tray),
              child: const Text('В трей'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    if (remember) {
      await ref.read(settingsProvider.notifier).setCloseAction(choice);
    }
    if (choice == WindowCloseAction.quit) {
      await _quit();
    } else {
      await windowManager.hide();
    }
  }

  // ---- WindowListener ----------------------------------------------------

  @override
  void onWindowClose() {
    if (_quitting) return;
    switch (ref.read(settingsProvider).closeAction) {
      case WindowCloseAction.quit:
        unawaited(_quit());
      case WindowCloseAction.tray:
        unawaited(windowManager.hide());
      case WindowCloseAction.ask:
        unawaited(_askOnClose());
    }
  }

  // ---- TrayListener ----------------------------------------------------

  @override
  void onTrayIconMouseDown() => unawaited(_showWindow());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(_showWindow());
      case 'quit':
        unawaited(_quit());
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
