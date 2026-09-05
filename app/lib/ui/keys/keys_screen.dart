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

  @override
  void initState() {
    super.initState();
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

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(customKeysProvider);

    return Scaffold(
      appBar: AppBar(
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
              _ActionsRow(
                onPaste: _pasteFromClipboard,
                onScan: _scanQr,
                onSubscribe: _addSubscription,
              ),
              const SizedBox(height: WSpace.lg),
              if (data.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: WSpace.xxl),
                  child: EmptyState(
                    icon: Icons.vpn_key_rounded,
                    title: 'Пока нет своих ключей',
                    subtitle: 'Вставьте конфигурацию из буфера или добавьте '
                        'ссылку на подписку. Ключи попадут в общий пул с меткой [Custom].',
                  ),
                )
              else ...[
                if (data.keys.isNotEmpty) ...[
                  _SectionTitle('Свои ключи (${data.keys.length})'),
                  for (final key in data.keys)
                    _CustomKeyTile(
                      entry: key,
                      onShowQr: () => _showQr(
                        key.rawUri,
                        parseProxyUri(key.rawUri)?.tag ?? 'Ключ',
                      ),
                      onDelete: () =>
                          ref.read(customKeysProvider.notifier).removeKey(key.rawUri),
                    ),
                  const SizedBox(height: WSpace.lg),
                ],
                if (data.subs.isNotEmpty) ...[
                  _SectionTitle('Подписки (${data.subs.length})'),
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
          label: const Text('Вставить из буфера'),
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(WSpace.xs, 0, 0, WSpace.sm),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: Theme.of(context).colorScheme.primary, letterSpacing: 1),
        ),
      );
}

class _CustomKeyTile extends StatelessWidget {
  const _CustomKeyTile({
    required this.entry,
    required this.onShowQr,
    required this.onDelete,
  });

  final CustomKey entry;
  final VoidCallback onShowQr;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final Node? node = parseProxyUri(entry.rawUri);
    final title = node?.tag.isNotEmpty == true
        ? node!.tag
        : (node != null ? '${node.endpoint.host}:${node.endpoint.port}' : 'Нераспознанный ключ');

    return Padding(
      padding: const EdgeInsets.only(bottom: WSpace.sm),
      child: SectionCard(
        padding: const EdgeInsets.fromLTRB(WSpace.lg, WSpace.md, WSpace.sm, WSpace.md),
        child: Row(
          children: [
            if (node != null)
              FlagView(node.countryCode, size: 26)
            else
              const Icon(Icons.help_outline_rounded, size: 26),
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
            PopupMenuButton<String>(
              onSelected: (v) => v == 'qr' ? onShowQr() : onDelete(),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'qr', child: Text('Показать QR')),
                PopupMenuItem(value: 'del', child: Text('Удалить')),
              ],
            ),
          ],
        ),
      ),
    );
  }
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
