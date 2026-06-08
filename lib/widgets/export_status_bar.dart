import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/export_queue_service.dart';
import '../utils/app_theme.dart';
import '../utils/time_format.dart';

/// A compact, tappable status strip showing the active cut and queue size.
/// Hides itself when there is no active work. Tapping opens the full queue.
class ExportStatusBar extends StatelessWidget {
  const ExportStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ExportQueueService>(
      builder: (context, queue, _) {
        if (!queue.hasActiveWork) return const SizedBox.shrink();
        final current = queue.currentJob;
        final waiting = queue.waitingCount;
        final pct = ((current?.progress ?? 0) * 100).clamp(0, 100).round();

        return Material(
          color: AppColors.surface,
          child: InkWell(
            onTap: () => showExportQueueSheet(context),
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: AppColors.surfaceLight),
                  bottom: BorderSide(color: AppColors.surfaceLight),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.accent,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              current != null
                                  ? 'جارٍ القص: ${current.name}'
                                  : 'في طابور القص',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              waiting > 0
                                  ? 'في الانتظار: $waiting مقاطع'
                                  : 'آخر مقطع قيد المعالجة',
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (current != null)
                        Text(
                          '%$pct',
                          style: const TextStyle(
                            color: AppColors.accent,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      const Icon(Icons.keyboard_arrow_up_rounded,
                          color: AppColors.textSecondary),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: (current?.progress ?? 0) <= 0
                          ? null
                          : current!.progress,
                      minHeight: 5,
                      backgroundColor: AppColors.surfaceLight,
                      color: AppColors.accent,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Opens the full "Export Queue" as a bottom sheet.
void showExportQueueSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _ExportQueueSheet(),
  );
}

class _ExportQueueSheet extends StatelessWidget {
  const _ExportQueueSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Consumer<ExportQueueService>(
        builder: (context, queue, _) {
          final jobs = queue.jobs;
          final hasFinished = jobs.any((j) =>
              j.status == ExportStatus.done ||
              j.status == ExportStatus.failed);
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.playlist_play_rounded,
                          color: AppColors.accent),
                      const SizedBox(width: 10),
                      const Text(
                        'طابور القص',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Spacer(),
                      if (hasFinished)
                        TextButton(
                          onPressed: queue.clearFinished,
                          child: const Text('مسح المنتهية'),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: AppColors.surfaceLight),
                if (jobs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Text(
                      'لا توجد مقاطع في الطابور.',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.all(12),
                      itemCount: jobs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) =>
                          _JobTile(job: jobs[i], queue: queue),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  final ExportJob job;
  final ExportQueueService queue;
  const _JobTile({required this.job, required this.queue});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Icon(job.isAudio ? Icons.audiotrack_rounded : Icons.movie_rounded,
                color: AppColors.accent2, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    job.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${formatMs(job.startMs)} → ${formatMs(job.endMs)} · '
                    '${formatMs(job.durationMs)}',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  if (job.status == ExportStatus.processing) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: job.progress <= 0 ? null : job.progress,
                        minHeight: 4,
                        backgroundColor: AppColors.surfaceLight,
                        color: AppColors.accent,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            _StatusChip(status: job.status),
            _trailingAction(context),
          ],
        ),
      ),
    );
  }

  Widget _trailingAction(BuildContext context) {
    switch (job.status) {
      case ExportStatus.waiting:
        return IconButton(
          tooltip: 'حذف من الطابور',
          onPressed: () => queue.removeWaiting(job.id),
          icon: const Icon(Icons.close_rounded,
              color: AppColors.textSecondary, size: 20),
        );
      case ExportStatus.processing:
        return IconButton(
          tooltip: 'إيقاف',
          onPressed: () => queue.cancelCurrent(),
          icon: const Icon(Icons.stop_circle_rounded,
              color: AppColors.danger, size: 22),
        );
      case ExportStatus.done:
      case ExportStatus.failed:
        return const SizedBox(width: 8);
    }
  }
}

class _StatusChip extends StatelessWidget {
  final ExportStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final (String label, Color color) = switch (status) {
      ExportStatus.waiting => ('في الانتظار', AppColors.textSecondary),
      ExportStatus.processing => ('قيد القص', AppColors.accent),
      ExportStatus.done => ('تم', AppColors.accent2),
      ExportStatus.failed => ('فشل', AppColors.danger),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }
}
