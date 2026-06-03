import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  /// Requests permission to read video media from the device.
  /// Returns true if access is granted.
  static Future<bool> requestVideoAccess() async {
    if (!Platform.isAndroid) return true;

    // Android 13+ uses granular media permissions.
    final videos = await Permission.videos.request();
    if (videos.isGranted || videos.isLimited) return true;

    // Fallback for Android 12 and below.
    final storage = await Permission.storage.request();
    return storage.isGranted || storage.isLimited;
  }

  /// Requests permission to save clips to the device gallery.
  static Future<bool> requestSaveAccess() async {
    if (!Platform.isAndroid) return true;
    // On Android 13+, saving via MediaStore doesn't strictly need a permission
    // for the app's own files, but request to be safe on older versions.
    final storage = await Permission.storage.request();
    if (storage.isGranted) return true;
    final photos = await Permission.photos.request();
    return photos.isGranted || photos.isLimited || storage.isLimited;
  }
}
