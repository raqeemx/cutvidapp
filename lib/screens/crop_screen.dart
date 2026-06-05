import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../models/clip.dart';
import '../services/clip_repository.dart';
import '../services/crop_service.dart';
import '../services/merge_service.dart';
import '../services/permission_service.dart';
import '../services/video_cutter.dart';
import '../utils/app_theme.dart';
import '../widgets/crop_overlay.dart';

class _Ratio {
  final String label;
  final double? value; // width/height; null = free
  const _Ratio(this.label, this.value);
}

class CropScreen extends StatefulWidget {
  const CropScreen({super.key});

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  static const _ratios = <_Ratio>[
    _Ratio('حر', null),
    _Ratio('1:1', 1.0),
    _Ratio('4:5', 0.8),
    _Ratio('9:16', 9 / 16),
    _Ratio('16:9', 16 / 9),
  ];

  // Platform templates → aspect ratio.
  static const _templates = <_Ratio>[
    _Ratio('TikTok / Shorts', 9 / 16),
    _Ratio('Instagram Post', 1.0),
    _Ratio('Instagram Story', 9 / 16),
    _Ratio('YouTube', 16 / 9),
  ];

  String? _videoPath;
  String? _videoName;

  VideoPlayerController? _controller;
  bool _ready = false;
  String? _error;

  int _rotation = 0; // quarter turns, clockwise
  double? _aspect; // null = free
  Rect _cropRect = const Rect.fromLTRB(0, 0, 1, 1);
  bool _previewResult = false;

  bool _cropping = false;
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);

  @override
  void dispose() {
    _controller?.dispose();
    _progress.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- Source selection ----
  Future<void> _pickFromDevice() async {
    final granted = await PermissionService.requestVideoAccess();
    if (!mounted) return;
    if (!granted) {
      _snack('يلزم إذن الوصول إلى الفيديو.');
      return;
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );
    if (result == null || result.files.single.path == null) return;
    _open(result.files.single.path!, result.files.single.name);
  }

  Future<void> _pickFromLibrary() async {
    final repo = context.read<ClipRepository>();
    final videos = repo.clips.where((c) => !c.isAudio).toList();
    if (videos.isEmpty) {
      _snack('لا توجد فيديوهات في المكتبة.');
      return;
    }
    final chosen = await Navigator.of(context).push<Clip>(
      MaterialPageRoute(builder: (_) => _LibraryVideoPicker(videos: videos)),
    );
    if (chosen == null) return;
    _open(chosen.filePath, chosen.name);
  }

  Future<void> _open(String path, String name) async {
    setState(() {
      _videoPath = path;
      _videoName = name;
      _ready = false;
      _error = null;
    });
    try {
      final c = VideoPlayerController.file(File(path));
      await c.initialize();
      c.setLooping(true);
      c.addListener(() {
        if (mounted) setState(() {});
      });
      await c.play();
      if (!mounted) return;
      setState(() {
        _controller = c;
        _ready = true;
        _rotation = 0;
        _aspect = null;
        _cropRect = const Rect.fromLTRB(0, 0, 1, 1);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذّر فتح هذا الفيديو.\n$e');
    }
  }

  // ---- Editing ----
  double _rotatedAspect() {
    final a = _controller!.value.aspectRatio;
    final safe = a == 0 ? 16 / 9 : a;
    return _rotation.isOdd ? 1 / safe : safe;
  }

  Rect _defaultRect() {
    if (_aspect == null) return const Rect.fromLTRB(0, 0, 1, 1);
    final r = _rotatedAspect();
    final ratioOverR = _aspect! / r; // = nw/nh
    double nw, nh;
    if (ratioOverR >= 1) {
      nw = 1;
      nh = 1 / ratioOverR;
    } else {
      nh = 1;
      nw = ratioOverR;
    }
    return Rect.fromLTWH((1 - nw) / 2, (1 - nh) / 2, nw, nh);
  }

  void _setAspect(double? a) {
    setState(() {
      _aspect = a;
      _cropRect = _defaultRect();
    });
  }

  void _rotate(int dir) {
    setState(() {
      _rotation = (_rotation + dir + 4) % 4;
      _cropRect = _defaultRect();
    });
  }

  Future<void> _runCrop() async {
    final path = _videoPath;
    final c = _controller;
    if (path == null || c == null) {
      _snack('اختر فيديو أولاً.');
      return;
    }
    final name = await _askName();
    if (name == null || name.trim().isEmpty) return;
    if (!mounted) return;

    final repo = context.read<ClipRepository>();
    final size = c.value.size;

    setState(() => _cropping = true);
    _progress.value = 0;
    try {
      final outPath = await CropService.startCrop(
        inputPath: path,
        videoWidth: size.width.round(),
        videoHeight: size.height.round(),
        cropRect: _cropRect,
        rotationQuarterTurns: _rotation,
        name: name.trim(),
        onProgress: (v) => _progress.value = v,
      );

      final durationMs = await MergeService.probeDurationMs(outPath) ?? 0;
      final thumb = await VideoCutter.generateThumbnail(videoPath: outPath);

      final clip = Clip(
        id: const Uuid().v4(),
        name: name.trim(),
        filePath: outPath,
        sourcePath: path,
        sourceName: 'اقتصاص: ${_videoName ?? ''}'.trim(),
        startMs: 0,
        endMs: durationMs,
        thumbnailPath: thumb,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await repo.addClip(clip);

      if (!mounted) return;
      setState(() => _cropping = false);
      await _showSuccess(name.trim());
      if (mounted) Navigator.of(context).pop();
    } on CropException catch (e) {
      if (!mounted) return;
      setState(() => _cropping = false);
      _snack(e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _cropping = false);
      _snack('حدث خطأ غير متوقع أثناء الاقتصاص.');
    }
  }

  Future<String?> _askName() {
    final controller = TextEditingController(text: 'مقطع مقصوص');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('اسم المقطع'),
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
            child: const Text('اقتصاص'),
          ),
        ],
      ),
    );
  }

  Future<void> _showSuccess(String name) {
    return showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: const [
            Icon(Icons.check_circle_rounded, color: AppColors.accent2),
            SizedBox(width: 10),
            Text('تم الحفظ بنجاح ✓'),
          ],
        ),
        content: Text(
          'تم حفظ "$name" في مكتبتك.\n'
          'يمكنك تشغيله أو تصديره من تبويب «مقاطعي».',
          style: const TextStyle(color: AppColors.textSecondary, height: 1.5),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('حسناً'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('اقتصاص الفيديو')),
      body: SafeArea(
        top: false,
        child: _videoPath == null
            ? _buildSourcePicker()
            : _error != null
                ? _ErrorView(message: _error!)
                : !_ready
                    ? const Center(child: CircularProgressIndicator())
                    : _buildEditor(),
      ),
    );
  }

  // ---- Source picker UI ----
  Widget _buildSourcePicker() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.crop_rounded, size: 72, color: AppColors.accent),
            const SizedBox(height: 20),
            const Text(
              'اختر فيديو لاقتصاصه',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _pickFromLibrary,
                icon: const Icon(Icons.video_library_rounded),
                label: const Text('من مكتبة التطبيق'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _pickFromDevice,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accent2,
                  side: const BorderSide(color: AppColors.accent2),
                ),
                icon: const Icon(Icons.phone_android_rounded),
                label: const Text('من ملفات الجهاز'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Editor UI ----
  Widget _buildEditor() {
    return Column(
      children: [
        _buildPreview(),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildToolRow(),
                const SizedBox(height: 14),
                const Text(
                  'نسبة الأبعاد',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _ratios
                      .map((r) => _ratioChip(r.label, r.value))
                      .toList(),
                ),
                const SizedBox(height: 14),
                const Text(
                  'قوالب المنصات',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _templates
                      .map((t) => _ratioChip(t.label, t.value))
                      .toList(),
                ),
              ],
            ),
          ),
        ),
        _buildBottomBar(),
      ],
    );
  }

  Widget _buildPreview() {
    final c = _controller!;
    final r = _rotatedAspect();
    final maxH = MediaQuery.of(context).size.height * 0.42;
    return Container(
      color: Colors.black,
      width: double.infinity,
      height: maxH,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final boxW = constraints.maxWidth;
          final boxH = constraints.maxHeight;
          double dw, dh;
          if (boxW / boxH > r) {
            dh = boxH;
            dw = boxH * r;
          } else {
            dw = boxW;
            dh = boxW / r;
          }
          final video = RotatedBox(
            quarterTurns: _rotation,
            child: VideoPlayer(c),
          );
          if (_previewResult) {
            return Center(child: _resultPreview(dw, dh, video));
          }
          return Center(
            child: SizedBox(
              width: dw,
              height: dh,
              child: Stack(
                children: [
                  Positioned.fill(child: video),
                  Positioned.fill(
                    child: CropOverlay(
                      displaySize: Size(dw, dh),
                      rect: _cropRect,
                      aspectRatio: _aspect,
                      onChanged: (rect) => setState(() => _cropRect = rect),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Shows only the kept (cropped) region, scaled to fit — a true result preview.
  Widget _resultPreview(double dw, double dh, Widget video) {
    final pr = Rect.fromLTWH(
      _cropRect.left * dw,
      _cropRect.top * dh,
      _cropRect.width * dw,
      _cropRect.height * dh,
    );
    if (pr.width < 1 || pr.height < 1) return video;
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: pr.width,
        height: pr.height,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 0,
            maxWidth: double.infinity,
            minHeight: 0,
            maxHeight: double.infinity,
            child: Transform.translate(
              offset: Offset(-pr.left, -pr.top),
              child: SizedBox(width: dw, height: dh, child: video),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolRow() {
    return Row(
      children: [
        _toolButton(Icons.rotate_left_rounded, 'تدوير يسار',
            () => _rotate(-1)),
        const SizedBox(width: 8),
        _toolButton(Icons.rotate_right_rounded, 'تدوير يمين',
            () => _rotate(1)),
        const Spacer(),
        _toolButton(
          _previewResult ? Icons.edit_rounded : Icons.visibility_rounded,
          _previewResult ? 'تحرير' : 'معاينة الناتج',
          () => setState(() => _previewResult = !_previewResult),
        ),
      ],
    );
  }

  Widget _toolButton(IconData icon, String label, VoidCallback onTap) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _cropping ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 20, color: AppColors.textPrimary),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ratioChip(String label, double? value) {
    final selected = _aspect == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: _cropping ? null : (_) => _setAspect(value),
      backgroundColor: AppColors.surface,
      selectedColor: AppColors.accent,
      labelStyle: TextStyle(
        color: selected ? Colors.black : AppColors.textPrimary,
        fontWeight: FontWeight.w700,
      ),
      side: BorderSide(
        color: selected ? AppColors.accent : AppColors.surfaceLight,
      ),
    );
  }

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
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _cropping ? null : _runCrop,
              icon: _cropping
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : const Icon(Icons.crop_rounded),
              label: Text(_cropping ? 'جارٍ الاقتصاص…' : 'اقتصاص وحفظ'),
            ),
          ),
          if (_cropping)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: ValueListenableBuilder<double>(
                valueListenable: _progress,
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
            const Icon(Icons.error_outline_rounded,
                color: AppColors.danger, size: 48),
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

/// Single-select list of library videos for cropping.
class _LibraryVideoPicker extends StatelessWidget {
  final List<Clip> videos;
  const _LibraryVideoPicker({required this.videos});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('اختر فيديو')),
      body: SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: videos.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final c = videos[i];
            final hasThumb = c.thumbnailPath.isNotEmpty &&
                File(c.thumbnailPath).existsSync();
            return Card(
              child: ListTile(
                onTap: () => Navigator.of(context).pop(c),
                leading: Container(
                  width: 56,
                  height: 42,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(8),
                    image: hasThumb
                        ? DecorationImage(
                            image: FileImage(File(c.thumbnailPath)),
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                  child: hasThumb
                      ? null
                      : const Icon(Icons.movie_rounded,
                          color: Colors.white, size: 20),
                ),
                title: Text(
                  c.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textPrimary),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
