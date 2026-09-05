import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';

/// The ℹ️ affordance required on every parameter (ТЗ §3). Tapping opens a
/// bottom sheet with a plain-language explanation.
class InfoHint extends StatelessWidget {
  const InfoHint({
    required this.title,
    required this.body,
    this.size = 18,
    super.key,
  });

  final String title;
  final String body;
  final double size;

  void _open(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            WSpace.xl,
            WSpace.sm,
            WSpace.xl,
            WSpace.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: WSpace.md),
                  Expanded(
                    child: Text(title,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                ],
              ),
              const SizedBox(height: WSpace.lg),
              Text(
                body,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Подсказка: $title',
      child: InkResponse(
        onTap: () => _open(context),
        radius: size + 6,
        child: Icon(
          Icons.info_outline_rounded,
          size: size,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A label followed by its ℹ️ hint — the common pairing in settings rows.
class LabeledHint extends StatelessWidget {
  const LabeledHint(this.text, {required this.hint, this.style, super.key});

  final String text;
  final ({String title, String body}) hint;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: Text(text, style: style)),
        const SizedBox(width: WSpace.sm),
        InfoHint(title: hint.title, body: hint.body),
      ],
    );
  }
}
