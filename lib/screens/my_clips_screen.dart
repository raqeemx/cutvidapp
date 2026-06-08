import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/clip.dart';
import '../services/clip_repository.dart';
import '../services/gallery_exporter.dart';
import '../services/permission_service.dart';
import '../utils/app_theme.dart';
import '../utils/time_format.dart';
import '../widgets/export_status_bar.dart';
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

  // Multi-select state.
  bool _selecting = false;
  final Set<String> _selected = {};

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

  void _enterSelection([String? id]) {
    setState(() {
      _selecting = true;
      if (id != null) _selected.add(id);
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggle(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  void _toggleSelectAll(List<Clip> visible) {
    final allSelected =
        visible.isNotEmpty && visible.every((c) => _selected.contains(c.id));
    setState(() {
      if (allSelected) {
        _selected.clear();
      } else {
        _selected.addAll(visible.map((c) => c.id));
      }
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _deleteSelected(ClipRepository repo) async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف المقاطع؟'),
        content: Text(
          'هل تريد حذف ${ids.length} ${_clipsWord(ids.length)}؟ '
          'لا يمكن التراجع بعد الحذف.',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await repo.deleteClips(ids);
    _snack('تم حذف ${ids.length} ${_clipsWord(ids.length)}');
    _exitSelection();
  }

  Future<void> _saveSelected(ClipRepository repo, List<Clip> all) async {
    final selectedClips =
        all.where((c) => _selected.contains(c.id)).toList();
    if (selectedClips.isEmpty) return;

    final granted = await PermissionService.requestSaveAccess();
    if (!mounted) return;
    if (!granted) {
      _snack('يلزم منح الإذن للحفظ في المعرض.');
      return;
    }

    final progress = ValueNotifier<int>(0);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('حفظ في المعرض'),
          content: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (context, done, _) {
              final total = selectedClips.length;
              final shown = (done + 1).clamp(1, total);
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: total == 0 ? null : done / total,
                      minHeight: 8,
                      backgroundColor: AppColors.surfaceLight,
                      color: AppColors.accent,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'جارٍ حفظ $shown من $total',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.textPrimary),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    var ok = 0;
    var fail = 0;
    for (var i = 0; i < selectedClips.length; i++) {
      progress.value = i;
      final success = await GalleryExporter.save(selectedClips[i]);
      if (success) {
        ok++;
        await repo.markSavedToGallery(selectedClips[i].id);
      } else {
        fail++;
      }
    }

    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();

    _snack(
      fail == 0
          ? 'تم حفظ $ok ${_clipsWord(ok)}'
          : 'تم حفظ $ok ${_clipsWord(ok)}، وفشل حفظ $fail',
    );
    _exitSelection();
  }

  static String _clipsWord(int n) => n == 1 ? 'مقطع' : 'مقاطع';

  @override
  Widget build(BuildContext context) {
    return Consumer<ClipRepository>(
      builder: (context, repo, _) {
        final all = repo.clips;
        final clips = _applyFilters(all);
        // Drop selections that no longer exist.
        _selected.removeWhere((id) => !all.any((c) => c.id == id));

        return Column(
          children: [
            _selecting ? _buildSelectionHeader(clips) : _buildHeader(all),
            const ExportStatusBar(),
            if (all.isNotEmpty && !_selecting) _buildSearchAndSort(),
            Expanded(
              child: all.isEmpty
                  ? const _EmptyState()
                  : clips.isEmpty
                      ? const _NoResults()
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          itemCount: clips.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, i) {
                            final c = clips[i];
                            return _ClipCard(
                              clip: c,
                              selecting: _selecting,
                              selected: _selected.contains(c.id),
                              onToggleSelect: () => _toggle(c.id),
                              onEnterSelection: () => _enterSelection(c.id),
                            );
                          },
                        ),
            ),
            if (_selecting) _buildSelectionActions(repo, all),
          ],
        );
      },
    );
  }

  Widget _buildHeader(List<Clip> all) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
      child: Row(
        children: [
          const Icon(Icons.collections_bookmark_rounded,
              color: AppColors.accent),
          const SizedBox(width: 10),
          const Text(
            'مقاطعي',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
          if (all.isNotEmpty)
            TextButton.icon(
              onPressed: () => _enterSelection(),
              icon: const Icon(Icons.checklist_rounded, size: 18),
              label: const Text('تحديد'),
            ),
        ],
      ),
    );
  }

  Widget _buildSelectionHeader(List<Clip> visible) {
    final allSelected =
        visible.isNotEmpty && visible.every((c) => _selected.contains(c.id));
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 12, 8),
      child: Row(
        children: [
          IconButton(
            tooltip: 'إنهاء التحديد',
            onPressed: _exitSelection,
            icon: const Icon(Icons.close_rounded, color: AppColors.textPrimary),
          ),
          Text(
            'تم تحديد ${_selected.length}',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => _toggleSelectAll(visible),
            child: Text(allSelected ? 'إلغاء الكل' : 'تحديد الكل'),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionActions(ClipRepository repo, List<Clip> all) {
    final has = _selected.isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.surfaceLight)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: has ? () => _saveSelected(repo, all) : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accent2,
                side: BorderSide(
                  color: has ? AppColors.accent2 : AppColors.surfaceLight,
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: const Icon(Icons.download_rounded, size: 20),
              label: const Text('حفظ المحدد'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: has ? () => _deleteSelected(repo) : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.danger,
                disabledBackgroundColor: AppColors.disabled,
              ),
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              label: const Text('حذف المحدد'),
            ),
          ),
        ],
      ),
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
  final bool selecting;
  final bool selected;
  final VoidCallback onToggleSelect;
  final VoidCallback onEnterSelection;

  const _ClipCard({
    required this.clip,
    required this.selecting,
    required this.selected,
    required this.onToggleSelect,
    required this.onEnterSelection,
  });

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
    final repo = context.read<ClipRepository>();
    final granted = await PermissionService.requestSaveAccess();
    if (!context.mounted) return;
    if (!granted) {
      _snack(context, 'يلزم منح الإذن للحفظ في المعرض.');
      return;
    }
    final success = await GalleryExporter.save(clip);
    if (!context.mounted) return;
    if (success) {
      await repo.markSavedToGallery(clip.id);
      if (context.mounted) {
        _snack(context, clip.isAudio
            ? 'تم الحفظ في الموسيقى'
            : 'تم الحفظ في المعرض');
      }
    } else {
      _snack(context, 'تعذّر الحفظ على الجهاز.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasThumb =
        clip.thumbnailPath.isNotEmpty && File(clip.thumbnailPath).existsSync();

    final card = Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: selected
            ? const BorderSide(color: AppColors.accent, width: 2)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (selecting) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 24, left: 2, right: 6),
                    child: Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: selected
                          ? AppColors.accent
                          : AppColors.textSecondary,
                    ),
                  ),
                ],
                // Thumbnail
                GestureDetector(
                  onTap: selecting ? onToggleSelect : () => _play(context),
                  child: Container(
                    width: 96,
                    height: 70,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(10),
                      gradient: (!hasThumb && clip.isAudio)
                          ? const LinearGradient(
                              colors: [AppColors.accent2, AppColors.accent],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            )
                          : null,
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
                        child: Icon(
                          clip.isAudio
                              ? Icons.music_note_rounded
                              : Icons.play_arrow_rounded,
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
                      if (clip.savedToGallery) ...[
                        const SizedBox(height: 6),
                        const _SavedBadge(),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (!selecting) ...[
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
          ],
        ),
      ),
    );

    return GestureDetector(
      onTap: selecting ? onToggleSelect : null,
      onLongPress: selecting ? null : onEnterSelection,
      child: card,
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

/// "Saved to gallery" badge shown on a clip card.
class _SavedBadge extends StatelessWidget {
  const _SavedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.accent2.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_rounded,
              size: 13, color: AppColors.accent2),
          SizedBox(width: 4),
          Text(
            'محفوظ في المعرض',
            style: TextStyle(
              color: AppColors.accent2,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
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
