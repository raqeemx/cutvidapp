import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../models/clip.dart';
import '../services/clip_repository.dart';
import '../services/video_cutter.dart';
import '../utils/app_theme.dart';
import '../utils/time_format.dart';
import '../widgets/range_timeline.dart';

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

  int? _startMs;
  int? _endMs;

  // Preview mode: when active, playback auto-stops at _endMs.
  bool _previewMode = false;

  bool _saving = false;

  // Live progress (0..1) of the FFmpeg cut, used by the progress dialog.
  final ValueNotifier<double> _cutProgress = ValueNotifier<double>(0);

  // Momentary highlight after marking a point (visual confirmation).
  bool _startFlash = false;
  bool _endFlash = false;

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
    if (_previewMode && _endMs != null) {
      final pos = c.value.position.inMilliseconds;
      if (pos >= _endMs!) {
        c.pause();
        c.seekTo(Duration(milliseconds: _startMs ?? 0));
        if (mounted) setState(() => _previewMode = false);
      }
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    _cutProgress.dispose();
    super.dispose();
  }

  int get _positionMs => _controller?.value.position.inMilliseconds ?? 0;
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

  void _flash({required bool isStart}) {
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

  void _setStart() {
    final pos = _positionMs;
    HapticFeedback.mediumImpact();
    setState(() {
      _startMs = pos;
      // Keep end valid.
      if (_endMs != null && _endMs! <= _startMs!) {
        _endMs = null;
      }
    });
    _flash(isStart: true);
    _snack('تم ضبط البداية عند ${formatMs(pos)}');
  }

  void _setEnd() {
    final pos = _positionMs;
    if (_startMs == null) {
      _snack('اضبط نقطة البداية أولاً.');
      return;
    }
    if (pos <= _startMs!) {
      _snack('يجب أن تكون النهاية بعد نقطة البداية.');
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() => _endMs = pos);
    _flash(isStart: false);
    _snack('تم ضبط النهاية عند ${formatMs(pos)}');
  }

  // ---- Live drag handlers from the timeline ----

  void _onStartDragged(int ms) {
    setState(() {
      _previewMode = false;
      _startMs = ms;
      if (_endMs != null && _endMs! <= _startMs!) _endMs = null;
    });
    _controller?.seekTo(Duration(milliseconds: ms));
  }

  void _onEndDragged(int ms) {
    setState(() {
      _previewMode = false;
      _endMs = ms;
    });
    _controller?.seekTo(Duration(milliseconds: ms));
  }

  void _onSeek(int ms) {
    setState(() => _previewMode = false);
    _controller?.seekTo(Duration(milliseconds: ms));
  }

  Future<void> _previewClip() async {
    final c = _controller;
    if (c == null) return;
    if (_startMs == null || _endMs == null) {
      _snack('حدّد البداية والنهاية أولاً.');
      return;
    }
    await c.seekTo(Duration(milliseconds: _startMs!));
    await c.play();
    setState(() => _previewMode = true);
  }

  String? _validateRange() {
    if (_startMs == null || _endMs == null) {
      return 'يجب تحديد البداية والنهاية قبل الحفظ.';
    }
    if (_endMs! <= _startMs!) {
      return 'يجب أن يكون وقت النهاية بعد وقت البداية.';
    }
    if ((_endMs! - _startMs!) < 300) {
      return 'المقطع قصير جداً. اختر مدى أطول.';
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

    setState(() => _saving = true);
    _cutProgress.value = 0;
    _showProgressDialog();

    final id = const Uuid().v4();

    final outPath = await VideoCutter.cut(
      sourcePath: widget.videoPath,
      startMs: _startMs!,
      endMs: _endMs!,
      clipId: id,
      onProgress: (p) => _cutProgress.value = p,
    );

    if (!mounted) return;
    // Close the progress dialog.
    Navigator.of(context, rootNavigator: true).pop();

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
      startMs: _startMs!,
      endMs: _endMs!,
      thumbnailPath: thumb,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );

    await repo.addClip(clip);

    if (!mounted) return;
    setState(() => _saving = false);

    _showSavedDialog(name.trim());
  }

  void _showProgressDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('جارٍ قص المقطع…'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<double>(
                valueListenable: _cutProgress,
                builder: (context, value, _) {
                  final pct = (value * 100).clamp(0, 100).toStringAsFixed(0);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: value <= 0 ? null : value,
                          minHeight: 10,
                          backgroundColor: AppColors.surfaceLight,
                          color: AppColors.accent,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '%$pct',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              const Text(
                'تتم المعالجة على جهازك بالكامل دون اتصال.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _askClipName() async {
    final controller = TextEditingController(
      text: 'مقطع ${formatMs(_startMs!)}-${formatMs(_endMs!)}',
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
              setState(() {
                _startMs = null;
                _endMs = null;
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
    final current = isStart ? (_startMs ?? 0) : (_endMs ?? _positionMs);
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
        _startMs = result;
        if (_endMs != null && _endMs! <= _startMs!) _endMs = null;
      } else {
        if (_startMs != null && result <= _startMs!) {
          _snack('يجب أن تكون النهاية بعد البداية.');
          return;
        }
        _endMs = result;
      }
    });
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
    final c = _controller!;
    return SingleChildScrollView(
      child: Column(
        children: [
          // Video preview
          Container(
            color: Colors.black,
            width: double.infinity,
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio == 0
                  ? 16 / 9
                  : c.value.aspectRatio,
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
                  // Center play overlay — rebuilds only on play-state changes.
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
                ],
              ),
            ),
          ),

          // Scrub position + play controls — isolated rebuilds via the
          // controller's ValueListenable instead of a screen-wide setState.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: ValueListenableBuilder<VideoPlayerValue>(
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
                        size: 40,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 7,
                              ),
                              activeTrackColor: AppColors.accent,
                              inactiveTrackColor: AppColors.surfaceLight,
                              thumbColor: AppColors.accent,
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 14,
                              ),
                            ),
                            child: Slider(
                              value: posMs.clamp(0, durMs).toDouble(),
                              max: durMs.toDouble().clamp(1, double.infinity),
                              onChanged: (v) => _onSeek(v.toInt()),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  formatMs(posMs),
                                  style: const TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  formatMs(durMs),
                                  style: const TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),

          // Range timeline (draggable handles) — playhead follows position.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ValueListenableBuilder<VideoPlayerValue>(
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
          ),

          // Start / End cards
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: _TimeCard(
                    label: 'البداية',
                    value: _startMs == null
                        ? 'اضغط ضبط البداية'
                        : formatMs(_startMs!),
                    isPlaceholder: _startMs == null,
                    highlight: _startFlash,
                    color: AppColors.accent2,
                    onEdit: _startMs == null
                        ? null
                        : () => _editTimeManually(isStart: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _TimeCard(
                    label: 'النهاية',
                    value: _endMs == null
                        ? 'اضغط ضبط النهاية'
                        : formatMs(_endMs!),
                    isPlaceholder: _endMs == null,
                    highlight: _endFlash,
                    color: AppColors.accent,
                    onEdit: _endMs == null
                        ? null
                        : () => _editTimeManually(isStart: false),
                  ),
                ),
              ],
            ),
          ),

          if (_startMs != null && _endMs != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'مدة المقطع: ${formatMs(_endMs! - _startMs!)}',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

          // First-run guidance hint.
          if (_showHint)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: _HintBanner(onDismiss: _dismissHint),
            ),

          const SizedBox(height: 16),

          // Action buttons
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.flag_circle_rounded,
                        label: 'ضبط البداية',
                        color: AppColors.accent2,
                        onTap: _setStart,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.stop_circle_rounded,
                        label: 'ضبط النهاية',
                        color: AppColors.accent,
                        onTap: _setEnd,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.visibility_rounded,
                        label: 'معاينة المقطع',
                        color: AppColors.surfaceLight,
                        textColor: AppColors.textPrimary,
                        onTap: _previewClip,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
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
                const SizedBox(height: 28),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- small widgets ----

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
              'حرّك الفيديو إلى اللحظة المطلوبة ثم اضغط «ضبط البداية»، وكرّر '
              'للنهاية. يمكنك أيضاً سحب المقابض على الخط الزمني لضبط دقيق.',
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

class _TimeCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final VoidCallback? onEdit;
  final bool isPlaceholder;
  final bool highlight;
  const _TimeCard({
    required this.label,
    required this.value,
    required this.color,
    this.onEdit,
    this.isPlaceholder = false,
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
                  style: TextStyle(
                    color: isPlaceholder
                        ? AppColors.textSecondary
                        : AppColors.textPrimary,
                    fontSize: isPlaceholder ? 12.5 : 18,
                    fontWeight: isPlaceholder
                        ? FontWeight.w600
                        : FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          if (onEdit != null)
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: onEdit,
              icon: const Icon(
                Icons.edit_rounded,
                size: 18,
                color: AppColors.textSecondary,
              ),
            ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Color textColor;
  final VoidCallback onTap;
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.textColor = Colors.black,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Icon(icon, color: textColor, size: 26),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  color: textColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
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
