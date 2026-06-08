import 'package:saver_gallery/saver_gallery.dart';

import '../models/clip.dart';
import '../utils/media_type.dart';

/// Shared logic for saving a clip to the device gallery/media store, used by
/// both the single "save to gallery" action and the bulk export.
class GalleryExporter {
  /// Saves [clip] to the gallery using the user's name and the right media
  /// folder/extension. Returns true on success.
  static Future<bool> save(Clip clip) async {
    final safeName = clip.name.trim().replaceAll(
      RegExp(r'[\\/:*?"<>|\x00-\x1F]'),
      '_',
    );
    final ext = fileExtension(clip.filePath);
    final relPath = clip.isAudio ? 'Music/TrimXClip' : 'Movies/TrimXClip';
    try {
      final result = await SaverGallery.saveFile(
        filePath: clip.filePath,
        fileName: '${safeName.isEmpty ? 'clip' : safeName}'
            '${ext.isEmpty ? (clip.isAudio ? '.m4a' : '.mp4') : ext}',
        androidRelativePath: relPath,
        skipIfExists: false,
      );
      return result.isSuccess;
    } catch (_) {
      return false;
    }
  }
}
