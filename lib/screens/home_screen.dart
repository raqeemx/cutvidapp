import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/permission_service.dart';
import '../utils/app_theme.dart';
import 'player_screen.dart';
import 'my_clips_screen.dart';
import 'merge_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  Future<void> _pickMedia({required bool audio}) async {
    final granted = audio
        ? await PermissionService.requestAudioAccess()
        : await PermissionService.requestVideoAccess();
    if (!mounted) return;
    if (!granted) {
      _showSnack(
        audio
            ? 'يلزم إذن الوصول إلى الصوت لاختيار ملف.'
            : 'يلزم إذن الوصول إلى الفيديو لاختيار مقطع.',
      );
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: audio ? FileType.audio : FileType.video,
      allowMultiple: false,
    );
    if (!mounted) return;
    if (result == null || result.files.single.path == null) return;

    final file = result.files.single;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          videoPath: file.path!,
          videoName: file.name,
          isAudio: audio,
        ),
      ),
    );
  }

  /// Lets the user choose whether to open a video or an audio file.
  Future<void> _showPickSheet() async {
    final choice = await showModalBottomSheet<bool>(
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
              leading: const Icon(
                Icons.movie_creation_rounded,
                color: AppColors.accent,
              ),
              title: const Text(
                'اختيار فيديو',
                style: TextStyle(color: AppColors.textPrimary),
              ),
              onTap: () => Navigator.pop(ctx, false),
            ),
            ListTile(
              leading: const Icon(
                Icons.audiotrack_rounded,
                color: AppColors.accent2,
              ),
              title: const Text(
                'اختيار ملف صوتي',
                style: TextStyle(color: AppColors.textPrimary),
              ),
              onTap: () => Navigator.pop(ctx, true),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null) return;
    await _pickMedia(audio: choice);
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _PickerTab(
        onPickVideo: () => _pickMedia(audio: false),
        onPickAudio: () => _pickMedia(audio: true),
      ),
      const MyClipsScreen(),
    ];

    return Scaffold(
      body: SafeArea(child: pages[_index]),
      floatingActionButton: _index == 0
          ? FloatingActionButton.extended(
              onPressed: _showPickSheet,
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.black,
              icon: const Icon(Icons.add_rounded),
              label: const Text(
                'فتح ملف',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            )
          : FloatingActionButton.extended(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MergeScreen()),
              ),
              backgroundColor: AppColors.accent2,
              foregroundColor: Colors.black,
              icon: const Icon(Icons.merge_rounded),
              label: const Text(
                'دمج مقاطع',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.movie_creation_outlined),
            activeIcon: Icon(Icons.movie_creation_rounded),
            label: 'الفيديوهات',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.collections_bookmark_outlined),
            activeIcon: Icon(Icons.collections_bookmark_rounded),
            label: 'مقاطعي',
          ),
        ],
      ),
    );
  }
}

class _PickerTab extends StatelessWidget {
  final VoidCallback onPickVideo;
  final VoidCallback onPickAudio;
  const _PickerTab({required this.onPickVideo, required this.onPickAudio});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 8),
        const _AppHeader(),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 130,
                    height: 130,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppColors.accent, Color(0xFFFFB877)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(36),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.accent.withValues(alpha: 0.35),
                          blurRadius: 30,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.content_cut_rounded,
                      size: 64,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 28),
                  const Text(
                    'اقصص أفضل لحظاتك',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'اختر فيديو أو ملفاً صوتياً من جهازك، شغّله، حدّد البداية '
                    'والنهاية، واحفظ المقطع — كل شيء يعمل بدون إنترنت ودون رفع '
                    'أي ملف.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: onPickVideo,
                      icon: const Icon(Icons.movie_creation_rounded),
                      label: const Text('اختر فيديو من جهازك'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: onPickAudio,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.accent2,
                        side: const BorderSide(color: AppColors.accent2),
                      ),
                      icon: const Icon(Icons.audiotrack_rounded),
                      label: const Text('اختر ملفاً صوتياً'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const _OfflineBadge(),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AppHeader extends StatelessWidget {
  const _AppHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Row(
        children: [
          const Icon(Icons.content_cut_rounded, color: AppColors.accent),
          const SizedBox(width: 10),
          const Text(
            'قص الفيديو',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

class _OfflineBadge extends StatelessWidget {
  const _OfflineBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.accent2.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.wifi_off_rounded, size: 16, color: AppColors.accent2),
          SizedBox(width: 8),
          Text(
            'يعمل دون اتصال تماماً · بلا رفع للملفات',
            style: TextStyle(
              color: AppColors.accent2,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
