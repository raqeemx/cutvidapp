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

  /// Turns a user-entered clip name into a safe file name (no extension),
  /// stripping characters that are illegal in file names. Arabic is preserved.
  static String _safeFileName(String name) {
    var s = name.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.isEmpty) s = 'clip';
    // Keep it within a reasonable length for the filesystem.
    if (s.length > 80) s = s.substring(0, 80).trim();
    return s;
  }

  /// Public helper: a unique path inside the clips library for a new clip
  /// named [name], with the correct extension for audio/video. Reused by the
  /// merge feature so merged output is saved exactly like cut clips.
  static Future<String> uniqueClipPath(
    String name, {
    required bool isAudio,
  }) async {
    final dir = await clipsDirectory();
    return _uniqueOutputPath(dir, name, isAudio ? 'm4a' : 'mp4');
  }

  /// Builds a unique output path in [dir] based on the user's [name] and
  /// [ext] (e.g. "mp4" or "m4a"), appending " (n)" only on a name clash.
  static String _uniqueOutputPath(Directory dir, String name, String ext) {
    final base = _safeFileName(name);
    var candidate = p.join(dir.path, '$base.$ext');
    var i = 1;
    while (File(candidate).existsSync()) {
      candidate = p.join(dir.path, '$base ($i).$ext');
      i++;
    }
    return candidate;
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
    String? name,
    bool isAudio = false,
    void Function(double progress)? onProgress,
  }) async {
    final dir = await clipsDirectory();
    // Audio clips are written as .m4a (AAC), video clips as .mp4.
    final ext = isAudio ? 'm4a' : 'mp4';
    // Name the saved file after what the user typed (not a random id).
    final outPath = (name != null && name.trim().isNotEmpty)
        ? _uniqueOutputPath(dir, name, ext)
        : p.join(dir.path, 'clip_$clipId.$ext');

    final start = _ffmpegTime(startMs);
    final clipDurationMs = (endMs - startMs).toDouble();
    final duration = _ffmpegTime(endMs - startMs);

    // -ss after -i for accurate seeking. Audio: drop the video stream (-vn);
    // video: re-encode to H.264 (libx264) + yuv420p + faststart for maximum
    // compatibility (plays in WhatsApp, gallery apps, other phones…).
    final cmd = isAudio
        ? "-y -i '$sourcePath' -ss $start -t $duration "
              "-vn -c:a aac -b:a 192k '$outPath'"
        : "-y -i '$sourcePath' -ss $start -t $duration "
              "-c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p "
              "-c:a aac -b:a 128k -movflags +faststart '$outPath'";

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
