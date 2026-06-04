import 'package:hive_flutter/hive_flutter.dart';

/// Remembers the last playback position for each video, so reopening a video
/// resumes from where the user left off. Keyed by a stable string (the source
/// video path, or a saved clip's id).
class PlaybackStore {
  static const String _boxName = 'playback_positions';
  static Box? _box;

  static Future<void> init() async {
    _box = await Hive.openBox(_boxName);
  }

  /// Returns the saved position in milliseconds, or null if none.
  static int? getPosition(String key) {
    final v = _box?.get(key);
    return v is int ? v : null;
  }

  static Future<void> setPosition(String key, int ms) async {
    if (ms <= 0) {
      await _box?.delete(key);
    } else {
      await _box?.put(key, ms);
    }
  }

  static Future<void> clear(String key) async => _box?.delete(key);
}
