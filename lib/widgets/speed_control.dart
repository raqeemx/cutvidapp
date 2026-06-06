import 'package:flutter/material.dart';

import '../utils/app_theme.dart';

/// A compact playback-speed picker (0.5x … 2x).
///
/// Purely a viewing/review aid — it changes the live playback rate only and
/// never affects the saved file or the cut.
class SpeedControl extends StatelessWidget {
  final double speed;
  final ValueChanged<double> onChanged;
  const SpeedControl({super.key, required this.speed, required this.onChanged});

  static const List<double> speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  static String label(double s) {
    final str = s.toStringAsFixed(2);
    return str
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      tooltip: 'سرعة التشغيل',
      initialValue: speed,
      color: AppColors.surface,
      onSelected: onChanged,
      itemBuilder: (ctx) => speeds
          .map(
            (s) => PopupMenuItem<double>(
              value: s,
              child: Row(
                children: [
                  Icon(
                    s == speed
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 18,
                    color: s == speed
                        ? AppColors.accent
                        : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${label(s)}x',
                    style: const TextStyle(color: AppColors.textPrimary),
                  ),
                ],
              ),
            ),
          )
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surfaceLight,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.speed_rounded,
                size: 16, color: AppColors.accent),
            const SizedBox(width: 4),
            Text(
              '${label(speed)}x',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
