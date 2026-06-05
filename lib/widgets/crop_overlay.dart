import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/app_theme.dart';

enum _Corner { topLeft, topRight, bottomLeft, bottomRight }

/// An interactive crop rectangle drawn over the (already rotated) video frame.
///
/// Works in the pixel space of [displaySize] but reports the rectangle in
/// normalized 0..1 coordinates via [onChanged]. The parent owns the rect, so
/// this widget renders straight from [rect] (no internal drift).
class CropOverlay extends StatelessWidget {
  final Size displaySize;
  final Rect rect; // normalized 0..1
  final double? aspectRatio; // width/height; null = free
  final ValueChanged<Rect> onChanged;

  const CropOverlay({
    super.key,
    required this.displaySize,
    required this.rect,
    required this.aspectRatio,
    required this.onChanged,
  });

  static const double _minPx = 40;
  static const double _handle = 28;

  Rect get _pr => Rect.fromLTWH(
        rect.left * displaySize.width,
        rect.top * displaySize.height,
        rect.width * displaySize.width,
        rect.height * displaySize.height,
      );

  void _report(Rect px) {
    final w = displaySize.width, h = displaySize.height;
    onChanged(Rect.fromLTRB(
      (px.left / w).clamp(0.0, 1.0),
      (px.top / h).clamp(0.0, 1.0),
      (px.right / w).clamp(0.0, 1.0),
      (px.bottom / h).clamp(0.0, 1.0),
    ));
  }

  void _move(Offset delta) {
    final w = displaySize.width, h = displaySize.height;
    final pr = _pr;
    final left = (pr.left + delta.dx).clamp(0.0, w - pr.width);
    final top = (pr.top + delta.dy).clamp(0.0, h - pr.height);
    _report(Rect.fromLTWH(left, top, pr.width, pr.height));
  }

  void _resize(_Corner corner, Offset delta) {
    final w = displaySize.width, h = displaySize.height;
    final pr = _pr;

    // Opposite (anchor) corner stays fixed; signs describe the moving corner.
    final double anchorX, anchorY;
    final double hx, vy; // direction of the moving corner relative to anchor
    switch (corner) {
      case _Corner.topLeft:
        anchorX = pr.right;
        anchorY = pr.bottom;
        hx = -1;
        vy = -1;
      case _Corner.topRight:
        anchorX = pr.left;
        anchorY = pr.bottom;
        hx = 1;
        vy = -1;
      case _Corner.bottomLeft:
        anchorX = pr.right;
        anchorY = pr.top;
        hx = -1;
        vy = 1;
      case _Corner.bottomRight:
        anchorX = pr.left;
        anchorY = pr.top;
        hx = 1;
        vy = 1;
    }

    final movingX = (((hx < 0) ? pr.left : pr.right) + delta.dx).clamp(0.0, w);
    final movingY = (((vy < 0) ? pr.top : pr.bottom) + delta.dy).clamp(0.0, h);

    var width = (movingX - anchorX).abs();
    var height = (movingY - anchorY).abs();

    final maxWidth = hx > 0 ? (w - anchorX) : anchorX;
    final maxHeight = vy > 0 ? (h - anchorY) : anchorY;

    if (aspectRatio != null) {
      // Drive by width, derive height, then clamp by available space.
      height = width / aspectRatio!;
      if (height > maxHeight) {
        height = maxHeight;
        width = height * aspectRatio!;
      }
      if (width > maxWidth) {
        width = maxWidth;
        height = width / aspectRatio!;
      }
    } else {
      width = math.min(width, maxWidth);
      height = math.min(height, maxHeight);
    }

    width = width.clamp(_minPx, w);
    height = height.clamp(_minPx, h);

    final mx = anchorX + hx * width;
    final my = anchorY + vy * height;
    _report(Rect.fromLTRB(
      math.min(anchorX, mx),
      math.min(anchorY, my),
      math.max(anchorX, mx),
      math.max(anchorY, my),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final pr = _pr;
    return SizedBox(
      width: displaySize.width,
      height: displaySize.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Dim outside + border.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _CropPainter(pr)),
            ),
          ),
          // Body drag.
          Positioned(
            left: pr.left,
            top: pr.top,
            width: pr.width,
            height: pr.height,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) => _move(d.delta),
              child: const SizedBox.expand(),
            ),
          ),
          _cornerHandle(_Corner.topLeft, pr.topLeft),
          _cornerHandle(_Corner.topRight, pr.topRight),
          _cornerHandle(_Corner.bottomLeft, pr.bottomLeft),
          _cornerHandle(_Corner.bottomRight, pr.bottomRight),
        ],
      ),
    );
  }

  Widget _cornerHandle(_Corner corner, Offset at) {
    return Positioned(
      left: at.dx - _handle / 2,
      top: at.dy - _handle / 2,
      width: _handle,
      height: _handle,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => _resize(corner, d.delta),
        child: Center(
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: AppColors.accent,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  final Rect rect;
  _CropPainter(this.rect);

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black54;
    // Four rectangles around the crop window.
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, rect.top), dim);
    canvas.drawRect(
        Rect.fromLTRB(0, rect.bottom, size.width, size.height), dim);
    canvas.drawRect(Rect.fromLTRB(0, rect.top, rect.left, rect.bottom), dim);
    canvas.drawRect(
        Rect.fromLTRB(rect.right, rect.top, size.width, rect.bottom), dim);

    final border = Paint()
      ..color = AppColors.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(rect, border);

    // Rule-of-thirds guides.
    final guide = Paint()
      ..color = Colors.white54
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final dx = rect.left + rect.width * i / 3;
      final dy = rect.top + rect.height * i / 3;
      canvas.drawLine(Offset(dx, rect.top), Offset(dx, rect.bottom), guide);
      canvas.drawLine(Offset(rect.left, dy), Offset(rect.right, dy), guide);
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) => old.rect != rect;
}
