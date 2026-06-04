import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/permission_service.dart';
import '../utils/app_theme.dart';
import 'player_screen.dart';
import 'my_clips_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  Future<void> _pickVideo() async {
    final granted = await PermissionService.requestVideoAccess();
    if (!mounted) return;
    if (!granted) {
      _showSnack('يلزم إذن الوصول إلى الفيديو لاختيار مقطع.');
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );
    if (!mounted) return;
    if (result == null || result.files.single.path == null) return;

    final file = result.files.single;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            PlayerScreen(videoPath: file.path!, videoName: file.name),
      ),
    );
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final pages = [_PickerTab(onPick: _pickVideo), const MyClipsScreen()];

    return Scaffold(
      body: SafeArea(child: pages[_index]),
      floatingActionButton: _index == 0
          ? FloatingActionButton.extended(
              onPressed: _pickVideo,
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.black,
              icon: const Icon(Icons.video_library_rounded),
              label: const Text(
                'اختيار فيديو',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            )
          : null,
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
  final VoidCallback onPick;
  const _PickerTab({required this.onPick});

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
                    'اقتطع لحظاتك المفضّلة',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'اختر فيديو من جهازك، شغّله، حدّد البداية والنهاية، ثم احفظ '
                    'المقطع — كل ذلك دون اتصال بالإنترنت تماماً.',
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
                      onPressed: onPick,
                      icon: const Icon(Icons.folder_open_rounded),
                      label: const Text('اختر فيديو من الجهاز'),
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
