import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/hints.dart';
import '../../app/theme/tokens.dart';
import '../../data/custom_keys_repository.dart';
import '../../domain/node.dart';
import '../../domain/uri_parser.dart';
import '../../state/custom_keys.dart';
import '../common/flag.dart';
import '../common/format.dart';
import '../common/widgets.dart';
import '../shell/home_shell.dart' show PageBody;

/// Manager for user-supplied keys and subscriptions (ТЗ: «Мои подписки / Свои
/// ключи»). Everything added here joins the common pool with a `[Custom]` tag.
class KeysScreen extends ConsumerStatefulWidget {
  const KeysScreen({super.key});

  @override
  ConsumerState<KeysScreen> createState() => _KeysScreenState();
}

class _KeysScreenState extends ConsumerState<KeysScreen> {
  bool get _canScanQr =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// Multi-select mode for "Свои ключи". Holds the raw URIs of picked keys.
  bool _selecting = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    // Ctrl/Cmd+V pastes a key while this screen is the visible branch. A global
    // key handler (not a Shortcuts/Focus tree) so it works without a prior
    // click anywhere on the screen.
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    // Refresh subscriptions that were never fetched or are older than an hour.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final data = ref.read(customKeysProvider).valueOrNull;
      if (data == null) return;
      final stale = data.subs.where((s) =>
          s.lastFetched == null ||
          DateTime.now().difference(s.lastFetched!) > const Duration(hours: 1));
      for (final s in stale) {
        ref.read(customKeysProvider.notifier).refreshSubscription(s.url);
      }
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    super.dispose();
  }

  /// True when this Keys branch is the one on screen and no dialog covers it.
  bool get _screenIsActive =>
      mounted &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  bool _onGlobalKey(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.keyV) {
      return false;
    }
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final combo = pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight) ||
        pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight);
    if (!combo || !_screenIsActive || _selecting) return false;
    _pasteFromClipboard();
    return true;
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _pasteFromClipboard() async {
    String text = '';
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text?.trim() ?? '';
    } catch (_) {
      _snack('Не удалось прочитать буфер обмена');
      return;
    }
    if (text.isEmpty) {
      _snack('Буфер обмена пуст');
      return;
    }
    final r = await ref.read(customKeysProvider.notifier).addFromText(text);
    if (r.added > 0) {
      _snack('Добавлено ключей: ${r.added}'
          '${r.duplicates > 0 ? ', пропущено дублей: ${r.duplicates}' : ''}');
      if (r.added >= 2) {
        await _offerBundle(r.addedNodeIds, 'Вставленная подборка');
      }
    } else if (r.duplicates > 0) {
      _snack('Эти ключи уже добавлены');
    } else if (r.failed > 0) {
      _snack('Найдено строк: ${r.failed}, но разобрать их не удалось');
    } else {
      _snack('В буфере не найдено ключей (vless://, vmess://, …)');
    }
  }

  void _scanQr() {
    _snack(_canScanQr
        ? 'Сканирование QR будет доступно в мобильной сборке'
        : 'Сканирование QR доступно на Android и iOS. На компьютере используйте вставку из буфера.');
  }

  Future<void> _addSubscription() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Добавить подписку'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://example.com/sub'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    final err = await ref.read(customKeysProvider.notifier).addSubscription(url);
    _snack(err ?? 'Подписка добавлена, загружаю узлы…');
  }

  void _showQr(String rawUri, String title) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 260,
          height: 260,
          child: QrImageView(
            data: rawUri,
            backgroundColor: Colors.white,
            padding: const EdgeInsets.all(12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: rawUri));
              _snack('Ключ скопирован в буфер');
            },
            child: const Text('Скопировать'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  // ---- bundles ---------------------------------------------------------

  /// Ask for a name, then create a bundle from [nodeIds]. No-op on cancel.
  Future<void> _offerBundle(List<String> nodeIds, String defaultName) async {
    if (nodeIds.length < 2) return;
    final controller = TextEditingController(text: defaultName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Объединить ${nodeIds.length} ключа в подборку?'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Название подборки'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Не надо'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Создать'),
          ),
        ],
      ),
    );
    if (name == null) return;
    final id =
        await ref.read(customKeysProvider.notifier).createBundle(name, nodeIds);
    if (id.isNotEmpty) {
      _snack('Подборка создана — она в списке локаций рядом со странами');
    }
  }

  Future<void> _combineSelected() async {
    final ids = <String>[
      for (final raw in _selected)
        if (parseProxyUri(raw)?.id case final String id) id,
    ];
    _exitSelection();
    await _offerBundle(ids, 'Моя подборка');
  }

  Future<void> _renameBundle(String id, String current) async {
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Переименовать подборку'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
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
    if (name != null && name.isNotEmpty) {
      await ref.read(customKeysProvider.notifier).renameBundle(id, name);
    }
  }

  // ---- multi-select ------------------------------------------------------

  void _enterSelection(String rawUri) {
    setState(() {
      _selecting = true;
      _selected
        ..clear()
        ..add(rawUri);
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggle(String rawUri) {
    setState(() {
      if (!_selected.remove(rawUri)) _selected.add(rawUri);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _selectAll(List<CustomKey> keys) {
    setState(() {
      if (_selected.length == keys.length) {
        _selected.clear();
        _selecting = false;
      } else {
        _selected
          ..clear()
          ..addAll(keys.map((k) => k.rawUri));
      }
    });
  }

  Future<void> _deleteSelected() async {
    final n = _selected.length;
    if (n == 0) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Удалить ${_plural(n, 'ключ', 'ключа', 'ключей')}?'),
        content: const Text('Действие нельзя отменить.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(customKeysProvider.notifier).removeKeys({..._selected});
    _exitSelection();
    _snack('Удалено: $n');
  }

  static String _plural(int n, String one, String few, String many) {
    final mod100 = n % 100;
    final mod10 = n % 10;
    if (mod100 >= 11 && mod100 <= 14) return '$n $many';
    if (mod10 == 1) return '$n $one';
    if (mod10 >= 2 && mod10 <= 4) return '$n $few';
    return '$n $many';
  }

  /// The parsed+enriched node for [rawUri] from the notifier's list (falls back
  /// to a fresh parse). Nodes are keyed by a content id, so parse once to match.
  static Node? _matchNode(List<Node> nodes, String rawUri) {
    final parsed = parseProxyUri(rawUri);
    if (parsed == null) return null;
    for (final n in nodes) {
      if (n.id == parsed.id) return n;
    }
    return parsed;
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(customKeysProvider);
    final keys = async.valueOrNull?.keys ?? const <CustomKey>[];

    // Drop stale selections after a delete / reload.
    if (_selecting) {
      final live = keys.map((k) => k.rawUri).toSet();
      _selected.removeWhere((r) => !live.contains(r));
      if (_selected.isEmpty && keys.isEmpty) _selecting = false;
    }

    return Scaffold(
      appBar: _selecting
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: 'Отмена',
                onPressed: _exitSelection,
              ),
              title: Text('${_selected.length} выбрано'),
              actions: [
                IconButton(
                  icon: Icon(_selected.length == keys.length
                      ? Icons.deselect_rounded
                      : Icons.select_all_rounded),
                  tooltip: _selected.length == keys.length
                      ? 'Снять выделение'
                      : 'Выбрать все',
                  onPressed: keys.isEmpty ? null : () => _selectAll(keys),
                ),
                IconButton(
                  icon: const Icon(Icons.playlist_add_rounded),
                  tooltip: 'Объединить в подборку',
                  onPressed: _selected.length < 2 ? null : _combineSelected,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  tooltip: 'Удалить выбранные',
                  onPressed: _selected.isEmpty ? null : _deleteSelected,
                ),
                const SizedBox(width: WSpace.sm),
              ],
            )
          : AppBar(
              title: const Text('Мои ключи'),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: WSpace.lg),
                  child: hintFor('custom_keys'),
                ),
              ],
            ),
      body: PageBody(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Не удалось загрузить ключи',
            subtitle: '$e',
          ),
          data: (data) => ListView(
            padding: const EdgeInsets.fromLTRB(WSpace.lg, WSpace.sm, WSpace.lg, WSpace.xxl),
            children: [
              if (!_selecting) ...[
                _ActionsRow(
                  onPaste: _pasteFromClipboard,
                  onScan: _scanQr,
                  onSubscribe: _addSubscription,
                ),
                const SizedBox(height: WSpace.lg),
              ],
              if (data.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: WSpace.xxl),
                  child: EmptyState(
                    icon: Icons.vpn_key_rounded,
                    title: 'Пока нет своих ключей',
                    subtitle: 'Вставьте конфигурацию из буфера (Ctrl+V) или '
                        'добавьте ссылку на подписку. Ключи попадут в общий '
                        'пул с меткой [Custom].',
                  ),
                )
              else ...[
                if (data.keys.isNotEmpty) ...[
                  _SectionHeader(
                    title: 'Свои ключи (${data.keys.length})',
                    trailing: _selecting
                        ? null
                        : TextButton.icon(
                            onPressed: () =>
                                _enterSelection(data.keys.first.rawUri),
                            icon: const Icon(Icons.checklist_rounded, size: 18),
                            label: const Text('Выбрать'),
                          ),
                  ),
                  for (final key in data.keys)
                    _CustomKeyTile(
                      entry: key,
                      // Prefer the notifier's node — it carries the geo (flag)
                      // resolved for imported keys.
                      node: _matchNode(data.nodes, key.rawUri),
                      selecting: _selecting,
                      selected: _selected.contains(key.rawUri),
                      onTap: _selecting ? () => _toggle(key.rawUri) : null,
                      onLongPress: _selecting
                          ? null
                          : () => _enterSelection(key.rawUri),
                      onShowQr: () => _showQr(
                        key.rawUri,
                        _matchNode(data.nodes, key.rawUri)?.tag ?? 'Ключ',
                      ),
                      onDelete: () =>
                          ref.read(customKeysProvider.notifier).removeKey(key.rawUri),
                    ),
                  const SizedBox(height: WSpace.lg),
                ],
                if (data.bundles.isNotEmpty && !_selecting) ...[
                  _SectionHeader(title: 'Подборки (${data.bundles.length})'),
                  for (final b in data.bundles)
                    _BundleTile(
                      bundle: b,
                      onRename: () => _renameBundle(b.id, b.name),
                      onDelete: () => ref
                          .read(customKeysProvider.notifier)
                          .removeBundle(b.id),
                    ),
                  const SizedBox(height: WSpace.lg),
                ],
                if (data.subs.isNotEmpty && !_selecting) ...[
                  _SectionHeader(title: 'Подписки (${data.subs.length})'),
                  for (final sub in data.subs)
                    _SubscriptionTile(
                      sub: sub,
                      onRefresh: () => ref
                          .read(customKeysProvider.notifier)
                          .refreshSubscription(sub.url),
                      onDelete: () => ref
                          .read(customKeysProvider.notifier)
                          .removeSubscription(sub.url),
                    ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionsRow extends StatelessWidget {
  const _ActionsRow({
    required this.onPaste,
    required this.onScan,
    required this.onSubscribe,
  });

  final VoidCallback onPaste;
  final VoidCallback onScan;
  final VoidCallback onSubscribe;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FilledButton.icon(
          onPressed: onPaste,
          icon: const Icon(Icons.content_paste_rounded),
          label: const Text('Вставить из буфера (Ctrl+V)'),
        ),
        const SizedBox(height: WSpace.sm),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onScan,
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: const Text('QR-код'),
              ),
            ),
            const SizedBox(width: WSpace.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onSubscribe,
                icon: const Icon(Icons.rss_feed_rounded),
                label: const Text('Подписка'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(WSpace.xs, 0, 0, WSpace.sm),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title.toUpperCase(),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    letterSpacing: 1),
              ),
            ),
            ?trailing,
          ],
        ),
      );
}

class _CustomKeyTile extends StatelessWidget {
  const _CustomKeyTile({
    required this.entry,
    required this.node,
    required this.onShowQr,
    required this.onDelete,
    this.selecting = false,
    this.selected = false,
    this.onTap,
    this.onLongPress,
  });

  final CustomKey entry;
  final Node? node;
  final VoidCallback onShowQr;
  final VoidCallback onDelete;
  final bool selecting;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final node = this.node;
    final title = node?.tag.isNotEmpty == true
        ? node!.tag
        : (node != null
            ? '${node.endpoint.host}:${node.endpoint.port}'
            : 'Нераспознанный ключ');

    Widget leading;
    if (selecting) {
      leading = Checkbox(value: selected, onChanged: (_) => onTap?.call());
    } else if (node != null) {
      leading = FlagView(node.countryCode, size: 26);
    } else {
      leading = const Icon(Icons.help_outline_rounded, size: 26);
    }

    final card = SectionCard(
      padding: const EdgeInsets.fromLTRB(WSpace.lg, WSpace.md, WSpace.sm, WSpace.md),
      onTap: selecting ? onTap : null,
      child: Row(
        children: [
          leading,
          const SizedBox(width: WSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 2),
                if (node != null)
                  NodeTags(node, compact: true)
                else
                  Text('Не удалось разобрать',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error)),
              ],
            ),
          ),
          if (!selecting)
            PopupMenuButton<String>(
              onSelected: (v) => v == 'qr' ? onShowQr() : onDelete(),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'qr', child: Text('Показать QR')),
                PopupMenuItem(value: 'del', child: Text('Удалить')),
              ],
            ),
        ],
      ),
    );

    final spaced = Padding(
      padding: const EdgeInsets.only(bottom: WSpace.sm),
      child: card,
    );
    if (onLongPress == null) return spaced;
    return GestureDetector(onLongPress: onLongPress, child: spaced);
  }
}

class _BundleTile extends StatelessWidget {
  const _BundleTile({
    required this.bundle,
    required this.onRename,
    required this.onDelete,
  });

  final KeyBundle bundle;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: WSpace.sm),
        child: SectionCard(
          padding: const EdgeInsets.fromLTRB(
              WSpace.lg, WSpace.md, WSpace.sm, WSpace.md),
          child: Row(
            children: [
              const Icon(Icons.playlist_play_rounded, size: 24),
              const SizedBox(width: WSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(bundle.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text('${bundle.nodeIds.length} узлов · в списке локаций',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant,
                            )),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (v) => v == 'rename' ? onRename() : onDelete(),
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'rename', child: Text('Переименовать')),
                  PopupMenuItem(value: 'del', child: Text('Удалить')),
                ],
              ),
            ],
          ),
        ),
      );
}

class _SubscriptionTile extends StatelessWidget {
  const _SubscriptionTile({
    required this.sub,
    required this.onRefresh,
    required this.onDelete,
  });

  final Subscription sub;
  final VoidCallback onRefresh;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final subtitle = sub.error != null
        ? sub.error!
        : '${sub.nodeCount} узлов · обновлено ${relativeTime(sub.lastFetched)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: WSpace.sm),
      child: SectionCard(
        padding: const EdgeInsets.fromLTRB(WSpace.lg, WSpace.md, WSpace.sm, WSpace.md),
        child: Row(
          children: [
            const Icon(Icons.rss_feed_rounded, size: 24),
            const SizedBox(width: WSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    Uri.tryParse(sub.url)?.host ?? sub.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: sub.error != null
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Обновить',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: onRefresh,
            ),
            PopupMenuButton<String>(
              onSelected: (_) => onDelete(),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'del', child: Text('Удалить')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
