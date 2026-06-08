import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../services/export_queue_service.dart';
import '../services/playback_store.dart';
import '../utils/app_theme.dart';
import '../utils/time_format.dart';
import '../widgets/export_status_bar.dart';
import '../widgets/range_timeline.dart';
import '../widgets/speed_control.dart';
import '../widgets/video_gesture_layer.dart';

enum _ScreenMenu { resetSelection, showHint }

class PlayerScreen extends StatefulWidget {
  final String videoPath;
  final String videoName;

  /// Whether the source is an audio file (shows an audio cover instead of a
  /// video surface, and saves an audio-only clip).
  final bool isAudio;

  const PlayerScreen({
    super.key,
    required this.videoPath,
    required this.videoName,
    this.isAudio = false,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _ready = false;
  String? _error;

  // The selection always has a valid range once the video is ready, so the
  // draggable handles are the single way to define the clip — no separate
  // "set start / set end" buttons are needed.
  int _startMs = 0;
  int _endMs = 0;

  // Preview mode: when active, playback auto-stops at _endMs.
  bool _previewMode = false;

  // Momentary highlight on a card after capturing its point.
  bool _startFlash = false;
  bool _endFlash = false;

  // First-run guidance.
  Box? _settings;
  bool _showHint = false;

  // Stable key for remembering this video's playback position.
  String? _posKey;

  // Live playback speed (review aid only; never affects the saved clip).
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
    _loadHint();
  }

  Future<void> _init() async {
    try {
      final c = VideoPlayerController.file(
        File(widget.videoPath),
        // Keep audio playing when the app is backgrounded / switched away.
        videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
      );
      await c.initialize();
      c.addListener(_onTick);

      // Resume from where the user left off, if sensible. The key is based on
      // stable file identity (name + size + duration), not the path, so videos
      // opened from outside the app (whose temp path changes each time) still
      // resume correctly.
      final dur = c.value.duration.inMilliseconds;
      _posKey = await _buildPosKey(dur);
      final saved = PlaybackStore.getPosition(_posKey!);
      if (saved != null && saved > 2000 && saved < dur - 2000) {
        await c.seekTo(Duration(milliseconds: saved));
      }

      if (!mounted) return;
      setState(() {
        _controller = c;
        // Start with the whole video selected; the user trims by dragging.
        _startMs = 0;
        _endMs = dur;
        _ready = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذّر فتح هذا الفيديو.\n$e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Persist the position when leaving the app (audio keeps playing).
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive) {
      _savePosition();
    }
  }

  /// A stable identity for the video that survives temp-path changes (external
  /// opens copy the file to a new cache path each time).
  Future<String> _buildPosKey(int durationMs) async {
    try {
      final size = await File(widget.videoPath).length();
      return '${widget.videoName}|$size|$durationMs';
    } catch (_) {
      return widget.videoPath;
    }
  }

  void _savePosition() {
    final c = _controller;
    final key = _posKey;
    if (c == null || key == null || !c.value.isInitialized) return;
    PlaybackStore.setPosition(key, c.value.position.inMilliseconds);
  }

  Future<void> _loadHint() async {
    final box = await Hive.openBox('settings');
    if (!mounted) return;
    setState(() {
      _settings = box;
      _showHint = !(box.get('player_hint_seen', defaultValue: false) as bool);
    });
  }

  void _dismissHint() {
    _settings?.put('player_hint_seen', true);
    setState(() => _showHint = false);
  }

  /// Only handles the preview auto-stop. Frequent UI updates are driven by
  /// ValueListenableBuilder on the controller, not setState, to avoid
  /// rebuilding the whole screen on every tick.
  void _onTick() {
    final c = _controller;
    if (c == null) return;
    if (_previewMode) {
      final pos = c.value.position.inMilliseconds;
      if (pos >= _endMs) {
        c.pause();
        c.seekTo(Duration(milliseconds: _startMs));
        if (mounted) setState(() => _previewMode = false);
      }
    }
  }

  @override
  void dispose() {
    _savePosition();
    WidgetsBinding.instance.removeObserver(this);
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  int get _durationMs => _controller?.value.duration.inMilliseconds ?? 0;

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    setState(() {
      _previewMode = false;
      if (c.value.isPlaying) {
        c.pause();
      } else {
        c.play();
      }
    });
  }

  void _setSpeed(double s) {
    setState(() => _speed = s);
    _controller?.setPlaybackSpeed(s);
  }

  // ---- Live drag handlers from the timeline ----

  void _onStartDragged(int ms) {
    setState(() {
      _previewMode = false;
      _startMs = ms.clamp(0, _endMs - 300);
    });
    _controller?.seekTo(Duration(milliseconds: _startMs));
  }

  void _onEndDragged(int ms) {
    setState(() {
      _previewMode = false;
      _endMs = ms.clamp(_startMs + 300, _durationMs);
    });
    _controller?.seekTo(Duration(milliseconds: _endMs));
  }

  void _onSeek(int ms) {
    setState(() => _previewMode = false);
    _controller?.seekTo(Duration(milliseconds: ms.clamp(0, _durationMs)));
  }

  /// Relative double-tap seek (±N seconds), clamped to the video bounds.
  void _seekRelative(int deltaMs) {
    _onSeek(_positionMs + deltaMs);
  }

  // ---- Capture start/end while the video keeps playing (no pause) ----

  int get _positionMs => _controller?.value.position.inMilliseconds ?? 0;

  void _flashCard({required bool isStart}) {
    setState(() {
      if (isStart) {
        _startFlash = true;
      } else {
        _endFlash = true;
      }
    });
    Future.delayed(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      setState(() {
        if (isStart) {
          _startFlash = false;
        } else {
          _endFlash = false;
        }
      });
    });
  }

  /// Captures the current playback position as the start point, live.
  void _captureStart() {
    final pos = _positionMs.clamp(0, _durationMs);
    HapticFeedback.mediumImpact();
    setState(() {
      _startMs = pos;
      // Keep the end valid: if it's now at or before start, push it to the end.
      if (_endMs <= _startMs) _endMs = _durationMs;
    });
    _flashCard(isStart: true);
    _snack('تم التقاط البداية عند ${formatMs(pos)}');
  }

  /// Captures the current playback position as the end point, live.
  void _captureEnd() {
    final pos = _positionMs.clamp(0, _durationMs);
    if (pos <= _startMs) {
      _snack('نقطة النهاية يجب أن تكون بعد البداية.');
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() => _endMs = pos);
    _flashCard(isStart: false);
    _snack('تم التقاط النهاية عند ${formatMs(pos)}');
  }

  Future<void> _previewClip() async {
    final c = _controller;
    if (c == null) return;
    await c.seekTo(Duration(milliseconds: _startMs));
    await c.play();
    setState(() => _previewMode = true);
  }

  String? _validateRange() {
    if (_endMs <= _startMs) {
      return 'نقطة النهاية يجب أن تكون بعد البداية.';
    }
    if ((_endMs - _startMs) < 300) {
      return 'المقطع قصير جداً، اختر مدى أطول.';
    }
    return null;
  }

  /// Adds the current selection to the background export queue without
  /// blocking the screen — the user can immediately mark another clip.
  Future<void> _addToQueue() async {
    final err = _validateRange();
    if (err != null) {
      _snack(err);
      return;
    }

    final name = await _askClipName();
    if (name == null || name.trim().isEmpty) return;
    if (!mounted) return;

    final queue = context.read<ExportQueueService>();
    queue.add(
      ExportJob(
        id: const Uuid().v4(),
        name: name.trim(),
        sourcePath: widget.videoPath,
        sourceName: widget.videoName,
        startMs: _startMs,
        endMs: _endMs,
        isAudio: widget.isAudio,
      ),
    );

    HapticFeedback.mediumImpact();
    _snack('تمت إضافة المقطع إلى طابور القص');
  }

  Future<String?> _askClipName() async {
    final controller = TextEditingController(
      text: 'مقطع ${formatMs(_startMs)}-${formatMs(_endMs)}',
    );
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('سمِّ المقطع'),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: const InputDecoration(
            hintText: 'أدخل اسماً',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  Future<void> _editTimeManually({required bool isStart}) async {
    final current = isStart ? _startMs : _endMs;
    // Valid window keeps end after start by at least 300ms and within duration.
    final minMs = isStart ? 0 : (_startMs + 300);
    final maxMs = isStart ? (_endMs - 300) : _durationMs;
    if (maxMs < minMs) {
      _snack('لا يوجد مجال كافٍ للتعديل اليدوي.');
      return;
    }
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => _TimeEditorDialog(
        initialMs: current.clamp(minMs, maxMs),
        minMs: minMs,
        maxMs: maxMs,
        durationMs: _durationMs,
        title: isStart ? 'تعديل وقت البداية' : 'تعديل وقت النهاية',
      ),
    );
    if (result == null) return;
    setState(() {
      _previewMode = false;
      if (isStart) {
        _startMs = result;
      } else {
        _endMs = result;
      }
    });
    // Move the playhead to the edited point for immediate visual feedback.
    _controller?.seekTo(
      Duration(milliseconds: isStart ? _startMs : _endMs),
    );
  }

  void _resetSelection() {
    setState(() {
      _previewMode = false;
      _startMs = 0;
      _endMs = _durationMs;
    });
    _snack('تمت إعادة تحديد الفيديو كاملاً.');
  }

  void _showHintAgain() {
    _settings?.put('player_hint_seen', false);
    setState(() => _showHint = true);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.videoName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          PopupMenuButton<_ScreenMenu>(
            tooltip: 'المزيد',
            color: AppColors.surface,
            icon: const Icon(Icons.more_horiz_rounded),
            onSelected: (a) {
              switch (a) {
                case _ScreenMenu.resetSelection:
                  _resetSelection();
                case _ScreenMenu.showHint:
                  _showHintAgain();
              }
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                value: _ScreenMenu.resetSelection,
                child: _MenuRow(
                  icon: Icons.restart_alt_rounded,
                  label: 'إعادة التحديد للكامل',
                ),
              ),
              PopupMenuItem(
                value: _ScreenMenu.showHint,
                child: _MenuRow(
                  icon: Icons.help_outline_rounded,
                  label: 'إظهار التلميح',
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _error != null
            ? _ErrorView(message: _error!)
            : !_ready
            ? const Center(child: CircularProgressIndicator())
            : _buildPlayer(),
      ),
    );
  }

  Widget _buildPlayer() {
    return Column(
      children: [
        // ===== Section 1: video preview =====
        _buildPreview(),

        // ===== Sections 2–4: scrollable editing area =====
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildScrubBar(),
                const SizedBox(height: 6),
                _buildTimeline(),
                const SizedBox(height: 12),
                _buildStartEndCards(),
                const SizedBox(height: 14),
                _buildSummaryBar(),
                if (_showHint) ...[
                  const SizedBox(height: 14),
                  _HintBanner(onDismiss: _dismissHint),
                ],
              ],
            ),
          ),
        ),

        // Live background-cut status (hidden when the queue is idle).
        const ExportStatusBar(),

        // ===== Section 5: fixed bottom action bar =====
        _buildBottomBar(),
      ],
    );
  }

  // ----- Section 1 -----
  Widget _buildPreview() {
    final c = _controller!;
    if (widget.isAudio) return _buildAudioPreview();
    final ar = c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio;
    // Bound the preview height so tall/portrait videos never push the cut
    // controls off-screen; the video is shown "contain" with letterboxing.
    final maxH = MediaQuery.of(context).size.height * 0.42;
    return LayoutBuilder(
      builder: (context, constraints) {
        final naturalH = constraints.maxWidth / ar;
        final boxH = naturalH > maxH ? maxH : naturalH;
        return Container(
          color: Colors.black,
          width: double.infinity,
          height: boxH,
          alignment: Alignment.center,
          child: AspectRatio(
            aspectRatio: ar,
            child: Stack(
              alignment: Alignment.center,
              children: [
                VideoPlayer(c),
            // Gesture layer: single tap = play/pause, double tap = ±5s.
            // Sits above the video and below the (interactive) fullscreen btn.
            Positioned.fill(
              child: VideoGestureLayer(
                onTap: _togglePlay,
                onSeek: _seekRelative,
              ),
            ),
            if (_previewMode)
              Positioned(
                top: 10,
                right: 10,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'معاينة',
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ),
            // Center play/pause overlay — visual only; must not eat taps so the
            // gesture layer below receives them (hence IgnorePointer).
            IgnorePointer(
              child: ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: c,
                builder: (context, value, _) => AnimatedOpacity(
                  opacity: value.isPlaying ? 0 : 1,
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
            ),
            // Fullscreen review button (48dp touch target).
            Positioned(
              bottom: 4,
              left: 4,
              child: IconButton(
                tooltip: 'ملء الشاشة',
                onPressed: _openFullscreen,
                icon: const Icon(
                  Icons.fullscreen_rounded,
                  color: Colors.white,
                  size: 26,
                ),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black45,
                ),
              ),
            ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Audio cover panel: no video surface, but the same tap/double-tap gestures
  /// and play overlay so cutting audio feels identical to cutting video.
  Widget _buildAudioPreview() {
    final c = _controller!;
    final h = (MediaQuery.of(context).size.height * 0.26).clamp(170.0, 260.0);
    return Container(
      width: double.infinity,
      height: h,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1A1C22), Color(0xFF0E0F13)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 92,
                height: 92,
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
                  size: 48,
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  widget.videoName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          // Gestures (tap = play/pause, double tap = ±5s).
          Positioned.fill(
            child: VideoGestureLayer(
              onTap: _togglePlay,
              onSeek: _seekRelative,
            ),
          ),
          if (_previewMode)
            Positioned(
              top: 10,
              right: 10,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'معاينة',
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ),
          // Play/pause overlay (visual only).
          IgnorePointer(
            child: ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: c,
              builder: (context, value, _) => AnimatedOpacity(
                opacity: value.isPlaying ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(50),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openFullscreen() async {
    final c = _controller;
    if (c == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FullscreenPlayer(controller: c),
        fullscreenDialog: true,
      ),
    );
  }

  // ----- Playback scrub bar (play/pause + position) -----
  Widget _buildScrubBar() {
    final c = _controller!;
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: c,
      builder: (context, value, _) {
        final posMs = value.position.inMilliseconds;
        final durMs = value.duration.inMilliseconds;
        return Row(
          children: [
            IconButton(
              onPressed: _togglePlay,
              icon: Icon(
                value.isPlaying
                    ? Icons.pause_circle_filled_rounded
                    : Icons.play_circle_fill_rounded,
                color: AppColors.accent,
                size: 38,
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  activeTrackColor: AppColors.accent,
                  inactiveTrackColor: AppColors.surfaceLight,
                  thumbColor: AppColors.accent,
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                ),
                child: Slider(
                  value: posMs.clamp(0, durMs).toDouble(),
                  max: durMs.toDouble().clamp(1, double.infinity),
                  onChanged: (v) => _onSeek(v.toInt()),
                ),
              ),
            ),
            Text(
              '${formatMs(posMs)} / ${formatMs(durMs)}',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11.5,
              ),
            ),
            const SizedBox(width: 8),
            SpeedControl(speed: _speed, onChanged: _setSpeed),
          ],
        );
      },
    );
  }

  // ----- Section 2: interactive timeline -----
  Widget _buildTimeline() {
    final c = _controller!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 4, right: 2),
          child: Text(
            'اسحب المقبضين لتحديد المقطع',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
        ),
        ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: c,
          builder: (context, value, _) => RangeTimeline(
            durationMs: value.duration.inMilliseconds,
            positionMs: value.position.inMilliseconds,
            startMs: _startMs,
            endMs: _endMs,
            onStartChanged: _onStartDragged,
            onEndChanged: _onEndDragged,
            onSeek: _onSeek,
          ),
        ),
      ],
    );
  }

  // ----- Section 3: start / end cards -----
  Widget _buildStartEndCards() {
    return Row(
      children: [
        Expanded(
          child: _TimeCard(
            label: 'البداية',
            value: formatMs(_startMs),
            color: AppColors.accent2,
            highlight: _startFlash,
            onEdit: () => _editTimeManually(isStart: true),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _TimeCard(
            label: 'النهاية',
            value: formatMs(_endMs),
            color: AppColors.accent,
            highlight: _endFlash,
            onEdit: () => _editTimeManually(isStart: false),
          ),
        ),
      ],
    );
  }

  // ----- Section 4: summary bar -----
  Widget _buildSummaryBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.accent2.withValues(alpha: 0.18),
            AppColors.accent.withValues(alpha: 0.18),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.surfaceLight),
      ),
      child: Row(
        children: [
          const Icon(Icons.content_cut_rounded, color: AppColors.accent),
          const SizedBox(width: 10),
          const Text(
            'مدة المقطع الناتج',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Text(
            formatMs(_endMs - _startMs),
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  // ----- Section 5: fixed bottom action bar -----
  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.surfaceLight)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Capture start/end live while watching — no pause.
          Row(
            children: [
              Expanded(
                child: _CaptureButton(
                  icon: Icons.flag_circle_rounded,
                  label: 'التقاط البداية',
                  color: AppColors.accent2,
                  onTap: _captureStart,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _CaptureButton(
                  icon: Icons.stop_circle_rounded,
                  label: 'التقاط النهاية',
                  color: AppColors.accent,
                  onTap: _captureEnd,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              // Secondary: preview
              Expanded(
                flex: 2,
                child: OutlinedButton.icon(
                  onPressed: _previewClip,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textPrimary,
                    side: const BorderSide(color: AppColors.surfaceLight),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.visibility_rounded, size: 20),
                  label: const Text('معاينة'),
                ),
              ),
              const SizedBox(width: 12),
              // Primary: add to background queue (non-blocking).
              Expanded(
                flex: 3,
                child: ElevatedButton.icon(
                  onPressed: _addToQueue,
                  icon: const Icon(Icons.playlist_add_rounded),
                  label: const Text('إضافة إلى طابور القص'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---- small widgets ----

/// Full-screen video for detailed review. Reuses the existing controller and
/// allows landscape rotation; restores portrait on exit.
class _FullscreenPlayer extends StatefulWidget {
  final VideoPlayerController controller;
  const _FullscreenPlayer({required this.controller});

  @override
  State<_FullscreenPlayer> createState() => _FullscreenPlayerState();
}

class _FullscreenPlayerState extends State<_FullscreenPlayer> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
              child: GestureDetector(
                onTap: () {
                  c.value.isPlaying ? c.pause() : c.play();
                },
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    VideoPlayer(c),
                    ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: c,
                      builder: (context, value, _) => AnimatedOpacity(
                        opacity: value.isPlaying ? 0 : 1,
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
                            size: 48,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(
              child: IconButton(
                tooltip: 'إغلاق',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(
                  Icons.fullscreen_exit_rounded,
                  color: Colors.white,
                  size: 28,
                ),
                style: IconButton.styleFrom(backgroundColor: Colors.black45),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HintBanner extends StatelessWidget {
  final VoidCallback onDismiss;
  const _HintBanner({required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.accent2.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.accent2.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lightbulb_rounded,
              color: AppColors.accent2, size: 20),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'الفيديو كامل محدّد الآن. اسحب المقبض التركوازي للبداية والبرتقالي '
              'للنهاية لاقتطاع الجزء المطلوب، ثم اضغط «حفظ المقطع».',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: onDismiss,
            icon: const Icon(Icons.close_rounded,
                color: AppColors.textSecondary, size: 18),
          ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppColors.textPrimary, size: 20),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(color: AppColors.textPrimary)),
      ],
    );
  }
}

/// Compact filled button used for the live "capture start / end" actions.
class _CaptureButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  const _CaptureButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: enabled ? color : AppColors.disabled,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                color: enabled ? Colors.black : AppColors.textSecondary,
                size: 22,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: enabled ? Colors.black : AppColors.textSecondary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimeCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final VoidCallback? onEdit;
  final bool highlight;
  const _TimeCard({
    required this.label,
    required this.value,
    required this.color,
    this.onEdit,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: highlight ? color.withValues(alpha: 0.18) : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: color.withValues(alpha: highlight ? 1 : 0.4),
          width: highlight ? 2 : 1.2,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          if (onEdit != null)
            IconButton(
              tooltip: 'تعديل دقيق',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: onEdit,
              icon: const Icon(
                Icons.tune_rounded,
                size: 20,
                color: AppColors.textSecondary,
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: AppColors.danger,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeEditorDialog extends StatefulWidget {
  final int initialMs;
  final int minMs;
  final int maxMs;
  final int durationMs;
  final String title;
  const _TimeEditorDialog({
    required this.initialMs,
    required this.minMs,
    required this.maxMs,
    required this.durationMs,
    required this.title,
  });

  @override
  State<_TimeEditorDialog> createState() => _TimeEditorDialogState();
}

class _TimeEditorDialogState extends State<_TimeEditorDialog> {
  late int _ms;
  bool _syncing = false;

  late final bool _showHours = widget.durationMs >= 3600000;
  final _hCtrl = TextEditingController();
  final _mCtrl = TextEditingController();
  final _sCtrl = TextEditingController();
  final _csCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ms = widget.initialMs;
    _syncFields();
  }

  @override
  void dispose() {
    _hCtrl.dispose();
    _mCtrl.dispose();
    _sCtrl.dispose();
    _csCtrl.dispose();
    super.dispose();
  }

  /// Updates the text fields from [_ms] (without re-parsing them).
  void _syncFields() {
    _syncing = true;
    final totalSec = _ms ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    final cs = (_ms % 1000) ~/ 10;
    two(int n) => n.toString().padLeft(2, '0');
    _hCtrl.text = two(h);
    _mCtrl.text = two(m);
    _sCtrl.text = two(s);
    _csCtrl.text = two(cs);
    _syncing = false;
  }

  /// Recomputes [_ms] from the typed fields (no clamping — validated below).
  void _parseFields() {
    if (_syncing) return;
    final h = _showHours ? (int.tryParse(_hCtrl.text) ?? 0) : 0;
    final m = int.tryParse(_mCtrl.text) ?? 0;
    final s = int.tryParse(_sCtrl.text) ?? 0;
    final cs = int.tryParse(_csCtrl.text) ?? 0;
    setState(() {
      _ms = ((h * 3600 + m * 60 + s) * 1000) + (cs * 10);
    });
  }

  void _setMs(int value) {
    setState(() => _ms = value.clamp(widget.minMs, widget.maxMs));
    _syncFields();
  }

  void _adjust(int deltaMs) => _setMs(_ms + deltaMs);

  bool get _valid => _ms >= widget.minMs && _ms <= widget.maxMs;

  String? get _errorText {
    if (_valid) return null;
    return 'أدخل وقتاً بين ${formatMsPrecise(widget.minMs)} '
        'و ${formatMsPrecise(widget.maxMs)}';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatMsPrecise(_ms),
              style: TextStyle(
                color: _valid ? AppColors.accent : AppColors.danger,
                fontSize: 30,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 14),
            // Manual entry fields.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (_showHours) ...[
                  _field(_hCtrl, 'س'),
                  _sep(':'),
                ],
                _field(_mCtrl, 'د'),
                _sep(':'),
                _field(_sCtrl, 'ث'),
                _sep('.'),
                _field(_csCtrl, 'جزء'),
              ],
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 10),
              Text(
                _errorText!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.danger, fontSize: 12),
              ),
            ],
            const SizedBox(height: 14),
            _adjustRow('ثانية', -1000, 1000, '1s'),
            const SizedBox(height: 8),
            _adjustRow('دقيق', -100, 100, '0.1s'),
            const SizedBox(height: 8),
            Slider(
              value: _ms.toDouble().clamp(
                    widget.minMs.toDouble(),
                    widget.maxMs.toDouble(),
                  ),
              min: widget.minMs.toDouble(),
              max: widget.maxMs.toDouble() <= widget.minMs.toDouble()
                  ? widget.minMs.toDouble() + 1
                  : widget.maxMs.toDouble(),
              onChanged: (v) => _setMs(v.toInt()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        ElevatedButton(
          onPressed: _valid ? () => Navigator.pop(context, _ms) : null,
          child: const Text('تطبيق'),
        ),
      ],
    );
  }

  Widget _field(TextEditingController ctrl, String label) {
    return Column(
      children: [
        SizedBox(
          width: 52,
          child: TextField(
            controller: ctrl,
            onChanged: (_) => _parseFields(),
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(2),
            ],
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 11)),
      ],
    );
  }

  Widget _sep(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 20),
        child: Text(s,
            style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 20,
                fontWeight: FontWeight.w800)),
      );

  Widget _adjustRow(String label, int minus, int plus, String step) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _stepBtn(Icons.remove, () => _adjust(minus)),
        Text(
          '$label  ($step)',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        _stepBtn(Icons.add, () => _adjust(plus)),
      ],
    );
  }

  Widget _stepBtn(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppColors.surfaceLight,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: AppColors.textPrimary, size: 20),
      ),
    );
  }
}
