import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Camembert léger sans dépendance externe.
class SimplePieChart extends StatelessWidget {
  final Map<String, dynamic> data;
  final double size;

  const SimplePieChart({super.key, required this.data, this.size = 160});

  static const _palette = [
    Color(0xFF3B82F6),
    Color(0xFF10B981),
    Color(0xFFF59E0B),
    Color(0xFFEF4444),
    Color(0xFF8B5CF6),
    Color(0xFF06B6D4),
    Color(0xFFEC4899),
    Color(0xFF64748B),
  ];

  @override
  Widget build(BuildContext context) {
    final entries = data.entries
        .where((e) => e.value is num && (e.value as num) > 0)
        .map((e) => MapEntry(e.key.toString(), (e.value as num).toDouble()))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    if (entries.isEmpty) {
      return SizedBox(
        height: size,
        child: Center(child: Text('Aucune donnée', style: TextStyle(color: Colors.grey.shade600, fontSize: 13))),
      );
    }

    final total = entries.fold<double>(0, (s, e) => s + e.value);
    final cs = Theme.of(context).colorScheme;
    final legend = TextStyle(fontSize: 12, color: cs.onSurface);
    final valueStyle = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.onSurface);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: size,
              height: size,
              child: CustomPaint(
                painter: _PiePainter(
                  entries: entries,
                  total: total,
                  colors: _palette,
                  holeColor: cs.surfaceContainer,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: entries.take(8).map((e) {
                  final i = entries.indexOf(e);
                  final pct = total > 0 ? (e.value / total * 100) : 0.0;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Container(width: 10, height: 10, decoration: BoxDecoration(color: _palette[i % _palette.length], shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Expanded(child: Text(e.key, style: legend, overflow: TextOverflow.ellipsis)),
                        Text('${e.value.toInt()} (${pct.toStringAsFixed(0)}%)', style: valueStyle),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PiePainter extends CustomPainter {
  final List<MapEntry<String, double>> entries;
  final double total;
  final List<Color> colors;
  final Color holeColor;

  _PiePainter({required this.entries, required this.total, required this.colors, required this.holeColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 * 0.92;
    var start = -math.pi / 2;

    for (var i = 0; i < entries.length; i++) {
      final sweep = total > 0 ? (entries[i].value / total) * 2 * math.pi : 0.0;
      final paint = Paint()
        ..color = colors[i % colors.length]
        ..style = PaintingStyle.fill;
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius), start, sweep, true, paint);
      start += sweep;
    }

    final hole = Paint()..color = holeColor;
    canvas.drawCircle(center, radius * 0.45, hole);
  }

  @override
  bool shouldRepaint(covariant _PiePainter old) => old.entries != entries || old.total != total;
}
