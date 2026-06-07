import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/remote_link_service.dart';
import '../utils/app_theme.dart';

/// A side "Discover" section that opens a single, remotely-controlled website
/// straight inside a full-screen WebView. The URL is fetched from a hosted JSON
/// file so it can change weekly without an app update.
///
/// Completely isolated from the offline editing features: any failure here is
/// contained to this screen and never affects cutting/playback.
class WebScreen extends StatefulWidget {
  const WebScreen({super.key});

  @override
  State<WebScreen> createState() => _WebScreenState();
}

class _WebScreenState extends State<WebScreen> {
  WebViewController? _controller;

  bool _loadingLink = true; // resolving the remote URL
  bool _networkError = false; // fetch failed and no cached URL
  String? _url; // resolved website URL

  bool _pageLoading = false; // webview is loading a page
  bool _pageError = false; // webview failed to load the page
  bool _canGoBack = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    setState(() {
      _loadingLink = true;
      _networkError = false;
      _pageError = false;
    });
    final res = await RemoteLinkService.fetch();
    if (!mounted) return;
    if (!res.hasUrl) {
      setState(() {
        _loadingLink = false;
        _url = null;
        _networkError = res.networkError;
      });
      return;
    }
    _buildController(res.url!);
    setState(() {
      _url = res.url;
      _loadingLink = false;
    });
  }

  void _buildController(String url) {
    _pageError = false;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppColors.background)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _pageLoading = true);
          },
          onPageFinished: (_) async {
            final back = await _controller?.canGoBack() ?? false;
            if (mounted) {
              setState(() {
                _pageLoading = false;
                _canGoBack = back;
              });
            }
          },
          onWebResourceError: (error) {
            // Only the main frame failing should show the error UI; sub-resource
            // errors (ads, trackers blocked by the site) are ignored.
            if (error.isForMainFrame ?? true) {
              if (mounted) {
                setState(() {
                  _pageError = true;
                  _pageLoading = false;
                });
              }
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(url));
  }

  Future<void> _openExternal() async {
    final url = _url;
    if (url == null) return;
    final uri = Uri.parse(url);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) _snack('تعذّر فتح المتصفّح.');
    } catch (_) {
      if (mounted) _snack('تعذّر فتح المتصفّح.');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await (_controller?.canGoBack() ?? Future.value(false))) {
          _controller?.goBack();
        }
      },
      child: Column(
        children: [
          _buildHeader(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
      child: Row(
        children: [
          const Icon(Icons.explore_rounded, color: AppColors.accent),
          const SizedBox(width: 10),
          const Text(
            'اكتشف',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'تحديث',
            onPressed: _loadingLink ? null : _resolve,
            icon: const Icon(Icons.refresh_rounded,
                color: AppColors.textSecondary),
          ),
          if (_url != null)
            IconButton(
              tooltip: 'فتح في المتصفّح',
              onPressed: _openExternal,
              icon: const Icon(Icons.open_in_new_rounded,
                  color: AppColors.textSecondary),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loadingLink) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppColors.accent),
            SizedBox(height: 16),
            Text('جارٍ التحميل…',
                style: TextStyle(color: AppColors.textSecondary)),
          ],
        ),
      );
    }

    if (_url == null) {
      return _networkError
          ? _message(
              icon: Icons.wifi_off_rounded,
              title: 'لا يوجد اتصال بالإنترنت',
              body: 'تعذّر تحميل المحتوى. تحقّق من اتصالك ثم أعد المحاولة.',
              actionLabel: 'إعادة المحاولة',
              onAction: _resolve,
            )
          : _message(
              icon: Icons.inbox_rounded,
              title: 'لا يوجد محتوى حالياً',
              body: 'لم يتم إعداد أي رابط بعد. تحقّق لاحقاً.',
              actionLabel: 'تحديث',
              onAction: _resolve,
            );
    }

    return Stack(
      children: [
        Positioned.fill(child: WebViewWidget(controller: _controller!)),
        if (_pageLoading && !_pageError)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              minHeight: 3,
              backgroundColor: AppColors.surfaceLight,
              color: AppColors.accent,
            ),
          ),
        if (_pageError)
          Positioned.fill(
            child: Container(
              color: AppColors.background,
              child: _message(
                icon: Icons.public_off_rounded,
                title: 'تعذّر عرض الموقع',
                body: 'قد لا يسمح هذا الموقع بالعرض داخل التطبيق. '
                    'يمكنك فتحه في المتصفّح الخارجي.',
                actionLabel: 'فتح في المتصفّح',
                onAction: _openExternal,
                secondaryLabel: 'إعادة المحاولة',
                onSecondary: () {
                  if (_url != null) {
                    setState(() => _pageError = false);
                    _controller?.loadRequest(Uri.parse(_url!));
                  }
                },
              ),
            ),
          ),
      ],
    );
  }

  Widget _message({
    required IconData icon,
    required String title,
    required String body,
    required String actionLabel,
    required VoidCallback onAction,
    String? secondaryLabel,
    VoidCallback? onSecondary,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 56, color: AppColors.surfaceLight),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textSecondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(onPressed: onAction, child: Text(actionLabel)),
            if (secondaryLabel != null && onSecondary != null) ...[
              const SizedBox(height: 8),
              TextButton(onPressed: onSecondary, child: Text(secondaryLabel)),
            ],
          ],
        ),
      ),
    );
  }
}
