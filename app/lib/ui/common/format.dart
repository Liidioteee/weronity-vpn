/// Small human-readable formatters shared across the UI.
library;

String formatBytes(int bytes, {int decimals = 1}) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 ? 0 : decimals;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

String formatSpeed(double bytesPerSecond) {
  final bits = bytesPerSecond * 8;
  const units = ['bps', 'Kbps', 'Mbps', 'Gbps'];
  var value = bits;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 || unit == 0 ? 0 : 1)} ${units[unit]}';
}

String formatPing(int? ms) => ms == null ? '—' : '$ms мс';

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

String formatAge(int hours) {
  if (hours < 1) return '< 1 ч';
  if (hours < 24) return '$hours ч';
  final days = hours ~/ 24;
  return '$days дн';
}

String relativeTime(DateTime? t) {
  if (t == null || t.millisecondsSinceEpoch == 0) return 'никогда';
  final diff = DateTime.now().difference(t);
  if (diff.inMinutes < 1) return 'только что';
  if (diff.inMinutes < 60) return '${diff.inMinutes} мин назад';
  if (diff.inHours < 24) return '${diff.inHours} ч назад';
  return '${diff.inDays} дн назад';
}
