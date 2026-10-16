import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/view_state.dart';
import 'transfer_widgets.dart';
import 'desktop_layout.dart';

/// Preview never owns a download: leaving this route keeps the model's task alive.
class MediaPreviewPage extends StatefulWidget {
  const MediaPreviewPage({super.key, required this.model, required this.item});
  final TamayuraModel model;
  final MediaView item;

  @override
  State<MediaPreviewPage> createState() => _MediaPreviewPageState();
}

class _MediaPreviewPageState extends State<MediaPreviewPage> {
  final _transform = TransformationController();
  final Set<int> _pointers = {};
  Offset? _dragStart;
  Duration? _dragStartedAt;
  bool _multiplePointers = false;
  bool _zoomed = false;
  bool _closing = false;
  double _drag = 0;
  Uint8List? _fullImage;
  String? _loadedUri;
  String? _previewError;
  bool _loadingPreview = false;
  int _previewGeneration = 0;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransform);
    widget.model.addListener(_onModel);
    _onModel();
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModel);
    _transform.removeListener(_onTransform);
    _transform.dispose();
    _previewGeneration++;
    super.dispose();
  }

  void _onTransform() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.03;
    if (zoomed != _zoomed && mounted) {
      setState(() {
        _zoomed = zoomed;
        if (zoomed) _drag = 0;
      });
    }
  }

  void _onModel() {
    final transfer = widget.model.transfers[widget.item.key];
    final uri = transfer?.savedUri;
    if (!widget.item.isVideo && uri != null && uri != _loadedUri) {
      _loadedUri = uri;
      unawaited(_loadPreview());
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadPreview() async {
    final generation = ++_previewGeneration;
    setState(() {
      _loadingPreview = true;
      _previewError = null;
    });
    try {
      final bytes = await widget.model.loadPreview(widget.item);
      if (!mounted || generation != _previewGeneration) return;
      setState(() {
        // Bound encoded memory as well as decoder dimensions; originals remain
        // available through the system's viewer when too large for this route.
        _fullImage = bytes != null && bytes.length <= 20 * 1024 * 1024
            ? bytes
            : null;
        if (_fullImage == null) {
          _previewError = '原文件已保存，暂无法在应用内预览。可用其他应用打开。';
        }
      });
    } catch (_) {
      if (!mounted || generation != _previewGeneration) return;
      setState(() => _previewError = '原文件预览读取失败，可重试或用其他应用打开。');
    } finally {
      if (mounted && generation == _previewGeneration) {
        setState(() => _loadingPreview = false);
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('操作未完成，请检查网络或文件权限后重试。')));
    }
  }

  void _pointerDown(PointerDownEvent event) {
    _pointers.add(event.pointer);
    if (_pointers.length == 1) {
      _dragStart = event.position;
      _dragStartedAt = event.timeStamp;
      _multiplePointers = false;
    } else {
      _multiplePointers = true;
      if (_drag != 0) setState(() => _drag = 0);
    }
  }

  void _pointerMove(PointerMoveEvent event) {
    if (_zoomed ||
        _multiplePointers ||
        _pointers.length != 1 ||
        _dragStart == null) {
      return;
    }
    final delta = event.position - _dragStart!;
    if (delta.dy > 0 && delta.dy > delta.dx.abs() * 1.3) {
      setState(() => _drag = delta.dy);
    }
  }

  void _pointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.isNotEmpty) return;
    final elapsed = _dragStartedAt == null
        ? 0
        : (event.timeStamp - _dragStartedAt!).inMilliseconds;
    final speed = elapsed > 0 ? _drag / elapsed * 1000 : 0;
    final dismiss =
        !_zoomed &&
        !_multiplePointers &&
        (_drag > 110 || (_drag > 55 && speed > 850));
    _dragStart = null;
    if (dismiss && !_closing) {
      _closing = true;
      Navigator.of(context).pop();
    } else if (_drag != 0) {
      setState(() => _drag = 0);
    }
  }

  void _resetGesture(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    _dragStart = null;
    if (_drag != 0) setState(() => _drag = 0);
  }

  void _toggleZoom() {
    // A second tap returns to the initial scale before drag-to-dismiss is enabled.
    if (_zoomed) {
      _transform.value = Matrix4.identity();
    } else {
      _transform.value = Matrix4.diagonal3Values(2, 2, 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const overlay = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarContrastEnforced: false,
    );
    final item = widget.item;
    final transfer = widget.model.transfers[item.key];
    final imageBytes = _fullImage ?? item.thumbnail;
    final image = imageBytes.isEmpty
        ? const Center(
            child: Icon(Icons.image_outlined, color: Colors.white54, size: 64),
          )
        : Image(
            image: ResizeImage(
              MemoryImage(imageBytes),
              width: 2048,
              height: 2048,
              policy: ResizeImagePolicy.fit,
            ),
            key: ValueKey(
              _fullImage == null ? 'cached-preview' : 'full-preview',
            ),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const Center(
              child: Text(
                '无法显示这张预览图，可下载后用其他应用打开。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, height: 1.6),
              ),
            ),
          );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // The safe-area strips share the dark photo canvas in both themes.
      value: overlay,
      child: PopScope<void>(
        // Keeping canPop true lets Android predictive back animate the route.
        canPop: true,
        child: Scaffold(
          key: const Key('media-preview-page'),
          // Keep photos on a neutral dark canvas in either application theme.
          backgroundColor: const Color(0xFF171717),
          appBar: AppBar(
            backgroundColor: const Color(0xFF171717),
            foregroundColor: Colors.white,
            systemOverlayStyle: overlay,
            title: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15),
            ),
            leading: IconButton(
              key: const Key('close-preview'),
              tooltip: '返回相册',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            actions: [
              IconButton(
                key: const Key('preview-zoom'),
                tooltip: _zoomed ? '还原缩放' : '放大预览',
                onPressed: _toggleZoom,
                icon: Icon(
                  _zoomed ? Icons.zoom_out_rounded : Icons.zoom_in_rounded,
                ),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                Expanded(
                  child: Listener(
                    key: const Key('preview-gesture-area'),
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _pointerDown,
                    onPointerMove: _pointerMove,
                    onPointerUp: _pointerUp,
                    onPointerCancel: _resetGesture,
                    child: AnimatedContainer(
                      duration: _drag == 0
                          ? const Duration(milliseconds: 180)
                          : Duration.zero,
                      curve: Curves.easeOutCubic,
                      transform: Matrix4.translationValues(0, _drag, 0),
                      child: GestureDetector(
                        onDoubleTap: _toggleZoom,
                        child: InteractiveViewer(
                          key: const Key('preview-zoom-view'),
                          transformationController: _transform,
                          minScale: 1,
                          maxScale: 5,
                          panEnabled: _zoomed,
                          child: Hero(
                            tag: 'media-${item.key}',
                            transitionOnUserGestures: true,
                            child: SizedBox.expand(child: image),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                  child: Row(
                    children: [
                      Icon(
                        _fullImage != null
                            ? Icons.high_quality_outlined
                            : Icons.photo_outlined,
                        size: 16,
                        color: Colors.white70,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          item.isVideo
                              ? '视频缩略图 · 下载后可用系统播放器打开'
                              : _loadingPreview
                              ? '正在读取本机原图…'
                              : _fullImage != null
                              ? isDesktop
                                    ? '本机原图 · 双击或滚轮缩放'
                                    : '本机原图 · 双指缩放'
                              : '缓存缩略图 · 下载完成后显示原图',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _zoomed
                            ? '双击还原'
                            : isDesktop
                            ? '双击放大'
                            : '下滑返回',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * .44,
                  ),
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerLow,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(24),
                      ),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_previewError != null) ...[
                            Text(
                              _previewError!,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            TextButton(
                              onPressed: _loadingPreview ? null : _loadPreview,
                              child: const Text('重新读取预览'),
                            ),
                          ],
                          TransferControls(
                            item: item,
                            transfer: transfer,
                            onDownload: () =>
                                _run(() => widget.model.download(item)),
                            onCancel: () => _run(
                              () => widget.model.cancelDownload(item.key),
                            ),
                            onShare: () => _run(() => widget.model.share(item)),
                            onOpen: () => _run(() => widget.model.open(item)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
