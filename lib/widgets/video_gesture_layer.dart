import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A reusable gesture layer for video screens.
///
/// - Single tap  → [onTap] (play / pause).
/// - Double tap on the right half → seek forward by [seekSeconds].
/// - Double tap on the left half  → seek backward by [seekSeconds].
///
/// A brief YouTube-style flash (icon + accumulated seconds) confirms the jump.
/// Place this as a `Positioned.fill` layer above the `VideoPlayer` and below any
/// genuinely tappable controls (e.g. a fullscreen button). Any visual overlays
/// it should not block (like a centered play icon) must be wrapped in
/// [IgnorePointer] so taps reach this layer.
class VideoGestureLayer extends StatefulWidget {
  final VoidCallback onTap;

  /// Called with the signed delta in milliseconds (negative = backward).
  final void Function(int deltaMs) onSeek;

  final int seekSeconds;

  const VideoGestureLayer({
    super.key,
    required this.onTap,
    required this.onSeek,
    this.seekSeconds = 5,
  });

  @override
  State<VideoGestureLayer> createState() => _VideoGestureLayerState();
}

enum _Side { left, right }

class _VideoGestureLayerState extends State<VideoGestureLayer> {
  _Side? _side;
  int _seconds = 0;
  Offset _lastTapPos = Offset.zero;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _handleDoubleTap(double width) {
    final side = _lastTapPos.dx < width / 2 ? _Side.left : _Side.right;
    // Reset the accumulator when switching sides.
    if (side != _side) _seconds = 0;
    _seconds += widget.seekSeconds;
    _side = side;

    final delta = widget.seekSeconds * 1000;
    widget.onSeek(side == _Side.right ? delta : -delta);
    HapticFeedback.selectionClick();
    setState(() {});

    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) {
        setState(() {
          _side = null;
          _seconds = 0;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onTap,
                onDoubleTapDown: (d) => _lastTapPos = d.localPosition,
                onDoubleTap: () => _handleDoubleTap(width),
              ),
            ),
            if (_side != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: Align(
                    alignment: _side == _Side.left
                        ? Alignment.centerLeft
                        : Alignment.centerRight,
                    child: FractionallySizedBox(
                      widthFactor: 0.5,
                      child: Center(child: _buildFlash()),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildFlash() {
    final forward = _side == _Side.right;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: const BoxDecoration(
        color: Colors.black54,
        shape: BoxShape.circle,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            forward ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
            color: Colors.white,
            size: 32,
          ),
          const SizedBox(height: 2),
          Text(
            '$_seconds ث',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
