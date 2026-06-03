import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:path/path.dart' as p;

import '../models/clip.dart';
import '../services/clip_repository.dart';
import '../services/permission_service.dart';
import '../utils/app_theme.dart';
import '../utils/time_format.dart';
import 'clip_player_screen.dart';

class MyClipsScreen extends StatelessWidget {
  const MyClipsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ClipRepository>(
      builder: (context, repo, _) {
        final clips = repo.clips;
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
                    'My Clips',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: clips.isEmpty
                  ? const _EmptyState()
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
}

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
        title: const Text('Rename clip'),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: const InputDecoration(border: OutlineInputBorder()),
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
    if (newName != null && newName.trim().isNotEmpty) {
      await repo.renameClip(clip.id, newName.trim());
    }
  }

  Future<void> _delete(BuildContext context) async {
    final repo = context.read<ClipRepository>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete clip?'),
        content: Text(
          '"${clip.name}" will be permanently removed.',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await repo.deleteClip(clip.id);
      if (context.mounted) _snack(context, 'Clip deleted');
    }
  }

  Future<void> _share(BuildContext context) async {
    final file = File(clip.filePath);
    if (!await file.exists()) {
      if (context.mounted) _snack(context, 'Clip file not found.');
      return;
    }
    await Share.shareXFiles([XFile(clip.filePath)], text: clip.name);
  }

  Future<void> _saveToGallery(BuildContext context) async {
    final granted = await PermissionService.requestSaveAccess();
    if (!context.mounted) return;
    if (!granted) {
      _snack(context, 'Permission needed to save to gallery.');
      return;
    }
    try {
      final result = await SaverGallery.saveFile(
        filePath: clip.filePath,
        fileName: '${p.basenameWithoutExtension(clip.filePath)}.mp4',
        androidRelativePath: 'Movies/ClipMaster',
        skipIfExists: false,
      );
      if (!context.mounted) return;
      if (result.isSuccess) {
        _snack(context, 'Saved to gallery (Movies/ClipMaster)');
      } else {
        _snack(context, 'Could not save to gallery.');
      }
    } catch (e) {
      if (context.mounted) _snack(context, 'Save failed: $e');
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
                              'From: ${clip.sourceName}',
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
            // Action row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _iconAction(
                  Icons.play_arrow_rounded,
                  'Play',
                  () => _play(context),
                ),
                _iconAction(
                  Icons.edit_rounded,
                  'Rename',
                  () => _rename(context),
                ),
                _iconAction(
                  Icons.download_rounded,
                  'Gallery',
                  () => _saveToGallery(context),
                ),
                _iconAction(
                  Icons.share_rounded,
                  'Share',
                  () => _share(context),
                ),
                _iconAction(
                  Icons.delete_outline_rounded,
                  'Delete',
                  () => _delete(context),
                  color: AppColors.danger,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconAction(
    IconData icon,
    String label,
    VoidCallback onTap, {
    Color color = AppColors.textPrimary,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(color: color, fontSize: 11)),
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
              'No clips yet',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Go to the Videos tab, pick a video, mark the part you like, and save your first clip.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
