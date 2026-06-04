import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:saver_gallery/saver_gallery.dart';

import '../models/clip.dart';
import '../services/clip_repository.dart';
import '../services/permission_service.dart';
import '../utils/app_theme.dart';
import '../utils/time_format.dart';
import 'clip_player_screen.dart';

enum ClipSort { newest, longest, name }

extension on ClipSort {
  String get label => switch (this) {
        ClipSort.newest => 'الأحدث',
        ClipSort.longest => 'الأطول',
        ClipSort.name => 'الاسم',
      };
}

class MyClipsScreen extends StatefulWidget {
  const MyClipsScreen({super.key});

  @override
  State<MyClipsScreen> createState() => _MyClipsScreenState();
}

class _MyClipsScreenState extends State<MyClipsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  ClipSort _sort = ClipSort.newest;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Clip> _applyFilters(List<Clip> clips) {
    final q = _query.trim().toLowerCase();
    var list = q.isEmpty
        ? List<Clip>.from(clips)
        : clips.where((c) => c.name.toLowerCase().contains(q)).toList();

    switch (_sort) {
      case ClipSort.newest:
        list.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
      case ClipSort.longest:
        list.sort((a, b) => b.durationMs.compareTo(a.durationMs));
      case ClipSort.name:
        list.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ClipRepository>(
      builder: (context, repo, _) {
        final all = repo.clips;
        final clips = _applyFilters(all);
        return Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.collections_bookmark_rounded,
                    color: AppColors.accent,
                  ),
                  SizedBox(width: 10),
                  Text(
                    'مقاطعي',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            if (all.isNotEmpty) _buildSearchAndSort(),
            Expanded(
              child: all.isEmpty
                  ? const _EmptyState()
                  : clips.isEmpty
                  ? const _NoResults()
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: clips.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, i) => _ClipCard(clip: clips[i]),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSearchAndSort() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _query = v),
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'ابحث بالاسم…',
                hintStyle: const TextStyle(color: AppColors.textSecondary),
                prefixIcon: const Icon(
                  Icons.search_rounded,
                  color: AppColors.textSecondary,
                ),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(
                          Icons.clear_rounded,
                          color: AppColors.textSecondary,
                          size: 20,
                        ),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
                filled: true,
                fillColor: AppColors.surface,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          PopupMenuButton<ClipSort>(
            tooltip: 'فرز',
            initialValue: _sort,
            color: AppColors.surface,
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (ctx) => ClipSort.values
                .map(
                  (s) => PopupMenuItem<ClipSort>(
                    value: s,
                    child: Row(
                      children: [
                        Icon(
                          s == _sort
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 18,
                          color: s == _sort
                              ? AppColors.accent
                              : AppColors.textSecondary,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          s.label,
                          style: const TextStyle(color: AppColors.textPrimary),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.sort_rounded,
                    color: AppColors.textSecondary,
                    size: 20,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _sort.label,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _ClipMenuAction { rename, gallery, delete }

class _ClipCard extends StatelessWidget {
  final Clip clip;
  const _ClipCard({required this.clip});

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _play(BuildContext context) async {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ClipPlayerScreen(clip: clip)));
  }

  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: clip.name);
    final repo = context.read<ClipRepository>();
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إعادة تسمية المقطع'),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: const InputDecoration(border: OutlineInputBorder()),
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
    if (newName != null && newName.trim().isNotEmpty) {
      await repo.renameClip(clip.id, newName.trim());
    }
  }

  /// Soft-delete with a 5-second window to undo before files are removed.
  void _delete(BuildContext context) {
    final repo = context.read<ClipRepository>();
    final messenger = ScaffoldMessenger.of(context);
    repo.scheduleDelete(clip.id);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 5),
        content: Text('تم حذف "${clip.name}"'),
        action: SnackBarAction(
          label: 'تراجع',
          textColor: AppColors.accent,
          onPressed: () => repo.undoDelete(clip.id),
        ),
      ),
    );
  }

  Future<void> _share(BuildContext context) async {
    final file = File(clip.filePath);
    if (!await file.exists()) {
      if (context.mounted) _snack(context, 'ملف المقطع غير موجود.');
      return;
    }
    await Share.shareXFiles([XFile(clip.filePath)], text: clip.name);
  }

  Future<void> _saveToGallery(BuildContext context) async {
    final granted = await PermissionService.requestSaveAccess();
    if (!context.mounted) return;
    if (!granted) {
      _snack(context, 'يلزم منح الإذن للحفظ في المعرض.');
      return;
    }
    try {
      // Save to the gallery using the user's clip name, not a random id.
      final safeName = clip.name.trim().replaceAll(
        RegExp(r'[\\/:*?"<>|\x00-\x1F]'),
        '_',
      );
      final result = await SaverGallery.saveFile(
        filePath: clip.filePath,
        fileName: '${safeName.isEmpty ? 'clip' : safeName}.mp4',
        androidRelativePath: 'Movies/ClipMaster',
        skipIfExists: false,
      );
      if (!context.mounted) return;
      if (result.isSuccess) {
        _snack(context, 'تم الحفظ في المعرض (Movies/ClipMaster)');
      } else {
        _snack(context, 'تعذّر الحفظ في المعرض.');
      }
    } catch (e) {
      if (context.mounted) _snack(context, 'فشل الحفظ: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasThumb =
        clip.thumbnailPath.isNotEmpty && File(clip.thumbnailPath).existsSync();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Thumbnail
                GestureDetector(
                  onTap: () => _play(context),
                  child: Container(
                    width: 96,
                    height: 70,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(10),
                      image: hasThumb
                          ? DecorationImage(
                              image: FileImage(File(clip.thumbnailPath)),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    child: Center(
                      child: Container(
                        decoration: const BoxDecoration(
                          color: Colors.black45,
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(6),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        clip.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(
                            Icons.timer_outlined,
                            size: 14,
                            color: AppColors.accent,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            formatMs(clip.durationMs),
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '${formatMs(clip.startMs)} → ${formatMs(clip.endMs)}',
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(
                            Icons.movie_outlined,
                            size: 14,
                            color: AppColors.textSecondary,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              'من: ${clip.sourceName}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 20, color: AppColors.surfaceLight),
            // Action row — three primary actions; the rest live in a menu.
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _iconAction(
                  Icons.play_arrow_rounded,
                  'تشغيل',
                  () => _play(context),
                ),
                _iconAction(
                  Icons.share_rounded,
                  'مشاركة',
                  () => _share(context),
                ),
                _moreMenu(context),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _moreMenu(BuildContext context) {
    return PopupMenuButton<_ClipMenuAction>(
      tooltip: 'المزيد',
      color: AppColors.surface,
      onSelected: (a) {
        switch (a) {
          case _ClipMenuAction.rename:
            _rename(context);
          case _ClipMenuAction.gallery:
            _saveToGallery(context);
          case _ClipMenuAction.delete:
            _delete(context);
        }
      },
      itemBuilder: (ctx) => const [
        PopupMenuItem(
          value: _ClipMenuAction.rename,
          child: _MenuRow(
            icon: Icons.edit_rounded,
            label: 'إعادة تسمية',
          ),
        ),
        PopupMenuItem(
          value: _ClipMenuAction.gallery,
          child: _MenuRow(
            icon: Icons.download_rounded,
            label: 'حفظ في المعرض',
          ),
        ),
        PopupMenuItem(
          value: _ClipMenuAction.delete,
          child: _MenuRow(
            icon: Icons.delete_outline_rounded,
            label: 'حذف',
            color: AppColors.danger,
          ),
        ),
      ],
      child: const _IconActionContent(
        icon: Icons.more_horiz_rounded,
        label: 'المزيد',
      ),
    );
  }

  Widget _iconAction(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: _IconActionContent(icon: icon, label: label),
    );
  }
}

/// Shared visual for action-row entries with a 48dp-friendly touch target.
class _IconActionContent extends StatelessWidget {
  final IconData icon;
  final String label;
  const _IconActionContent({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppColors.textPrimary, size: 24),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _MenuRow({
    required this.icon,
    required this.label,
    this.color = AppColors.textPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}

class _NoResults extends StatelessWidget {
  const _NoResults();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off_rounded, size: 56, color: AppColors.surfaceLight),
            SizedBox(height: 14),
            Text(
              'لا توجد نتائج مطابقة',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(
              Icons.video_library_outlined,
              size: 72,
              color: AppColors.surfaceLight,
            ),
            SizedBox(height: 16),
            Text(
              'لا توجد مقاطع بعد',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'افتح تبويب الفيديوهات، اختر فيديو، وحدّد أول لحظة تعجبك.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
