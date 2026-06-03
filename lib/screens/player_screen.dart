import 'dart:io';

import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    _init();
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
      setState(() => _error = 'Could not open this video.\n$e');
    }
  }

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
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
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

  void _setStart() {
    final pos = _positionMs;
    setState(() {
      _startMs = pos;
      // Keep end valid.
      if (_endMs != null && _endMs! <= _startMs!) {
        _endMs = null;
      }
    });
    _snack('Start set at ${formatMs(pos)}');
  }

  void _setEnd() {
    final pos = _positionMs;
    if (_startMs == null) {
      _snack('Set the start point first.');
      return;
    }
    if (pos <= _startMs!) {
      _snack('End must be after the start point.');
      return;
    }
    setState(() => _endMs = pos);
    _snack('End set at ${formatMs(pos)}');
  }

  Future<void> _previewClip() async {
    final c = _controller;
    if (c == null) return;
    if (_startMs == null || _endMs == null) {
      _snack('Mark both start and end first.');
      return;
    }
    await c.seekTo(Duration(milliseconds: _startMs!));
    await c.play();
    setState(() => _previewMode = true);
  }

  String? _validateRange() {
    if (_startMs == null || _endMs == null) {
      return 'You must mark both start and end before saving.';
    }
    if (_endMs! <= _startMs!) {
      return 'End time must be after the start time.';
    }
    if ((_endMs! - _startMs!) < 300) {
      return 'Clip is too short. Select a longer range.';
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

    setState(() => _saving = true);
    final id = const Uuid().v4();

    final outPath = await VideoCutter.cut(
      sourcePath: widget.videoPath,
      startMs: _startMs!,
      endMs: _endMs!,
      clipId: id,
    );

    if (!mounted) return;

    if (outPath == null) {
      setState(() => _saving = false);
      _snack('Failed to cut the clip. Try a different range.');
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

  Future<String?> _askClipName() async {
    final controller = TextEditingController(
      text: 'Clip ${formatMs(_startMs!)}-${formatMs(_endMs!)}',
    );
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name your clip'),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: const InputDecoration(
            hintText: 'Enter a name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
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
            Text('Clip saved'),
          ],
        ),
        content: Text(
          '"$name" was saved to your library.\nYou can keep cutting more clips from this video.',
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
            child: const Text('Cut another'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
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
        title: isStart ? 'Edit start time' : 'Edit end time',
      ),
    );
    if (result == null) return;
    setState(() {
      if (isStart) {
        _startMs = result;
        if (_endMs != null && _endMs! <= _startMs!) _endMs = null;
      } else {
        if (_startMs != null && result <= _startMs!) {
          _snack('End must be after start.');
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
                      left: 10,
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
                          'PREVIEW',
                          style: TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  GestureDetector(
                    onTap: _togglePlay,
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

          // Scrub position + play controls
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Column(
              children: [
                Row(
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
                              value: _positionMs
                                  .clamp(0, _durationMs)
                                  .toDouble(),
                              max: _durationMs.toDouble().clamp(
                                1,
                                double.infinity,
                              ),
                              onChanged: (v) {
                                setState(() => _previewMode = false);
                                c.seekTo(Duration(milliseconds: v.toInt()));
                              },
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  formatMs(_positionMs),
                                  style: const TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  formatMs(_durationMs),
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
                ),
              ],
            ),
          ),

          // Range timeline
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: RangeTimeline(
              durationMs: _durationMs,
              positionMs: _positionMs,
              startMs: _startMs,
              endMs: _endMs,
            ),
          ),

          // Start / End cards
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: _TimeCard(
                    label: 'START',
                    value: _startMs == null ? '--:--' : formatMs(_startMs!),
                    color: AppColors.accent2,
                    onEdit: _startMs == null
                        ? null
                        : () => _editTimeManually(isStart: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _TimeCard(
                    label: 'END',
                    value: _endMs == null ? '--:--' : formatMs(_endMs!),
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
                'Clip length: ${formatMs(_endMs! - _startMs!)}',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
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
                        label: 'Set Start',
                        color: AppColors.accent2,
                        onTap: _setStart,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.stop_circle_rounded,
                        label: 'Set End',
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
                        label: 'Preview Clip',
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
                    label: Text(_saving ? 'Cutting clip…' : 'Save Clip'),
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
          Column(
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
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const Spacer(),
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
          _adjustRow('Seconds', -1000, 1000, '1s'),
          const SizedBox(height: 8),
          _adjustRow('Fine', -100, 100, '0.1s'),
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
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, _ms),
          child: const Text('Apply'),
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
