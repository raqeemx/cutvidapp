import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/app_theme.dart';

/// A visual timeline that highlights the selected start..end range
/// and shows the current playback position.
///
/// The start/end markers are draggable: dragging a handle updates the
/// corresponding value immediately via [onStartChanged] / [onEndChanged].
/// Tapping anywhere on the track requests a seek via [onSeek].
class RangeTimeline extends StatefulWidget {
  final int durationMs;
  final int positionMs;
  final int? startMs;
  final int? endMs;

  /// Called continuously while the start handle is dragged.
  final ValueChanged<int>? onStartChanged;

  /// Called continuously while the end handle is dragged.
  final ValueChanged<int>? onEndChanged;

  /// Called when the user taps the track to move the playhead.
  final ValueChanged<int>? onSeek;

  const RangeTimeline({
    super.key,
    required this.durationMs,
    required this.positionMs,
    required this.startMs,
    required this.endMs,
    this.onStartChanged,
    this.onEndChanged,
    this.onSeek,
  });

  @override
  State<RangeTimeline> createState() => _RangeTimelineState();
}

enum _Handle { start, end }

class _RangeTimelineState extends State<RangeTimeline> {
  // Touch slop (in px) for grabbing a handle near the touch point.
  static const double _hitSlop = 28;

  _Handle? _active;

  int _msForX(double x, double width) {
    final total = widget.durationMs <= 0 ? 1 : widget.durationMs;
    final ratio = (x / width).clamp(0.0, 1.0);
    return (ratio * total).round();
  }

  double _xForMs(int ms, double width) {
    final total = widget.durationMs <= 0 ? 1 : widget.durationMs;
    return (ms / total).clamp(0.0, 1.0) * width;
  }

  /// Decide which handle (if any) the touch is grabbing.
  _Handle? _pick(double x, double width) {
    final startX = widget.startMs != null
        ? _xForMs(widget.startMs!, width)
        : null;
    final endX = widget.endMs != null ? _xForMs(widget.endMs!, width) : null;

    final dStart = startX != null ? (x - startX).abs() : double.infinity;
    final dEnd = endX != null ? (x - endX).abs() : double.infinity;

    if (dStart > _hitSlop && dEnd > _hitSlop) return null;
    return dStart <= dEnd ? _Handle.start : _Handle.end;
  }

  void _drag(double x, double width) {
    final ms = _msForX(x, width);
    if (_active == _Handle.start) {
      // Keep start before end (with a small minimum gap).
      final maxStart = (widget.endMs ?? widget.durationMs) - 300;
      widget.onStartChanged?.call(ms.clamp(0, maxStart < 0 ? 0 : maxStart));
    } else if (_active == _Handle.end) {
      final minEnd = (widget.startMs ?? 0) + 300;
      widget.onEndChanged?.call(ms.clamp(minEnd, widget.durationMs));
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final hasRange = widget.startMs != null &&
            widget.endMs != null &&
            widget.endMs! > widget.startMs!;
        final startX =
            widget.startMs != null ? _xForMs(widget.startMs!, width) : null;
        final endX = widget.endMs != null ? _xForMs(widget.endMs!, width) : null;
        final playX = _xForMs(widget.positionMs, width);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            // A tap that isn't grabbing a handle seeks the playhead.
            if (_pick(d.localPosition.dx, width) == null) {
              widget.onSeek?.call(_msForX(d.localPosition.dx, width));
            }
          },
          onHorizontalDragStart: (d) {
            final handle = _pick(d.localPosition.dx, width);
            if (handle != null) {
              HapticFeedback.selectionClick();
              setState(() => _active = handle);
              _drag(d.localPosition.dx, width);
            }
          },
          onHorizontalDragUpdate: (d) {
            if (_active != null) _drag(d.localPosition.dx, width);
          },
          onHorizontalDragEnd: (_) => setState(() => _active = null),
          onHorizontalDragCancel: () => setState(() => _active = null),
          child: SizedBox(
            height: 64,
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
                    top: 14,
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
                // Start handle
                if (startX != null)
                  _marker(startX, AppColors.accent2,
                      active: _active == _Handle.start),
                // End handle
                if (endX != null)
                  _marker(endX, AppColors.accent,
                      active: _active == _Handle.end),
                // Playhead
                Positioned(
                  left: playX - 1,
                  top: 6,
                  bottom: 6,
                  child: Container(width: 2, color: Colors.white),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _marker(double x, Color color, {required bool active}) {
    final knobSize = active ? 22.0 : 16.0;
    return Positioned(
      left: x - knobSize / 2,
      top: 0,
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: knobSize,
            height: knobSize,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.6),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              Icons.drag_indicator_rounded,
              size: active ? 13 : 10,
              color: Colors.white,
            ),
          ),
          Container(width: 2, height: 44, color: color),
        ],
      ),
    );
  }
}
