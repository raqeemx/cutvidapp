import 'package:flutter/services.dart';

/// A video file resolved from an external open/share intent.
class IncomingVideo {
  final String path;
  final String name;
  const IncomingVideo({required this.path, required this.name});
}

/// Bridge to the native handling of videos opened from outside the app.
///
/// The native side captures the incoming URI (cold/warm start) and copies it
/// from content:// to a real cache file, so the rest of the app keeps working
/// with plain file paths (VideoPlayer + FFmpeg).
class IncomingMedia {
  static const MethodChannel _method = MethodChannel('clip_master/incoming');
  static const EventChannel _events = EventChannel('clip_master/incoming_events');

  /// Raw URI string from the launching intent, or null. Consumed once.
  static Future<String?> getInitialMedia() async {
    try {
      return await _method.invokeMethod<String>('getInitialMedia');
    } catch (_) {
      return null;
    }
  }

  /// Copies a content://, file:// (or other) URI into a temp cache file.
  /// Throws on failure. The native copy runs off the main thread.
  static Future<IncomingVideo> resolve(String uri) async {
    final res = await _method.invokeMapMethod<String, dynamic>(
      'copyUriToTempFile',
      {'uri': uri},
    );
    final path = res?['path'] as String?;
    if (path == null || path.isEmpty) {
      throw Exception('تعذّر تحضير الملف.');
    }
    return IncomingVideo(
      path: path,
      name: (res?['name'] as String?)?.trim().isNotEmpty == true
          ? res!['name'] as String
          : 'فيديو',
    );
  }

  /// Stream of raw URI strings delivered while the app is running (warm start).
  static Stream<String> get stream =>
      _events.receiveBroadcastStream().where((e) => e is String).cast<String>();
}
