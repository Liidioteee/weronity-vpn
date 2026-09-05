import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/hints.dart';
import '../../app/theme/tokens.dart';
import '../../core/connection_controller.dart';
import '../../state/providers.dart';
import '../common/widgets.dart';

/// Pro → Графики. Rolling throughput and latency from the connection ticker.
class GraphsScreen extends ConsumerWidget {
  const GraphsScreen({super.key});

  static const _window = 120; // last N samples shown

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(connectionControllerProvider);
    final all = controller.history;

    if (all.length < 2) {
      return const PageBodyPadded(
        child: EmptyState(
          icon: Icons.show_chart_rounded,
          title: 'Нет данных',
          subtitle: 'Графики появятся через пару секунд после подключения.',
        ),
      );
    }

    final pts = all.length > _window
        ? all.sublist(all.length - _window)
        : all;
    final x0 = pts.first.elapsed.inSeconds.toDouble();

    List<FlSpot> spots(double Function(TrafficPoint) y) => [
          for (final p in pts)
            FlSpot(p.elapsed.inSeconds.toDouble() - x0, y(p)),
        ];

    final downMbps = spots((p) => p.downBps * 8 / 1e6);
    final upMbps = spots((p) => p.upBps * 8 / 1e6);
    final ping = spots((p) => p.pingMs.toDouble());

    final maxThroughput = [
      for (final s in [...downMbps, ...upMbps]) s.y,
    ].fold<double>(1, (m, v) => v > m ? v : m);
    final maxPing = ping.fold<double>(
      10,
      (m, s) => s.y > m ? s.y : m,
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        WSpace.lg,
        WSpace.md,
        WSpace.lg,
        WSpace.xxl,
      ),
      children: [
        Row(
          children: [
            Text(
              'Активность за ${pts.length} с',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const Spacer(),
            hintFor('net_graphs'),
          ],
        ),
        const SizedBox(height: WSpace.sm),
        _ChartCard(
          title: 'Пропускная способность, Мбит/с',
          legend: const [
            ('Загрузка', WColors.protected),
            ('Отдача', WColors.info),
          ],
          child: LineChart(
            _lineData(
              context,
              bars: [
                _bar(downMbps, WColors.protected, fill: true),
                _bar(upMbps, WColors.info),
              ],
              maxY: maxThroughput * 1.2,
            ),
          ),
        ),
        const SizedBox(height: WSpace.md),
        _ChartCard(
          title: 'Задержка, мс',
          legend: const [('RTT', WColors.violet)],
          child: LineChart(
            _lineData(
              context,
              bars: [_bar(ping, WColors.violet, fill: true)],
              maxY: maxPing * 1.25,
            ),
          ),
        ),
      ],
    );
  }

  LineChartBarData _bar(List<FlSpot> spots, Color color, {bool fill = false}) =>
      LineChartBarData(
        spots: spots,
        isCurved: true,
        curveSmoothness: 0.2,
        color: color,
        barWidth: 2.4,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(
          show: fill,
          color: color.withValues(alpha: 0.14),
        ),
      );

  LineChartData _lineData(
    BuildContext context, {
    required List<LineChartBarData> bars,
    required double maxY,
  }) {
    final grid = Theme.of(context).colorScheme.outline.withValues(alpha: 0.4);
    return LineChartData(
      minY: 0,
      maxY: maxY <= 0 ? 1 : maxY,
      lineBarsData: bars,
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(),
        rightTitles: const AxisTitles(),
        bottomTitles: const AxisTitles(),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 38,
            getTitlesWidget: (v, meta) => Text(
              v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ),
      ),
      gridData: FlGridData(
        drawVerticalLine: false,
        getDrawingHorizontalLine: (v) => FlLine(color: grid, strokeWidth: 1),
      ),
      borderData: FlBorderData(show: false),
      lineTouchData: const LineTouchData(enabled: false),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.legend,
    required this.child,
  });

  final String title;
  final List<(String, Color)> legend;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              for (final (label, color) in legend)
                Padding(
                  padding: const EdgeInsets.only(left: WSpace.sm),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        label,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: WSpace.lg),
          SizedBox(height: 170, child: child),
        ],
      ),
    );
  }
}

/// A [PageBody]-style padded wrapper for the empty state.
class PageBodyPadded extends StatelessWidget {
  const PageBodyPadded({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(WSpace.lg),
        child: child,
      );
}
