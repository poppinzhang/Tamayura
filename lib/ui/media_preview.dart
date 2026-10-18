import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/view_state.dart';
import '../l10n/app_locale.dart';
import 'transfer_widgets.dart';
import 'desktop_layout.dart';

/// Why the saved original is not shown; worded when the page is built.
enum _PreviewProblem { unavailable, readFailed }

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
  _PreviewProblem? _previewProblem;
  bool _loadingPreview = false;
  int _previewGeneration = 0;
  bool _deletingLocal = false;

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
    if (uri == null && _loadedUri != null) {
      _previewGeneration++;
      _loadedUri = null;
      _fullImage = null;
      _previewProblem = null;
      _loadingPreview = false;
    }
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
      _previewProblem = null;
    });
    try {
      final bytes = await widget.model.loadPreview(
        widget.item,
        isCurrent: () => mounted && generation == _previewGeneration,
      );
      if (!mounted || generation != _previewGeneration) return;
      setState(() {
        // Bound encoded memory as well as decoder dimensions; originals remain
        // available through the system's viewer when too large for this route.
        _fullImage = bytes != null && bytes.length <= 20 * 1024 * 1024
            ? bytes
            : null;
        if (_fullImage == null) {
          _previewProblem = _PreviewProblem.unavailable;
        }
      });
    } catch (_) {
      if (!mounted || generation != _previewGeneration) return;
      setState(() => _previewProblem = _PreviewProblem.readFailed);
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
      ).showSnackBar(SnackBar(content: Text(context.l10n.previewActionFailed)));
    }
  }

  Future<void> _deleteLocalFile() async {
    if (_deletingLocal) return;
    setState(() => _deletingLocal = true);
    var deleted = false;
    try {
      deleted = await widget.model.deleteLocalFile(widget.item);
    } catch (_) {
      // Keep the preview and saved controls available for a retry.
    }
    if (!mounted) return;
    setState(() => _deletingLocal = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          deleted
              ? context.l10n.previewLocalDeleted
              : widget.model.error ?? context.l10n.previewLocalDeleteFailed,
        ),
      ),
    );
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

  DeviceView? get _sourceDevice {
    for (final device in widget.model.devices) {
      if (device.id == widget.item.deviceId) return device;
    }
    return null;
  }

  void _showDetails() {
    final item = widget.item;
    final device = _sourceDevice;
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        final l10n = context.l10n;
        return FractionallySizedBox(
          heightFactor: .75,
          child: SafeArea(
            top: false,
            child: Column(
              key: const Key('media-details-sheet'),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.previewDetails,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        key: const Key('close-media-details'),
                        tooltip: l10n.previewCloseDetails,
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    key: const Key('media-details-scroll'),
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _MediaDetail(
                          label: l10n.detailFileName,
                          value: item.name,
                        ),
                        _MediaDetail(
                          label: l10n.detailSourceDevice,
                          value: device?.name ?? l10n.rememberedDeviceFallback,
                        ),
                        _MediaDetail(
                          label: l10n.detailDeviceStatus,
                          value: device == null
                              ? l10n.detailDeviceUnknown
                              : device.online
                              ? l10n.commonOnline
                              : l10n.commonOffline,
                        ),
                        _MediaDetail(
                          label: l10n.detailModified,
                          value: _formatModified(
                            item.modified,
                            includeTime: true,
                          ),
                        ),
                        _MediaDetail(
                          label: l10n.detailType,
                          value:
                              '${item.isVideo ? l10n.commonVideo : l10n.commonImage}${item.mimeType.isEmpty ? '' : ' · ${item.mimeType}'}',
                        ),
                        _MediaDetail(
                          label: l10n.detailSize,
                          value: l10n.detailSizeValue(
                            formatMediaBytes(item.size),
                            item.size,
                          ),
                        ),
                        if (item.sharedFolderName.isNotEmpty)
                          _MediaDetail(
                            label: l10n.detailCollection,
                            value: item.sharedFolderName,
                          ),
                        if (item.relativePath.isNotEmpty)
                          _MediaDetail(
                            label: l10n.detailRelativePath,
                            value: item.relativePath,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
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
            errorBuilder: (context, _, _) => Center(
              child: Text(
                context.l10n.previewImageError,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, height: 1.6),
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
              tooltip: context.l10n.previewBack,
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            actions: [
              IconButton(
                key: const Key('preview-details'),
                tooltip: context.l10n.previewDetails,
                onPressed: _showDetails,
                icon: const Icon(Icons.info_outline_rounded),
              ),
              if (transfer?.complete == true)
                IconButton(
                  key: const Key('preview-delete-local'),
                  tooltip: context.l10n.previewDeleteLocal,
                  onPressed: _deletingLocal ? null : _deleteLocalFile,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              IconButton(
                key: const Key('preview-zoom'),
                tooltip: _zoomed
                    ? context.l10n.previewZoomReset
                    : context.l10n.previewZoomIn,
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
                              ? context.l10n.previewVideoHint
                              : _loadingPreview
                              ? context.l10n.previewReadingOriginal
                              : _fullImage != null
                              ? isDesktop
                                    ? context.l10n.previewOriginalDesktop
                                    : context.l10n.previewOriginalMobile
                              : context.l10n.previewCachedThumbnail,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _zoomed
                            ? isDesktop
                                  ? context.l10n.previewResetDesktop
                                  : context.l10n.previewResetMobile
                            : isDesktop
                            ? context.l10n.previewZoomDesktop
                            : context.l10n.previewSwipeDown,
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
                          Text(
                            context.l10n.previewSource(
                              _sourceDevice?.name ??
                                  context.l10n.rememberedDeviceFallback,
                            ),
                            key: const Key('preview-source'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_formatModified(item.modified)} · ${formatMediaBytes(item.size)} · ${item.isVideo ? context.l10n.commonVideo : context.l10n.commonImage}',
                            key: const Key('preview-metadata'),
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 14),
                          if (_previewProblem != null) ...[
                            Text(
                              switch (_previewProblem!) {
                                _PreviewProblem.unavailable =>
                                  context.l10n.previewUnavailable,
                                _PreviewProblem.readFailed =>
                                  context.l10n.previewReadFailed,
                              },
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            TextButton(
                              onPressed: _loadingPreview ? null : _loadPreview,
                              child: Text(context.l10n.previewRetry),
                            ),
                          ],
                          AbsorbPointer(
                            absorbing: _deletingLocal,
                            child: TransferControls(
                              item: item,
                              transfer: transfer,
                              onDownload: () =>
                                  _run(() => widget.model.download(item)),
                              onCancel: () => _run(
                                () => widget.model.cancelDownload(item.key),
                              ),
                              onDiscard: () => _run(
                                () => widget.model.discardDownload(item.key),
                              ),
                              onShare: () =>
                                  _run(() => widget.model.share(item)),
                              onOpen: () => _run(() => widget.model.open(item)),
                            ),
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

String _formatModified(DateTime value, {bool includeTime = false}) {
  final local = value.toLocal();
  String twoDigits(int part) => part.toString().padLeft(2, '0');
  final date =
      '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)}';
  return includeTime
      ? '$date ${twoDigits(local.hour)}:${twoDigits(local.minute)}:${twoDigits(local.second)}'
      : date;
}

class _MediaDetail extends StatelessWidget {
  const _MediaDetail({required this.label, required this.value});

  final String label, value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(value, style: theme.textTheme.bodyLarge),
        ],
      ),
    );
  }
}
