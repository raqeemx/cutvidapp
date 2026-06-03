/// Formats a [Duration] (or milliseconds) into mm:ss, e.g. 01:15.
/// Falls back to hh:mm:ss when the duration is one hour or longer.
String formatDuration(Duration d) {
  final totalSeconds = d.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;

  String two(int n) => n.toString().padLeft(2, '0');

  if (hours > 0) {
    return '${two(hours)}:${two(minutes)}:${two(seconds)}';
  }
  return '${two(minutes)}:${two(seconds)}';
}

String formatMs(int ms) => formatDuration(Duration(milliseconds: ms));

/// Formats milliseconds with hundredths for fine editing, e.g. 01:15.42
String formatMsPrecise(int ms) {
  final d = Duration(milliseconds: ms);
  final base = formatDuration(d);
  final hundredths = ((ms % 1000) ~/ 10).toString().padLeft(2, '0');
  return '$base.$hundredths';
}
