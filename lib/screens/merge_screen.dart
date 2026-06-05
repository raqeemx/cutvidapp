import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/clip.dart';
import '../services/clip_repository.dart';
import '../services/merge_service.dart';
import '../services/permission_service.dart';
import '../services/video_cutter.dart';
import '../utils/app_theme.dart';
import '../utils/media_type.dart';
import '../utils/time_format.dart';

/// One item queued for merging (from the library or device storage).
class MergeItem {
  final String path;
  final String name;
  final bool isAudio;
  final String? thumbnailPath;
  final int? durationMs;
  const MergeItem({
    required this.path,
    required this.name,
    required this.isAudio,
    this.thumbnailPath,
    this.durationMs,
  });
}

class MergeScreen extends StatefulWidget {
  const MergeScreen({super.key});

  @override
  State<MergeScreen> createState() => _MergeScreenState();
}

class _MergeScreenState extends State<MergeScreen> {
  final List<MergeItem> _items = [];
  MergeMode _mode = MergeMode.fast;
  bool _merging = false;
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);

  /// The media kind of the queue (null until the first item is added).
  bool? get _kind => _items.isEmpty ? null : _items.first.isAudio;

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  bool _tryAdd(MergeItem item) {
    if (_kind != null && item.isAudio != _kind) {
      _snack('لا يمكن دمج الصوت مع الفيديو في عملية واحدة.');
      return false;
    }
    setState(() => _items.add(item));
    return true;
  }

  Future<void> _addFromLibrary() async {
    final repo = context.read<ClipRepository>();
    final all = repo.clips;
    if (all.isEmpty) {
      _snack('لا توجد مقاطع في المكتبة بعد.');
      return;
    }
    final selected = await Navigator.of(context).push<List<Clip>>(
      MaterialPageRoute(
        builder: (_) => _LibraryPickerScreen(clips: all, requireAudio: _kind),
      ),
    );
    if (selected == null) return;
    var added = 0;
    var skipped = 0;
    for (final c in selected) {
      final ok = _tryAdd(MergeItem(
        path: c.filePath,
        name: c.name,
        isAudio: c.isAudio,
        thumbnailPath: c.thumbnailPath,
        durationMs: c.durationMs,
      ));
      ok ? added++ : skipped++;
    }
    if (added > 0) _snack('أُضيف $added مقطع.');
    if (skipped > 0 && added == 0) {
      // _tryAdd already showed the mismatch message.
    }
  }

  Future<void> _addFromDevice() async {
    final audio = await _chooseDeviceKind();
    if (audio == null) return;

    final granted = audio
        ? await PermissionService.requestAudioAccess()
        : await PermissionService.requestVideoAccess();
    if (!mounted) return;
    if (!granted) {
      _snack('يلزم منح الإذن لاختيار الملفات.');
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: audio ? FileType.audio : FileType.video,
      allowMultiple: true,
    );
    if (result == null) return;
    for (final f in result.files) {
      if (f.path == null) continue;
      _tryAdd(MergeItem(
        path: f.path!,
        name: f.name,
        isAudio: isAudioFile(f.name),
      ));
    }
  }

  Future<bool?> _chooseDeviceKind() {
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.movie_creation_rounded,
                  color: AppColors.accent),
              title: const Text('فيديو من الجهاز',
                  style: TextStyle(color: AppColors.textPrimary)),
              onTap: () => Navigator.pop(ctx, false),
            ),
            ListTile(
              leading: const Icon(Icons.audiotrack_rounded,
                  color: AppColors.accent2),
              title: const Text('صوت من الجهاز',
                  style: TextStyle(color: AppColors.textPrimary)),
              onTap: () => Navigator.pop(ctx, true),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _startMerge() async {
    if (_items.length < 2) {
      _snack('اختر مقطعين على الأقل للدمج.');
      return;
    }
    final name = await _askName();
    if (name == null || name.trim().isEmpty) return;
    if (!mounted) return;

    final isAudio = _kind ?? false;
    final repo = context.read<ClipRepository>();

    setState(() => _merging = true);
    _progress.value = 0;

    try {
      // Central, interceptable merge entry point.
      final outPath = await MergeService.startMerge(
        inputPaths: _items.map((e) => e.path).toList(),
        isAudio: isAudio,
        mode: _mode,
        name: name.trim(),
        onProgress: (v) => _progress.value = v,
      );

      final durationMs = await MergeService.probeDurationMs(outPath) ?? 0;
      final thumb = isAudio
          ? ''
          : await VideoCutter.generateThumbnail(videoPath: outPath);

      final clip = Clip(
        id: const Uuid().v4(),
        name: name.trim(),
        filePath: outPath,
        sourcePath: '',
        sourceName: 'دمج ${_items.length} مقاطع',
        startMs: 0,
        endMs: durationMs,
        thumbnailPath: thumb,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await repo.addClip(clip);

      if (!mounted) return;
      setState(() => _merging = false);
      await _showSuccess(name.trim(), isAudio);
      if (mounted) Navigator.of(context).pop();
    } on MergeException catch (e) {
      if (!mounted) return;
      setState(() => _merging = false);
      _snack(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _merging = false);
      _snack('حدث خطأ غير متوقع أثناء الدمج.');
    }
  }

  Future<String?> _askName() {
    final controller = TextEditingController(text: 'مقطع مدموج');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('اسم المقطع المدموج'),
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
            child: const Text('دمج'),
          ),
        ],
      ),
    );
  }

  Future<void> _showSuccess(String name, bool isAudio) {
    return showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: const [
            Icon(Icons.check_circle_rounded, color: AppColors.accent2),
            SizedBox(width: 10),
            Text('تم الدمج بنجاح ✓'),
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
      appBar: AppBar(title: const Text('دمج المقاطع')),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _buildAddBar(),
            _buildModeSelector(),
            const Divider(height: 1, color: AppColors.surfaceLight),
            Expanded(
              child: _items.isEmpty ? _buildEmpty() : _buildList(),
            ),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildAddBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _merging ? null : _addFromLibrary,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accent,
                side: const BorderSide(color: AppColors.accent),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: const Icon(Icons.video_library_rounded, size: 20),
              label: const Text('من المكتبة'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _merging ? null : _addFromDevice,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accent2,
                side: const BorderSide(color: AppColors.accent2),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: const Icon(Icons.phone_android_rounded, size: 20),
              label: const Text('من الجهاز'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _modeChip('دمج سريع', MergeMode.fast),
              const SizedBox(width: 10),
              _modeChip('دمج بطيء', MergeMode.slow),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _mode == MergeMode.fast
                ? 'سريع وبلا إعادة ترميز — الأنسب لمقاطع المكتبة المتشابهة.'
                : 'يعيد الترميز لتوحيد المقاطع المختلفة المصدر/الإعدادات (أبطأ).',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeChip(String label, MergeMode mode) {
    final selected = _mode == mode;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: _merging ? null : (_) => setState(() => _mode = mode),
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

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.merge_rounded, size: 64, color: AppColors.surfaceLight),
            SizedBox(height: 14),
            Text(
              'أضف مقطعين أو أكثر لدمجهما',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'اختر من مكتبة التطبيق أو من ملفات الجهاز، ثم رتّبها بالسحب.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      itemCount: _items.length,
      // ignore: deprecated_member_use
      onReorder: (oldI, newI) {
        setState(() {
          if (newI > oldI) newI -= 1;
          final item = _items.removeAt(oldI);
          _items.insert(newI, item);
        });
      },
      itemBuilder: (context, i) {
        final item = _items[i];
        return _itemTile(item, i, key: ValueKey('${item.path}#$i'));
      },
    );
  }

  Widget _itemTile(MergeItem item, int index, {required Key key}) {
    final hasThumb = (item.thumbnailPath != null &&
        item.thumbnailPath!.isNotEmpty &&
        File(item.thumbnailPath!).existsSync());
    return Card(
      key: key,
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Container(
              alignment: Alignment.center,
              width: 22,
              child: Text(
                '${index + 1}',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Container(
              width: 56,
              height: 42,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
                gradient: (!hasThumb && item.isAudio)
                    ? const LinearGradient(
                        colors: [AppColors.accent2, AppColors.accent],
                      )
                    : null,
                image: hasThumb
                    ? DecorationImage(
                        image: FileImage(File(item.thumbnailPath!)),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: hasThumb
                  ? null
                  : Icon(
                      item.isAudio
                          ? Icons.music_note_rounded
                          : Icons.movie_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (item.durationMs != null)
                    Text(
                      formatMs(item.durationMs!),
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'إزالة',
              onPressed: _merging
                  ? null
                  : () => setState(() => _items.removeAt(index)),
              icon: const Icon(Icons.close_rounded,
                  color: AppColors.textSecondary, size: 20),
            ),
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.drag_handle_rounded,
                    color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final canMerge = _items.length >= 2 && !_merging;
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
              onPressed: canMerge ? _startMerge : null,
              icon: _merging
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : const Icon(Icons.merge_rounded),
              label: Text(
                _merging
                    ? 'جارٍ الدمج…'
                    : 'دمج المقاطع (${_items.length})',
              ),
            ),
          ),
          if (_merging)
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

/// Multi-select list of library clips for adding to the merge queue.
class _LibraryPickerScreen extends StatefulWidget {
  final List<Clip> clips;

  /// When non-null, only clips of this kind (audio/video) can be selected.
  final bool? requireAudio;

  const _LibraryPickerScreen({required this.clips, this.requireAudio});

  @override
  State<_LibraryPickerScreen> createState() => _LibraryPickerScreenState();
}

class _LibraryPickerScreenState extends State<_LibraryPickerScreen> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('اختر من المكتبة'),
        actions: [
          TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () {
                    final chosen = widget.clips
                        .where((c) => _selected.contains(c.id))
                        .toList();
                    Navigator.of(context).pop(chosen);
                  },
            child: Text(
              'إضافة (${_selected.length})',
              style: TextStyle(
                color: _selected.isEmpty
                    ? AppColors.textSecondary
                    : AppColors.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: widget.clips.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final c = widget.clips[i];
            final disabled =
                widget.requireAudio != null && c.isAudio != widget.requireAudio;
            final checked = _selected.contains(c.id);
            return Opacity(
              opacity: disabled ? 0.4 : 1,
              child: Card(
                child: CheckboxListTile(
                  value: checked,
                  onChanged: disabled
                      ? null
                      : (v) => setState(() {
                          if (v == true) {
                            _selected.add(c.id);
                          } else {
                            _selected.remove(c.id);
                          }
                        }),
                  activeColor: AppColors.accent,
                  title: Text(
                    c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textPrimary),
                  ),
                  subtitle: Text(
                    '${c.isAudio ? 'صوت' : 'فيديو'} · ${formatMs(c.durationMs)}',
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                  secondary: Icon(
                    c.isAudio
                        ? Icons.audiotrack_rounded
                        : Icons.movie_rounded,
                    color: c.isAudio ? AppColors.accent2 : AppColors.accent,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
