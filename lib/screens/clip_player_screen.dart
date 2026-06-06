import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/clip.dart';
import '../services/playback_store.dart';
import '../utils/app_theme.dart';
import '../utils/time_format.dart';
import '../widgets/speed_control.dart';
import '../widgets/video_gesture_layer.dart';

class ClipPlayerScreen extends StatefulWidget {
  final Clip clip;
  const ClipPlayerScreen({super.key, required this.clip});

  @override
  State<ClipPlayerScreen> createState() => _ClipPlayerScreenState();
}

class _ClipPlayerScreenState extends State<ClipPlayerScreen>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _ready = false;
  String? _error;

  String get _posKey => 'clip_${widget.clip.id}';

  // Live playback speed (review aid only).
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    try {
      final file = File(widget.clip.filePath);
      if (!await file.exists()) {
        setState(
          () => _error = 'ملف المقطع غير موجود. ربما تم حذفه.',
        );
        return;
      }
      final c = VideoPlayerController.file(
        file,
        // Keep audio playing when the app is backgrounded / switched away.
        videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
      );
      await c.initialize();
      c.setLooping(true);
      c.addListener(() {
        if (mounted) setState(() {});
      });

      // Resume from where the user left off, if sensible.
      final dur = c.value.duration.inMilliseconds;
      final saved = PlaybackStore.getPosition(_posKey);
      if (saved != null && saved > 2000 && saved < dur - 2000) {
        await c.seekTo(Duration(milliseconds: saved));
      }

      await c.play();
      if (!mounted) return;
      setState(() {
        _controller = c;
        _ready = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذّر تشغيل هذا المقطع.\n$e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive) {
      _savePosition();
    }
  }

  void _savePosition() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    PlaybackStore.setPosition(_posKey, c.value.position.inMilliseconds);
  }

  @override
  void dispose() {
    _savePosition();
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    setState(() {
      c.value.isPlaying ? c.pause() : c.play();
    });
  }

  void _setSpeed(double s) {
    setState(() => _speed = s);
    _controller?.setPlaybackSpeed(s);
  }

  /// Double-tap seek (±N seconds), clamped within the looping clip's duration.
  void _seekRelative(int deltaMs) {
    final c = _controller;
    if (c == null) return;
    final durMs = c.value.duration.inMilliseconds;
    final target = (c.value.position.inMilliseconds + deltaMs).clamp(0, durMs);
    c.seekTo(Duration(milliseconds: target));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.clip.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                ),
              )
            : !_ready
            ? const Center(child: CircularProgressIndicator())
            : _buildPlayer(),
      ),
    );
  }

  Widget _buildPlayer() {
    final c = _controller!;
    final posMs = c.value.position.inMilliseconds;
    final durMs = c.value.duration.inMilliseconds;
    return Column(
      children: [
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio == 0
                  ? 16 / 9
                  : c.value.aspectRatio,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (widget.clip.isAudio)
                    const _AudioCover()
                  else
                    VideoPlayer(c),
                  // Single tap = play/pause, double tap = ±5s.
                  Positioned.fill(
                    child: VideoGestureLayer(
                      onTap: _togglePlay,
                      onSeek: _seekRelative,
                    ),
                  ),
                  // Visual-only play icon; must not swallow taps.
                  IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: c.value.isPlaying ? 0 : 1,
                      duration: const Duration(milliseconds: 200),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(50),
                        ),
                        padding: const EdgeInsets.all(14),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 44,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              IconButton(
                onPressed: _togglePlay,
                icon: Icon(
                  c.value.isPlaying
                      ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_fill_rounded,
                  color: AppColors.accent,
                  size: 40,
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    activeTrackColor: AppColors.accent,
                    inactiveTrackColor: AppColors.surfaceLight,
                    thumbColor: AppColors.accent,
                  ),
                  child: Slider(
                    value: posMs.clamp(0, durMs).toDouble(),
                    max: durMs.toDouble().clamp(1, double.infinity),
                    onChanged: (v) =>
                        c.seekTo(Duration(milliseconds: v.toInt())),
                  ),
                ),
              ),
              Text(
                formatMs(posMs),
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 8),
              SpeedControl(speed: _speed, onChanged: _setSpeed),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(
                  widget.clip.isAudio
                      ? Icons.audiotrack_outlined
                      : Icons.movie_outlined,
                  size: 18,
                  color: AppColors.accent,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'المصدر الأصلي',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                      Text(
                        widget.clip.sourceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${formatMs(widget.clip.startMs)} → ${formatMs(widget.clip.endMs)}',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Cover shown in place of the video surface when playing an audio clip.
class _AudioCover extends StatelessWidget {
  const _AudioCover();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1A1C22), Color(0xFF0E0F13)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Center(
        child: Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              colors: [AppColors.accent2, AppColors.accent],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.accent.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Icon(
            Icons.music_note_rounded,
            color: Colors.black,
            size: 50,
          ),
        ),
      ),
    );
  }
}
