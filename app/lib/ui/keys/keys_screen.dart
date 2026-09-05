import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/hints.dart';
import '../../app/theme/tokens.dart';
import '../common/widgets.dart';

/// Placeholder for the custom-keys manager (paste / QR / subscription URL).
/// Implemented in Phase 2b.
class KeysScreen extends ConsumerWidget {
  const KeysScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Мои ключи'),
        actions: [Padding(padding: const EdgeInsets.only(right: WSpace.lg), child: hintFor('custom_keys'))],
      ),
      body: const EmptyState(
        icon: Icons.vpn_key_rounded,
        title: 'Свои ключи и подписки',
        subtitle: 'Вставка из буфера, QR-код и ссылки на подписку появятся здесь '
            '(Фаза 2b). Ключи попадают в общий пул с меткой [Custom].',
      ),
    );
  }
}
