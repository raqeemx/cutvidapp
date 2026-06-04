import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

/// Performs fully on-device, offline video cutting using FFmpeg.
/// No network access, no uploads.
class VideoCutter {
  /// Directory where saved clips are stored inside the app.
  static Future<Directory> clipsDirectory() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'clips'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> thumbsDirectory() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'thumbs'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static String _ffmpegTime(int ms) {
    final seconds = ms / 1000.0;
    return seconds.toStringAsFixed(3);
  }

  /// Cuts [sourcePath] from [startMs] to [endMs] and writes a new mp4 file.
  /// Returns the output file path on success, or null on failure.
  ///
  /// Uses re-encoding for accurate cuts (frame-accurate start/end).
  ///
  /// [onProgress] is invoked with a value in 0.0..1.0 as encoding advances,
  /// derived from FFmpeg's statistics callback (processed time vs. clip length).
  static Future<String?> cut({
    required String sourcePath,
    required int startMs,
    required int endMs,
    required String clipId,
    void Function(double progress)? onProgress,
  }) async {
    final dir = await clipsDirectory();
    final outPath = p.join(dir.path, 'clip_$clipId.mp4');

    final start = _ffmpegTime(startMs);
    final clipDurationMs = (endMs - startMs).toDouble();
    final duration = _ffmpegTime(endMs - startMs);

    // -ss after -i for accurate seeking, re-encode for frame accuracy.
    final cmd =
        "-y -i '$sourcePath' -ss $start -t $duration "
        "-c:v mpeg4 -q:v 3 -c:a aac -b:a 128k '$outPath'";

    final completer = Completer<String?>();

    await FFmpegKit.executeAsync(
      cmd,
      (session) async {
        final returnCode = await session.getReturnCode();
        if (ReturnCode.isSuccess(returnCode)) {
          final f = File(outPath);
          if (await f.exists() && await f.length() > 0) {
            onProgress?.call(1.0);
            if (!completer.isCompleted) completer.complete(outPath);
            return;
          }
        }
        if (!completer.isCompleted) completer.complete(null);
      },
      null,
      (statistics) {
        if (onProgress == null || clipDurationMs <= 0) return;
        // statistics.getTime() is the processed media time in milliseconds.
        final processed = statistics.getTime().toDouble();
        final progress = (processed / clipDurationMs).clamp(0.0, 1.0);
        onProgress(progress);
      },
    );

    return completer.future;
  }

  /// Generates a thumbnail for a video file. Returns path or empty string.
  static Future<String> generateThumbnail({
    required String videoPath,
    int positionMs = 0,
  }) async {
    try {
      final dir = await thumbsDirectory();
      final thumb = await VideoThumbnail.thumbnailFile(
        video: videoPath,
        thumbnailPath: dir.path,
        imageFormat: ImageFormat.JPEG,
        timeMs: positionMs,
        maxWidth: 400,
        quality: 70,
      );
      return thumb ?? '';
    } catch (_) {
      return '';
    }
  }
}
