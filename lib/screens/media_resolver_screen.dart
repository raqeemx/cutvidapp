import 'package:flutter/material.dart';

import '../services/incoming_media.dart';
import '../utils/app_theme.dart';
import '../utils/media_type.dart';
import 'player_screen.dart';

/// Shown when a video is opened from outside the app. It copies the incoming
/// URI to a usable file (showing a loading indicator for large files), then
/// replaces itself with the [PlayerScreen] so the user lands straight on the
/// cut screen — skipping the welcome screen.
class MediaResolverScreen extends StatefulWidget {
  final String uri;
  const MediaResolverScreen({super.key, required this.uri});

  @override
  State<MediaResolverScreen> createState() => _MediaResolverScreenState();
}

class _MediaResolverScreenState extends State<MediaResolverScreen> {
  String? _error;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    try {
      final video = await IncomingMedia.resolve(widget.uri);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            videoPath: video.path,
            videoName: video.name,
            isAudio: isAudioFile(video.name),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذّر فتح الفيديو المُحدَّد.\n$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('فتح فيديو')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _error != null ? _buildError() : _buildLoading(),
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: const [
        CircularProgressIndicator(color: AppColors.accent),
        SizedBox(height: 20),
        Text(
          'جارٍ تحضير الفيديو…',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(height: 8),
        Text(
          'قد يستغرق الأمر لحظات للملفات الكبيرة.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline_rounded,
            color: AppColors.danger, size: 48),
        const SizedBox(height: 16),
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('رجوع'),
        ),
      ],
    );
  }
}
