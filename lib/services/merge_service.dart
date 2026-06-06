import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'video_cutter.dart';

/// How clips are joined together.
enum MergeMode {
  /// Stream copy with the concat demuxer — no re-encoding. Fast, but requires
  /// the inputs to share the same codec/params (true for the app's own clips).
  fast,

  /// Re-encode and normalize (resolution/fps/sample-rate) with the concat
  /// filter — slower but works across mismatched sources.
  slow,
}

class MergeException implements Exception {
  final String message;
  MergeException(this.message);
  @override
  String toString() => message;
}

/// Central entry point for joining several clips into one new file.
///
/// [startMerge] is intentionally the single place merging happens, so it can
/// later be gated behind a purchase/subscription check without touching the UI.
class MergeService {
  // Normalization target for the slow (re-encode) video path.
  static const int _targetW = 1280;
  static const int _targetH = 720;
  static const int _targetFps = 30;
  static const int _targetSampleRate = 44100;

  /// Probes a media file's duration in milliseconds, or null on failure.
  static Future<int?> probeDurationMs(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      final durStr = info?.getDuration();
      if (durStr == null) return null;
      final seconds = double.tryParse(durStr);
      if (seconds == null) return null;
      return (seconds * 1000).round();
    } catch (_) {
      return null;
    }
  }

  /// Merges [inputPaths] (already ordered) into one new file saved in the
  /// clips library, and returns its path.
  ///
  /// Throws [MergeException] with a user-facing message on any failure.
  static Future<String> startMerge({
    required List<String> inputPaths,
    required bool isAudio,
    required MergeMode mode,
    required String name,
    void Function(double progress)? onProgress,
  }) async {
    if (inputPaths.length < 2) {
      throw MergeException('اختر مقطعين على الأقل للدمج.');
    }
    for (final path in inputPaths) {
      if (!await File(path).exists()) {
        throw MergeException('أحد الملفات المختارة لم يعد موجوداً.');
      }
    }

    // Total duration (for an accurate progress percentage). Best-effort.
    var totalMs = 0;
    for (final path in inputPaths) {
      totalMs += (await probeDurationMs(path)) ?? 0;
    }

    final outPath = await VideoCutter.uniqueClipPath(name, isAudio: isAudio);

    final ok = mode == MergeMode.fast
        ? await _runFast(inputPaths, outPath, totalMs, onProgress)
        : await _runSlow(inputPaths, isAudio, outPath, totalMs, onProgress);

    if (!ok) {
      // Clean up a partial/empty output.
      try {
        final f = File(outPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      throw MergeException(
        mode == MergeMode.fast
            ? 'تعذّر الدمج السريع — قد تكون المقاطع بإعدادات مختلفة. جرّب الدمج البطيء.'
            : 'تعذّر دمج المقاطع. تأكد من صلاحية الملفات وحاول مجدداً.',
      );
    }
    return outPath;
  }

  // ---- Fast: concat demuxer + stream copy ----
  static Future<bool> _runFast(
    List<String> inputs,
    String outPath,
    int totalMs,
    void Function(double)? onProgress,
  ) async {
    final listPath = await _writeConcatList(inputs);
    try {
      final args = [
        '-y',
        '-f', 'concat',
        '-safe', '0',
        '-i', listPath,
        '-c', 'copy',
        '-movflags', '+faststart',
        outPath,
      ];
      return _execute(args, outPath, totalMs, onProgress);
    } finally {
      try {
        await File(listPath).delete();
      } catch (_) {}
    }
  }

  // ---- Slow: concat filter + re-encode (normalizes mismatched inputs) ----
  static Future<bool> _runSlow(
    List<String> inputs,
    bool isAudio,
    String outPath,
    int totalMs,
    void Function(double)? onProgress,
  ) async {
    final args = <String>['-y'];
    for (final input in inputs) {
      args.addAll(['-i', input]);
    }

    final n = inputs.length;
    final filter = StringBuffer();
    if (isAudio) {
      for (var i = 0; i < n; i++) {
        filter.write('[$i:a]aresample=$_targetSampleRate[a$i];');
      }
      for (var i = 0; i < n; i++) {
        filter.write('[a$i]');
      }
      filter.write('concat=n=$n:v=0:a=1[outa]');
      args.addAll([
        '-filter_complex', filter.toString(),
        '-map', '[outa]',
        '-c:a', 'aac',
        '-b:a', '192k',
        outPath,
      ]);
    } else {
      for (var i = 0; i < n; i++) {
        filter.write(
          '[$i:v]scale=$_targetW:$_targetH:force_original_aspect_ratio=decrease,'
          'pad=$_targetW:$_targetH:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=$_targetFps[v$i];'
          '[$i:a]aresample=$_targetSampleRate[a$i];',
        );
      }
      for (var i = 0; i < n; i++) {
        filter.write('[v$i][a$i]');
      }
      filter.write('concat=n=$n:v=1:a=1[outv][outa]');
      args.addAll([
        '-filter_complex', filter.toString(),
        '-map', '[outv]',
        '-map', '[outa]',
        '-c:v', 'libx264',
        '-preset', 'veryfast',
        '-crf', '23',
        '-pix_fmt', 'yuv420p',
        '-c:a', 'aac',
        '-b:a', '192k',
        '-movflags', '+faststart',
        outPath,
      ]);
    }
    return _execute(args, outPath, totalMs, onProgress);
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

  /// Writes the concat-demuxer list file, escaping single quotes in paths.
  static Future<String> _writeConcatList(List<String> inputs) async {
    final dir = await getTemporaryDirectory();
    final listFile = File(
      p.join(dir.path, 'merge_list_${DateTime.now().millisecondsSinceEpoch}.txt'),
    );
    final buffer = StringBuffer();
    for (final input in inputs) {
      final escaped = input.replaceAll("'", "'\\''");
      buffer.writeln("file '$escaped'");
    }
    await listFile.writeAsString(buffer.toString());
    return listFile.path;
  }
}
