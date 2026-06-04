import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/clip.dart';
import '../services/clip_repository.dart';
import '../services/video_cutter.dart';
import '../utils/app_theme.dart';
import '../utils/time_format.dart';
import '../widgets/range_timeline.dart';

enum _ScreenMenu { resetSelection, showHint }

class PlayerScreen extends StatefulWidget {
  final String videoPath;
  final String videoName;
  const PlayerScreen({
    super.key,
    required this.videoPath,
    required this.videoName,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
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

  bool _saving = false;

  // Live progress (0..1) of the FFmpeg cut, used by the progress dialog.
  final ValueNotifier<double> _cutProgress = ValueNotifier<double>(0);

  // First-run guidance.
  Box? _settings;
  bool _showHint = false;

  @override
  void initState() {
    super.initState();
    _init();
    _loadHint();
  }

  Future<void> _init() async {
    try {
      final c = VideoPlayerController.file(File(widget.videoPath));
      await c.initialize();
      c.addListener(_onTick);
      if (!mounted) return;
      setState(() {
        _controller = c;
        // Start with the whole video selected; the user trims by dragging.
        _startMs = 0;
        _endMs = c.value.duration.inMilliseconds;
        _ready = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذّر فتح هذا الفيديو.\n$e');
    }
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
    WakelockPlus.disable();
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    _cutProgress.dispose();
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
    _controller?.seekTo(Duration(milliseconds: ms));
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

  Future<void> _saveClip() async {
    final err = _validateRange();
    if (err != null) {
      _snack(err);
      return;
    }
    _controller?.pause();

    final repo = context.read<ClipRepository>();
    final name = await _askClipName();
    if (name == null || name.trim().isEmpty) return;
    if (!mounted) return;

    // Progress is shown inline in the bottom action bar (see _buildBottomBar).
    setState(() => _saving = true);
    _cutProgress.value = 0;

    final id = const Uuid().v4();

    // Keep the screen awake during the (possibly long) encode.
    await WakelockPlus.enable();
    String? outPath;
    try {
      outPath = await VideoCutter.cut(
        sourcePath: widget.videoPath,
        startMs: _startMs,
        endMs: _endMs,
        clipId: id,
        onProgress: (p) => _cutProgress.value = p,
      );
    } finally {
      await WakelockPlus.disable();
    }

    if (!mounted) return;

    if (outPath == null) {
      setState(() => _saving = false);
      _snack('تعذّر قص المقطع. جرّب مدى مختلفاً.');
      return;
    }

    final thumb = await VideoCutter.generateThumbnail(
      videoPath: outPath,
      positionMs: 0,
    );

    final clip = Clip(
      id: id,
      name: name.trim(),
      filePath: outPath,
      sourcePath: widget.videoPath,
      sourceName: widget.videoName,
      startMs: _startMs,
      endMs: _endMs,
      thumbnailPath: thumb,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );

    await repo.addClip(clip);

    if (!mounted) return;
    setState(() => _saving = false);

    // Tactile confirmation that the save finished.
    HapticFeedback.mediumImpact();
    _showSavedDialog(name.trim());
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

  void _showSavedDialog(String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: const [
            Icon(Icons.check_circle_rounded, color: AppColors.accent2),
            SizedBox(width: 10),
            Text('تم حفظ المقطع'),
          ],
        ),
        content: Text(
          'تم حفظ "$name" في مكتبتك.\nيمكنك متابعة قص مقاطع أخرى من هذا الفيديو.',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              // Reselect the whole video for the next cut.
              setState(() {
                _startMs = 0;
                _endMs = _durationMs;
              });
            },
            child: const Text('قص مقطع آخر'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('حسناً'),
          ),
        ],
      ),
    );
  }

  Future<void> _editTimeManually({required bool isStart}) async {
    final current = isStart ? _startMs : _endMs;
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => _TimeEditorDialog(
        initialMs: current,
        maxMs: _durationMs,
        title: isStart ? 'تعديل وقت البداية' : 'تعديل وقت النهاية',
      ),
    );
    if (result == null) return;
    setState(() {
      if (isStart) {
        _startMs = result.clamp(0, _endMs - 300 < 0 ? 0 : _endMs - 300);
      } else {
        if (result <= _startMs) {
          _snack('نقطة النهاية يجب أن تكون بعد البداية.');
          return;
        }
        _endMs = result.clamp(_startMs + 300, _durationMs);
      }
    });
  }

  void _resetSelection() {
    if (_saving) return;
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

        // ===== Section 5: fixed bottom action bar =====
        _buildBottomBar(),
      ],
    );
  }

  // ----- Section 1 -----
  Widget _buildPreview() {
    final c = _controller!;
    return Container(
      color: Colors.black,
      width: double.infinity,
      child: AspectRatio(
        aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(c),
            if (_previewMode)
              Positioned(
                top: 10,
                right: 10,
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
            // Center play/pause overlay — rebuilds only on play-state changes.
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: c,
              builder: (context, value, _) => GestureDetector(
                onTap: _togglePlay,
                child: AnimatedOpacity(
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
            const SizedBox(width: 4),
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
            onEdit: () => _editTimeManually(isStart: true),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _TimeCard(
            label: 'النهاية',
            value: formatMs(_endMs),
            color: AppColors.accent,
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
          Row(
            children: [
              // Secondary: preview
              Expanded(
                flex: 2,
                child: OutlinedButton.icon(
                  onPressed: _saving ? null : _previewClip,
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
              // Primary: save (wide)
              Expanded(
                flex: 3,
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _saveClip,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                      : const Icon(Icons.save_alt_rounded),
                  label: Text(_saving ? 'جارٍ القص…' : 'حفظ المقطع'),
                ),
              ),
            ],
          ),
          // Inline real progress while cutting.
          if (_saving)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: ValueListenableBuilder<double>(
                valueListenable: _cutProgress,
                builder: (context, value, _) {
                  final pct = (value * 100).clamp(0, 100).toStringAsFixed(0);
                  return Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: value <= 0 ? null : value,
                            minHeight: 8,
                            backgroundColor: AppColors.surfaceLight,
                            color: AppColors.accent,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '%$pct',
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  );
                },
              ),
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

class _TimeCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final VoidCallback? onEdit;
  const _TimeCard({
    required this.label,
    required this.value,
    required this.color,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1.2),
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
  final int maxMs;
  final String title;
  const _TimeEditorDialog({
    required this.initialMs,
    required this.maxMs,
    required this.title,
  });

  @override
  State<_TimeEditorDialog> createState() => _TimeEditorDialogState();
}

class _TimeEditorDialogState extends State<_TimeEditorDialog> {
  late int _ms;

  @override
  void initState() {
    super.initState();
    _ms = widget.initialMs;
  }

  void _adjust(int deltaMs) {
    setState(() {
      _ms = (_ms + deltaMs).clamp(0, widget.maxMs);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatMsPrecise(_ms),
            style: const TextStyle(
              color: AppColors.accent,
              fontSize: 32,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 16),
          _adjustRow('ثوانٍ', -1000, 1000, '1s'),
          const SizedBox(height: 8),
          _adjustRow('دقيق', -100, 100, '0.1s'),
          const SizedBox(height: 12),
          Slider(
            value: _ms.toDouble().clamp(0, widget.maxMs.toDouble()),
            max: widget.maxMs.toDouble().clamp(1, double.infinity),
            onChanged: (v) => setState(() => _ms = v.toInt()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, _ms),
          child: const Text('تطبيق'),
        ),
      ],
    );
  }

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
