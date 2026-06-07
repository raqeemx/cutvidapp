import 'dart:convert';
import 'dart:io';

import 'package:hive_flutter/hive_flutter.dart';

/// Outcome of resolving the remote link.
class RemoteLinkResult {
  /// The website URL to open, or null when none is configured.
  final String? url;

  /// True when [url] came from the local cache (network/parse failed).
  final bool fromCache;

  /// True when the network request itself failed (offline, timeout…).
  final bool networkError;

  const RemoteLinkResult({
    this.url,
    this.fromCache = false,
    this.networkError = false,
  });

  bool get hasUrl => url != null && url!.isNotEmpty;
}

/// Fetches a single, remotely-controlled website URL from a hosted JSON file,
/// so it can be changed without shipping an app update.
///
/// Fully isolated from the offline editing features — any failure here never
/// affects cutting/playback.
class RemoteLinkService {
  /// The remote JSON source. Change this constant to point elsewhere.
  static const String jsonUrl =
      'https://raw.githubusercontent.com/raqeemx/Trimx.link/refs/heads/main/links.json';

  static const String _boxName = 'settings';
  static const String _cacheKey = 'discover_last_url';

  /// Fetches and parses the link, falling back to the last cached URL on error.
  static Future<RemoteLinkResult> fetch() async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12);
      // A cache-buster reduces (not eliminates) GitHub raw CDN staleness.
      final uri = Uri.parse(jsonUrl).replace(queryParameters: {
        'cb': DateTime.now().millisecondsSinceEpoch.toString(),
      });
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(
            const Duration(seconds: 15),
          );

      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final url = _extractUrl(body);
        client.close();
        if (url != null && url.isNotEmpty) {
          await _cache(url);
          return RemoteLinkResult(url: url);
        }
        // Reachable but no URL configured → friendly empty state.
        return const RemoteLinkResult(url: null);
      }
      client.close();
      return _cachedOr(networkError: false);
    } catch (_) {
      // Offline / timeout / DNS → use cache if we have it.
      return _cachedOr(networkError: true);
    }
  }

  /// Parses the URL out of the JSON body flexibly.
  static String? _extractUrl(String body) {
    try {
      final data = jsonDecode(body);
      if (data is String) return _normalize(data);
      if (data is Map) {
        for (final key in const ['url', 'link', 'website', 'site']) {
          final v = data[key];
          if (v is String && v.trim().isNotEmpty) return _normalize(v);
        }
      }
      if (data is List && data.isNotEmpty) {
        final first = data.first;
        if (first is String) return _normalize(first);
        if (first is Map) {
          final v = first['url'] ?? first['link'];
          if (v is String) return _normalize(v);
        }
      }
    } catch (_) {
      // Not valid JSON — ignore.
    }
    return null;
  }

  static String? _normalize(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'https://$s';
    }
    return s;
  }

  static Future<Box> _box() async {
    if (Hive.isBoxOpen(_boxName)) return Hive.box(_boxName);
    return Hive.openBox(_boxName);
  }

  static Future<void> _cache(String url) async {
    final box = await _box();
    await box.put(_cacheKey, url);
  }

  static Future<RemoteLinkResult> _cachedOr({required bool networkError}) async {
    final box = await _box();
    final cached = box.get(_cacheKey);
    if (cached is String && cached.isNotEmpty) {
      return RemoteLinkResult(
        url: cached,
        fromCache: true,
        networkError: networkError,
      );
    }
    return RemoteLinkResult(networkError: networkError);
  }
}
