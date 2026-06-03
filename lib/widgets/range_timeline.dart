import 'package:flutter/material.dart';

import '../utils/app_theme.dart';

/// A visual timeline that highlights the selected start..end range
/// and shows the current playback position.
class RangeTimeline extends StatelessWidget {
  final int durationMs;
  final int positionMs;
  final int? startMs;
  final int? endMs;

  const RangeTimeline({
    super.key,
    required this.durationMs,
    required this.positionMs,
    required this.startMs,
    required this.endMs,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final total = durationMs <= 0 ? 1 : durationMs;

        double posFor(int ms) => (ms / total).clamp(0.0, 1.0) * width;

        final hasRange = startMs != null && endMs != null && endMs! > startMs!;
        final startX = startMs != null ? posFor(startMs!) : null;
        final endX = endMs != null ? posFor(endMs!) : null;
        final playX = posFor(positionMs);

        return SizedBox(
          height: 56,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Track
              Align(
                alignment: Alignment.center,
                child: Container(
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceLight,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              // Selected range
              if (hasRange)
                Positioned(
                  left: startX,
                  top: 10,
                  width: (endX! - startX!).clamp(0, width),
                  height: 36,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppColors.accent2, AppColors.accent],
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              // Start marker
              if (startX != null) _marker(startX, AppColors.accent2, true),
              // End marker
              if (endX != null) _marker(endX, AppColors.accent, false),
              // Playhead
              Positioned(
                left: playX - 1,
                top: 2,
                bottom: 2,
                child: Container(width: 2, color: Colors.white),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _marker(double x, Color color, bool isStart) {
    return Positioned(
      left: x - 6,
      top: 4,
      child: Column(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          Container(width: 2, height: 36, color: color),
        ],
      ),
    );
  }
}
