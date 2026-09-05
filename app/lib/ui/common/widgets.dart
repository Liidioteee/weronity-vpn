import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../domain/node.dart';

/// Bordered container used for every "card" surface in the app.
class SectionCard extends StatelessWidget {
  const SectionCard({
    required this.child,
    this.padding = const EdgeInsets.all(WSpace.lg),
    this.onTap,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
    if (onTap == null) return card;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Small pill label (protocol, security, lifetime class, [Custom], …).
class Tag extends StatelessWidget {
  const Tag(this.text, {this.color, this.icon, super.key});

  final String text;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: WSpace.sm, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(WRadius.sm),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: c),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: c, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

Color securityColor(NodeSecurity s) => switch (s) {
      NodeSecurity.reality => WColors.protected,
      NodeSecurity.tls => WColors.info,
      NodeSecurity.none => WColors.textMutedDark,
    };

Color lifetimeColor(LifetimeClass c) => switch (c) {
      LifetimeClass.longLived => WColors.protected,
      LifetimeClass.shortLived => WColors.connecting,
      LifetimeClass.fresh => WColors.info,
    };

/// Row of tags describing a node.
class NodeTags extends StatelessWidget {
  const NodeTags(this.node, {this.compact = false, super.key});

  final Node node;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: WSpace.xs,
      runSpacing: WSpace.xs,
      children: [
        Tag(node.protocol.toUpperCase()),
        Tag(node.classification.security.label,
            color: securityColor(node.classification.security)),
        if (!compact) Tag(node.transport),
        Tag(node.lifetime.klass.label, color: lifetimeColor(node.lifetime.klass)),
        if (node.classification.udp) const Tag('UDP'),
        if (node.classification.cdn) const Tag('CDN'),
        if (node.isCustom)
          const Tag('Custom', color: WColors.violet, icon: Icons.vpn_key_rounded),
        if (node.recommended && !compact)
          const Tag('Рекоменд.', color: WColors.violetBright, icon: Icons.star_rounded),
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WSpace.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: muted),
            const SizedBox(height: WSpace.lg),
            Text(title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
            if (subtitle != null) ...[
              const SizedBox(height: WSpace.sm),
              Text(subtitle!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: muted)),
            ],
            if (action != null) ...[
              const SizedBox(height: WSpace.xl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
