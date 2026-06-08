import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/clip.dart';

/// Manages persistence of saved clips using Hive and notifies listeners.
class ClipRepository extends ChangeNotifier {
  static const String _boxName = 'clips_box';
  late Box<Clip> _box;
  bool _initialized = false;

  /// Clips that are scheduled for deletion but can still be undone.
  /// They are hidden from [clips] while pending.
  final Set<String> _pendingDelete = {};
  final Map<String, Timer> _deleteTimers = {};

  bool get initialized => _initialized;

  Future<void> init() async {
    if (_initialized) return;
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(ClipAdapter());
    }
    _box = await Hive.openBox<Clip>(_boxName);
    _initialized = true;
    notifyListeners();
  }

  List<Clip> get clips {
    final list = _box.values
        .where((c) => !_pendingDelete.contains(c.id))
        .toList();
    list.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    return list;
  }

  Future<void> addClip(Clip clip) async {
    await _box.put(clip.id, clip);
    notifyListeners();
  }

  Future<void> renameClip(String id, String newName) async {
    final clip = _box.get(id);
    if (clip == null) return;
    clip.name = newName;
    await clip.save();
    notifyListeners();
  }

  /// Hides the clip immediately and commits the real deletion after [delay].
  /// Call [undoDelete] before the timer fires to restore it.
  void scheduleDelete(String id, {Duration delay = const Duration(seconds: 5)}) {
    if (_box.get(id) == null) return;
    _deleteTimers[id]?.cancel();
    _pendingDelete.add(id);
    _deleteTimers[id] = Timer(delay, () => _commitDelete(id));
    notifyListeners();
  }

  /// Cancels a pending deletion and brings the clip back into the list.
  void undoDelete(String id) {
    if (!_pendingDelete.contains(id)) return;
    _deleteTimers.remove(id)?.cancel();
    _pendingDelete.remove(id);
    notifyListeners();
  }

  Future<void> _commitDelete(String id) async {
    _deleteTimers.remove(id);
    _pendingDelete.remove(id);
    await deleteClip(id);
  }

  Future<void> deleteClip(String id) async {
    await _deleteFilesAndEntry(id, notify: true);
  }

  /// Deletes several clips at once (files + thumbnails + entries), then a single
  /// UI update. Missing files are ignored so a stale path never crashes.
  Future<void> deleteClips(List<String> ids) async {
    for (final id in ids) {
      await _deleteFilesAndEntry(id, notify: false);
    }
    notifyListeners();
  }

  Future<void> _deleteFilesAndEntry(String id, {required bool notify}) async {
    final clip = _box.get(id);
    if (clip == null) return;
    // Best-effort delete of the underlying files.
    try {
      final f = File(clip.filePath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    try {
      if (clip.thumbnailPath.isNotEmpty) {
        final t = File(clip.thumbnailPath);
        if (await t.exists()) await t.delete();
      }
    } catch (_) {}
    await _box.delete(id);
    if (notify) notifyListeners();
  }

  /// Flags a clip as exported to the device gallery.
  Future<void> markSavedToGallery(String id) async {
    final clip = _box.get(id);
    if (clip == null || clip.savedToGallery) return;
    clip.savedToGallery = true;
    await clip.save();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final t in _deleteTimers.values) {
      t.cancel();
    }
    _deleteTimers.clear();
    super.dispose();
  }

  Clip? getById(String id) => _box.get(id);
}
