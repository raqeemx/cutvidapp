import 'dart:async';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

import 'merge_service.dart' show MergeService;
import 'video_cutter.dart';

class CropException implements Exception {
  final String message;
  CropException(this.message);
  @override
  String toString() => message;
}

/// Central, interceptable entry point for cropping/rotating a video.
///
/// All work is local (FFmpeg on-device); the original file is never modified —
/// a new file is written into the clips library.
class CropService {
  /// Crops [inputPath] to [cropRect] (normalized 0..1 within the rotated,
  /// display-oriented frame) after applying [rotationQuarterTurns] clockwise,
  /// and saves the result as a new library clip. Returns the output path.
  ///
  /// [videoWidth]/[videoHeight] are the display-oriented dimensions (e.g. from
  /// VideoPlayerController.value.size), so crop coordinates match the preview.
  static Future<String> startCrop({
    required String inputPath,
    required int videoWidth,
    required int videoHeight,
    required Rect cropRect,
    required int rotationQuarterTurns,
    required String name,
    void Function(double progress)? onProgress,
  }) async {
    if (!await File(inputPath).exists()) {
      throw CropException('الفيديو المختار لم يعد موجوداً.');
    }
    if (videoWidth <= 0 || videoHeight <= 0) {
      throw CropException('تعذّر قراءة أبعاد الفيديو.');
    }

    final turns = rotationQuarterTurns % 4;
    final swapped = turns.isOdd;
    final rotW = swapped ? videoHeight : videoWidth;
    final rotH = swapped ? videoWidth : videoHeight;

    // Convert the normalized rect to even pixel values within bounds.
    int even(int v) => v - (v % 2);
    var cw = even((cropRect.width * rotW).round().clamp(2, rotW));
    var ch = even((cropRect.height * rotH).round().clamp(2, rotH));
    var cx = even((cropRect.left * rotW).round().clamp(0, rotW - cw));
    var cy = even((cropRect.top * rotH).round().clamp(0, rotH - ch));
    if (cw < 2) cw = 2;
    if (ch < 2) ch = 2;

    final rotationFilter = switch (turns) {
      1 => 'transpose=1',
      2 => 'transpose=1,transpose=1',
      3 => 'transpose=2',
      _ => '',
    };
    final cropFilter = 'crop=$cw:$ch:$cx:$cy';
    final vf =
        rotationFilter.isEmpty ? cropFilter : '$rotationFilter,$cropFilter';

    final outPath = await VideoCutter.uniqueClipPath(name, isAudio: false);
    final totalMs = await MergeService.probeDurationMs(inputPath) ?? 0;

    // H.264 (libx264) + yuv420p + faststart → broadly compatible MP4.
    final args = [
      '-y',
      '-i', inputPath,
      '-vf', vf,
      '-c:v', 'libx264',
      '-preset', 'veryfast',
      '-crf', '23',
      '-pix_fmt', 'yuv420p',
      '-c:a', 'aac',
      '-b:a', '128k',
      '-movflags', '+faststart',
      outPath,
    ];

    final ok = await _execute(args, outPath, totalMs, onProgress);
    if (!ok) {
      try {
        final f = File(outPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      throw CropException('تعذّر اقتصاص الفيديو. حاول مرة أخرى.');
    }
    return outPath;
  }

  static Future<bool> _execute(
    List<String> args,
    String outPath,
    int totalMs,
    void Function(double)? onProgress,
  ) async {
    final completer = Completer<bool>();
    await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        final rc = await session.getReturnCode();
        final f = File(outPath);
        final good = ReturnCode.isSuccess(rc) &&
            await f.exists() &&
            await f.length() > 0;
        if (good) onProgress?.call(1.0);
        if (!completer.isCompleted) completer.complete(good);
      },
      null,
      (stats) {
        if (onProgress == null || totalMs <= 0) return;
        final progress = (stats.getTime().toDouble() / totalMs).clamp(0.0, 1.0);
        onProgress(progress);
      },
    );
    return completer.future;
  }
}
