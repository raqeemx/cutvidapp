import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/clip.dart';
import 'clip_repository.dart';
import 'video_cutter.dart';

enum ExportStatus { waiting, processing, done, failed }

/// A single cut queued for background export.
class ExportJob {
  final String id;
  final String name;
  final String sourcePath;
  final String sourceName;
  final int startMs;
  final int endMs;
  final bool isAudio;

  ExportStatus status;
  double progress; // 0..1 while processing
  String? error;

  ExportJob({
    required this.id,
    required this.name,
    required this.sourcePath,
    required this.sourceName,
    required this.startMs,
    required this.endMs,
    required this.isAudio,
    this.status = ExportStatus.waiting,
    this.progress = 0,
    this.error,
  });

  int get durationMs => endMs - startMs;
}

/// Background cutting queue with a single sequential worker.
///
/// The UI never blocks: jobs are added and processed one-by-one (only one
/// FFmpeg session runs at a time). Successful jobs are saved to
/// [ClipRepository]; failures are flagged and the queue keeps going.
class ExportQueueService extends ChangeNotifier {
  final ClipRepository _repo;
  ExportQueueService(this._repo);

  final List<ExportJob> _jobs = [];
  bool _processing = false;
  bool _cancelRequested = false;

  List<ExportJob> get jobs => List.unmodifiable(_jobs);
  bool get isProcessing => _processing;

  ExportJob? get currentJob {
    for (final j in _jobs) {
      if (j.status == ExportStatus.processing) return j;
    }
    return null;
  }

  int get waitingCount =>
      _jobs.where((j) => j.status == ExportStatus.waiting).length;

  /// True while there is anything in flight or queued.
  bool get hasActiveWork => currentJob != null || waitingCount > 0;

  /// Adds a job and starts the worker if idle.
  void add(ExportJob job) {
    _jobs.add(job);
    notifyListeners();
    _processNext();
  }

  /// Removes a job that hasn't started yet.
  void removeWaiting(String id) {
    final idx = _jobs.indexWhere((j) => j.id == id);
    if (idx < 0) return;
    if (_jobs[idx].status == ExportStatus.waiting) {
      _jobs.removeAt(idx);
      notifyListeners();
    }
  }

  /// Removes finished (done/failed) entries from the list.
  void clearFinished() {
    _jobs.removeWhere(
      (j) => j.status == ExportStatus.done || j.status == ExportStatus.failed,
    );
    notifyListeners();
  }

  /// Safely cancels the job currently being cut (stops FFmpeg, drops the job).
  Future<void> cancelCurrent() async {
    if (currentJob == null) return;
    _cancelRequested = true;
    await FFmpegKit.cancel();
  }

  ExportJob? _nextWaiting() {
    for (final j in _jobs) {
      if (j.status == ExportStatus.waiting) return j;
    }
    return null;
  }

  Future<void> _processNext() async {
    if (_processing) return;
    final job = _nextWaiting();
    if (job == null) {
      _processing = false;
      await WakelockPlus.disable();
      notifyListeners();
      return;
    }

    _processing = true;
    _cancelRequested = false;
    job.status = ExportStatus.processing;
    job.progress = 0;
    notifyListeners();
    await WakelockPlus.enable();

    try {
      final clipId = const Uuid().v4();
      final outPath = await VideoCutter.cut(
        sourcePath: job.sourcePath,
        startMs: job.startMs,
        endMs: job.endMs,
        clipId: clipId,
        name: job.name,
        isAudio: job.isAudio,
        onProgress: (p) {
          job.progress = p;
          notifyListeners();
        },
      );

      if (_cancelRequested) {
        // User cancelled — drop the job entirely.
        _jobs.removeWhere((j) => j.id == job.id);
      } else if (outPath == null) {
        job.status = ExportStatus.failed;
        job.error = 'تعذّر قص هذا المقطع';
      } else {
        final thumb = job.isAudio
            ? ''
            : await VideoCutter.generateThumbnail(videoPath: outPath);
        final clip = Clip(
          id: clipId,
          name: job.name,
          filePath: outPath,
          sourcePath: job.sourcePath,
          sourceName: job.sourceName,
          startMs: job.startMs,
          endMs: job.endMs,
          thumbnailPath: thumb,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
        );
        await _repo.addClip(clip);
        job.status = ExportStatus.done;
        job.progress = 1.0;
      }
    } catch (e) {
      job.status = ExportStatus.failed;
      job.error = e.toString();
    } finally {
      _processing = false;
      _cancelRequested = false;
      notifyListeners();
      // Continue with the next waiting job (if any).
      _processNext();
    }
  }
}
