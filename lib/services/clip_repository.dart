import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/clip.dart';

/// Manages persistence of saved clips using Hive and notifies listeners.
class ClipRepository extends ChangeNotifier {
  static const String _boxName = 'clips_box';
  late Box<Clip> _box;
  bool _initialized = false;

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
    final list = _box.values.toList();
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

  Future<void> deleteClip(String id) async {
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
    notifyListeners();
  }

  Clip? getById(String id) => _box.get(id);
}
