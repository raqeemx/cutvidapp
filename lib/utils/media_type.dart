// Helpers for distinguishing audio from video by file name/extension.
//
// The app stores the media type implicitly in the file extension rather than
// in the Hive model, so clips saved before audio support (all `.mp4` video)
// keep working without any data migration.

const Set<String> kAudioExtensions = {
  '.mp3',
  '.m4a',
  '.aac',
  '.wav',
  '.ogg',
  '.oga',
  '.opus',
  '.flac',
  '.wma',
  '.amr',
  '.mka',
};

const Set<String> kVideoExtensions = {
  '.mp4',
  '.mov',
  '.mkv',
  '.webm',
  '.avi',
  '.3gp',
  '.m4v',
  '.flv',
  '.wmv',
  '.ts',
};

/// Returns the lowercase extension (including the dot) of a path or file name,
/// or an empty string if none.
String fileExtension(String pathOrName) {
  final lower = pathOrName.toLowerCase();
  final slash = lower.lastIndexOf(RegExp(r'[\\/]'));
  final dot = lower.lastIndexOf('.');
  if (dot < 0 || dot < slash) return '';
  return lower.substring(dot);
}

/// True when the path/name looks like an audio file.
bool isAudioFile(String pathOrName) =>
    kAudioExtensions.contains(fileExtension(pathOrName));
