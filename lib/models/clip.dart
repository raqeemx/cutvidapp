import 'package:hive/hive.dart';

import '../utils/media_type.dart';

part 'clip.g.dart';

@HiveType(typeId: 0)
class Clip extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String name;

  /// Absolute path to the saved clip video file inside the app library.
  @HiveField(2)
  String filePath;

  /// Path of the original source video this clip was cut from.
  @HiveField(3)
  String sourcePath;

  /// Display name of the original source video.
  @HiveField(4)
  String sourceName;

  /// Start time in milliseconds within the source video.
  @HiveField(5)
  int startMs;

  /// End time in milliseconds within the source video.
  @HiveField(6)
  int endMs;

  /// Path to a generated thumbnail image (may be empty).
  @HiveField(7)
  String thumbnailPath;

  @HiveField(8)
  int createdAtMs;

  /// Whether this clip has been exported to the device gallery/media store.
  /// Defaults to false; older records (without this field) read as false.
  @HiveField(9)
  bool savedToGallery;

  Clip({
    required this.id,
    required this.name,
    required this.filePath,
    required this.sourcePath,
    required this.sourceName,
    required this.startMs,
    required this.endMs,
    required this.thumbnailPath,
    required this.createdAtMs,
    this.savedToGallery = false,
  });

  int get durationMs => endMs - startMs;

  /// Whether this saved clip is an audio file (inferred from its extension).
  /// Old clips are video (.mp4), so they report false — no migration needed.
  bool get isAudio => isAudioFile(filePath);
}
