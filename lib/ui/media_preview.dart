import 'dart:async';

import 'package:animations/animations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:material_ui/material_ui.dart';

import '../app/view_state.dart';
import '../l10n/app_locale.dart';
import 'app_icons.dart';
import 'app_motion.dart';
import 'transfer_widgets.dart';
import 'desktop_layout.dart';
import 'media_preview_sequence.dart';

export 'media_preview_sequence.dart';

/// Why the saved original is not shown; worded when the page is built.
enum _PreviewProblem { unavailable, readFailed }

/// Preview never owns a download: leaving this route keeps the model's task alive.
class MediaPreviewPage extends StatefulWidget {
  const MediaPreviewPage({
    super.key,
    required this.model,
    required this.item,
    this.sequence,
  });
  final TamayuraModel model;
  final MediaView item;
  final MediaPreviewSequence? sequence;

  @override
  State<MediaPreviewPage> createState() => _MediaPreviewPageState();
}

class _MediaPreviewPageState extends State<MediaPreviewPage>
    with SingleTickerProviderStateMixin {
  static const _returnDuration = Duration(milliseconds: 180);
  static const _returnCurve = Curves.easeOutCubic;
  final _transform = TransformationController();
  late final MediaPreviewSequence _sequence;
  late MediaView _item;
  late int _index;
  late int _targetIndex;
  int _navigationGeneration = 0;
  bool _navigating = false;
  bool _reverse = false;
  int _quarterTurns = 0;
  final Set<String> _startingDownloads = {};
  Axis? _gestureAxis;
  double _horizontalDrag = 0;
  double _horizontalInitialOffset = 0;
  double _horizontalReturnFrom = 0;
  late final AnimationController _returnController;
  final Set<int> _pointers = {};
  Offset? _dragStart;
  Duration? _dragStartedAt;
  bool _multiplePointers = false;
  bool _zoomed = false;
  bool _closing = false;
  double _drag = 0;
  double _dragInitialOffset = 0;
  double _returnFrom = 0;
  Uint8List? _fullImage;
  String? _loadedUri;
  _PreviewProblem? _previewProblem;
  bool _loadingPreview = false;
  int _previewGeneration = 0;
  bool _deletingLocal = false;

  @override
  void initState() {
    super.initState();
    _item = widget.item;
    final sequence = widget.sequence;
    _sequence = sequence != null && sequence.indexOf(_item) >= 0
        ? sequence
        : MediaPreviewSequence.items([_item]);
    _index = _sequence.indexOf(_item);
    _targetIndex = _index;
    _returnController = AnimationController(
      vsync: this,
      duration: _returnDuration,
      value: 1,
    );
    _transform.addListener(_onTransform);
    widget.model.addListener(_onModel);
    _onModel();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduce(context)) _returnController.value = 1;
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModel);
    _transform.removeListener(_onTransform);
    _transform.dispose();
    _returnController.dispose();
    _previewGeneration++;
    _navigationGeneration++;
    super.dispose();
  }

  void _onTransform() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.03;
    if (zoomed != _zoomed && mounted) {
      setState(() => _zoomed = zoomed);
      if (zoomed) _returnToOrigin();
    }
  }

  void _onModel() {
    if (_closing) return;
    final transfer = widget.model.transfers[_item.key];
    final uri = transfer?.savedUri;
    if (uri == null && _loadedUri != null) {
      _previewGeneration++;
      _loadedUri = null;
      _fullImage = null;
      _previewProblem = null;
      _loadingPreview = false;
    }
    if (!_item.isVideo && uri != null && uri != _loadedUri) {
      _loadedUri = uri;
      unawaited(_loadPreview());
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadPreview() async {
    final generation = ++_previewGeneration;
    final item = _item;
    setState(() {
      _loadingPreview = true;
      _previewProblem = null;
    });
    try {
      final bytes = await widget.model.loadPreview(
        item,
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
      deleted = await widget.model.deleteLocalFile(_item);
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

  bool _canNavigate(int direction) {
    final next = _targetIndex + direction;
    return !_closing && !_deletingLocal && next >= 0 && next < _sequence.length;
  }

  Future<void> _navigate(int direction) async {
    if (!_canNavigate(direction)) {
      _returnToOrigin();
      return;
    }
    final target = _targetIndex + direction;
    final generation = ++_navigationGeneration;
    setState(() {
      _targetIndex = target;
      _navigating = true;
    });
    try {
      final item = await _sequence.resolve(widget.model, target);
      if (!mounted || generation != _navigationGeneration) return;
      if (item == null) throw StateError('Preview media unavailable');
      _previewGeneration++;
      _transform.value = Matrix4.identity();
      _returnController.value = 1;
      setState(() {
        _reverse = target < _index;
        _index = target;
        _item = item;
        _quarterTurns = 0;
        _loadedUri = null;
        _fullImage = null;
        _previewProblem = null;
        _loadingPreview = false;
        _navigating = false;
        _drag = _horizontalDrag = 0;
        _returnFrom = _horizontalReturnFrom = 0;
      });
      _onModel();
      unawaited(_downloadOnVisit(item));
    } catch (_) {
      if (!mounted || generation != _navigationGeneration) return;
      setState(() {
        _targetIndex = _index;
        _navigating = false;
      });
      _returnToOrigin();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.previewActionFailed)));
    }
  }

  Future<void> _downloadOnVisit(MediaView item) async {
    final transfer = widget.model.transfers[item.key];
    if (transfer?.complete == true ||
        transfer?.running == true ||
        !_startingDownloads.add(item.key)) {
      return;
    }
    try {
      final previousError = widget.model.error;
      await _run(() => widget.model.download(item));
      if (!mounted || _item.key != item.key) return;
      final error = widget.model.error;
      final current = widget.model.transfers[item.key];
      // Scheduling can fail before a transfer exists. The controller reports
      // those errors on the model instead of throwing or creating a task row.
      if (error != null &&
          error != previousError &&
          current?.running != true &&
          current?.complete != true &&
          current?.error == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error)));
      }
    } finally {
      _startingDownloads.remove(item.key);
    }
  }

  void _rotate(int direction) {
    _transform.value = Matrix4.identity();
    _returnToOrigin();
    setState(() => _quarterTurns = (_quarterTurns + direction) % 4);
  }

  void _pointerDown(PointerDownEvent event) {
    _pointers.add(event.pointer);
    if (_pointers.length == 1) {
      // A new gesture takes over at the current painted position, including
      // when the previous gesture is still returning to the origin.
      final offset = _dragOffset;
      final horizontalOffset = _horizontalOffset;
      _returnController.value = 1;
      setState(() {
        _drag = offset;
        _returnFrom = 0;
        _horizontalDrag = horizontalOffset;
        _horizontalReturnFrom = 0;
      });
      _dragInitialOffset = offset;
      _horizontalInitialOffset = horizontalOffset;
      _dragStart = event.position - Offset(horizontalOffset, offset);
      _dragStartedAt = event.timeStamp;
      _multiplePointers = false;
      _gestureAxis = null;
    } else {
      _multiplePointers = true;
      _returnToOrigin();
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
    final movement =
        delta - Offset(_horizontalInitialOffset, _dragInitialOffset);
    if (_gestureAxis == null) {
      // A return interrupted by a new pointer contributes a painted offset,
      // but must not choose the axis of the new gesture.
      if (movement.dx.abs() > 12 &&
          movement.dx.abs() > movement.dy.abs() * 1.3) {
        _gestureAxis = Axis.horizontal;
        _returnFrom = _drag;
        _drag = 0;
      } else if (movement.dy > 12 && movement.dy > movement.dx.abs() * 1.3) {
        _gestureAxis = Axis.vertical;
        _horizontalReturnFrom = _horizontalDrag;
        _horizontalDrag = 0;
      }
      if (_gestureAxis != null &&
          (_returnFrom != 0 || _horizontalReturnFrom != 0) &&
          !AppMotion.reduce(context)) {
        _returnController.forward(from: 0);
      }
    }
    if (_gestureAxis == Axis.horizontal && _sequence.length > 1) {
      final direction = movement.dx < 0 ? 1 : -1;
      setState(() {
        _horizontalDrag =
            _horizontalInitialOffset +
            movement.dx * (_canNavigate(direction) ? 1 : .2);
      });
    } else if (_gestureAxis == Axis.vertical) {
      setState(() => _drag = delta.dy.clamp(0, double.infinity));
    }
  }

  void _pointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.isNotEmpty) return;
    final elapsed = _dragStartedAt == null
        ? 0
        : (event.timeStamp - _dragStartedAt!).inMilliseconds;
    // The inherited return offset is visual continuity, not movement made by
    // this pointer. A tap that interrupts the return must not dismiss it.
    final distance = _drag - _dragInitialOffset;
    final speed = elapsed > 0 ? distance / elapsed * 1000 : 0;
    final horizontalDistance = _dragStart == null
        ? 0.0
        : event.position.dx - _dragStart!.dx - _horizontalInitialOffset;
    final horizontalSpeed = elapsed > 0
        ? horizontalDistance.abs() / elapsed * 1000
        : 0;
    final navigate =
        !_zoomed &&
        !_multiplePointers &&
        _gestureAxis == Axis.horizontal &&
        (horizontalDistance.abs() >
                (MediaQuery.sizeOf(context).width * .18).clamp(48, 140) ||
            (horizontalDistance.abs() > 30 && horizontalSpeed > 700));
    final dismiss =
        !_zoomed &&
        !_multiplePointers &&
        _gestureAxis != Axis.horizontal &&
        distance > 0 &&
        (_drag > 110 || (_drag > 55 && speed > 850));
    _dragStart = null;
    if (navigate) {
      unawaited(_navigate(horizontalDistance < 0 ? 1 : -1));
    } else if (dismiss && !_closing) {
      _closing = true;
      Navigator.of(context).pop();
    } else {
      _returnToOrigin();
    }
  }

  void _resetGesture(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    _multiplePointers = true;
    _dragStart = null;
    _returnToOrigin();
  }

  double get _dragOffset =>
      _drag +
      _returnFrom * (1 - _returnCurve.transform(_returnController.value));

  double get _horizontalOffset =>
      _horizontalDrag +
      _horizontalReturnFrom *
          (1 - _returnCurve.transform(_returnController.value));

  void _returnToOrigin() {
    final offset = _dragOffset;
    final horizontalOffset = _horizontalOffset;
    if (offset == 0 && horizontalOffset == 0) return;
    setState(() {
      _drag = 0;
      _returnFrom = offset;
      _horizontalDrag = 0;
      _horizontalReturnFrom = horizontalOffset;
    });
    if (AppMotion.reduce(context)) {
      _returnController.value = 1;
    } else {
      _returnController.forward(from: 0);
    }
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
      if (device.id == _item.deviceId) return device;
    }
    return null;
  }

  void _showDetails() {
    final item = _item;
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
                        icon: const Icon(AppIcons.close),
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

  Widget _mediaCanvas(Widget image) => Transform.translate(
    key: ValueKey('preview-item-${_item.key}'),
    offset: Offset(_horizontalDrag, 0),
    child: Animate(
      controller: _returnController,
      autoPlay: false,
      effects: [
        MoveEffect(
          begin: Offset(_horizontalReturnFrom, 0),
          end: Offset.zero,
          duration: _returnDuration,
          curve: _returnCurve,
        ),
      ],
      child: RotatedBox(
        key: const Key('preview-rotation'),
        quarterTurns: _quarterTurns,
        child: SizedBox.expand(child: image),
      ),
    ),
  );

  Widget _previewToolbar() {
    final l10n = context.l10n;
    return IconTheme(
      data: const IconThemeData(color: Colors.white),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_sequence.length > 1) ...[
              IconButton(
                key: const Key('preview-previous'),
                tooltip: l10n.previewPrevious,
                onPressed: _canNavigate(-1) ? () => _navigate(-1) : null,
                icon: const Icon(AppIcons.previous),
              ),
              Flexible(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    l10n.previewPosition(_index + 1, _sequence.length),
                    key: const Key('preview-position'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ),
              IconButton(
                key: const Key('preview-next'),
                tooltip: l10n.previewNext,
                onPressed: _canNavigate(1) ? () => _navigate(1) : null,
                icon: const Icon(AppIcons.next),
              ),
            ],
            if (!_item.isVideo) ...[
              IconButton(
                key: const Key('preview-rotate-counterclockwise'),
                tooltip: l10n.previewRotateCounterclockwise,
                onPressed: () => _rotate(-1),
                icon: const Icon(AppIcons.rotateCounterclockwise),
              ),
              IconButton(
                key: const Key('preview-rotate-clockwise'),
                tooltip: l10n.previewRotateClockwise,
                onPressed: () => _rotate(1),
                icon: const Icon(AppIcons.rotateClockwise),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _previewHints() {
    final l10n = context.l10n;
    final status = _item.isVideo
        ? l10n.previewVideoHint
        : _loadingPreview
        ? l10n.previewReadingOriginal
        : _fullImage != null
        ? isDesktop
              ? l10n.previewOriginalDesktop
              : l10n.previewOriginalMobile
        : l10n.previewCachedThumbnail;
    final hint = _zoomed
        ? isDesktop
              ? l10n.previewResetDesktop
              : l10n.previewResetMobile
        : _sequence.length > 1
        ? l10n.previewSwipeHorizontal
        : isDesktop
        ? l10n.previewZoomDesktop
        : l10n.previewSwipeDown;
    const style = TextStyle(fontSize: 11, color: Colors.white70);
    final statusRow = Row(
      children: [
        Icon(
          _fullImage != null ? AppIcons.original : AppIcons.image,
          size: 16,
          color: Colors.white70,
        ),
        const SizedBox(width: 6),
        Expanded(child: Text(status, style: style)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxWidth <
              560 * MediaQuery.textScalerOf(context).scale(1);
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                statusRow,
                Text(hint, textAlign: TextAlign.right, style: style),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: statusRow),
              const SizedBox(width: 8),
              Flexible(
                child: Text(hint, textAlign: TextAlign.right, style: style),
              ),
            ],
          );
        },
      ),
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
    final item = _item;
    final transfer = widget.model.transfers[item.key];
    final imageBytes = _fullImage ?? item.thumbnail;
    final image = imageBytes.isEmpty
        ? const Center(
            child: Icon(AppIcons.image, color: Colors.white54, size: 64),
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
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) return;
          // The route remains mounted throughout its exit transition. Invalidate
          // lookups now so they cannot start unseen downloads during that time.
          _closing = true;
          _navigationGeneration++;
          _previewGeneration++;
        },
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
              icon: const Icon(AppIcons.back),
            ),
            actions: [
              IconButton(
                key: const Key('preview-details'),
                tooltip: context.l10n.previewDetails,
                onPressed: _showDetails,
                icon: const Icon(AppIcons.info),
              ),
              if (transfer?.complete == true)
                IconButton(
                  key: const Key('preview-delete-local'),
                  tooltip: context.l10n.previewDeleteLocal,
                  onPressed: _deletingLocal || _navigating
                      ? null
                      : _deleteLocalFile,
                  icon: const Icon(AppIcons.delete),
                ),
              IconButton(
                key: const Key('preview-zoom'),
                tooltip: _zoomed
                    ? context.l10n.previewZoomReset
                    : context.l10n.previewZoomIn,
                onPressed: _toggleZoom,
                icon: Icon(_zoomed ? AppIcons.zoomOut : AppIcons.zoomIn),
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
                    child: Transform.translate(
                      offset: Offset(0, _drag),
                      child: Animate(
                        controller: _returnController,
                        autoPlay: false,
                        effects: [
                          MoveEffect(
                            begin: Offset(0, _returnFrom),
                            end: Offset.zero,
                            duration: _returnDuration,
                            curve: _returnCurve,
                          ),
                        ],
                        child: GestureDetector(
                          onDoubleTap: _toggleZoom,
                          child: InteractiveViewer(
                            key: const Key('preview-zoom-view'),
                            transformationController: _transform,
                            minScale: 1,
                            maxScale: 5,
                            panEnabled: _zoomed,
                            child: AppHero(
                              tag: 'media-${item.key}',
                              transitionOnUserGestures: true,
                              child: ClipRect(
                                child: SizedBox.expand(
                                  child: AppMotion.reduce(context)
                                      ? _mediaCanvas(image)
                                      : PageTransitionSwitcher(
                                          duration: const Duration(
                                            milliseconds: 280,
                                          ),
                                          reverse: _reverse,
                                          transitionBuilder:
                                              (
                                                child,
                                                primary,
                                                secondary,
                                              ) => SharedAxisTransition(
                                                animation: primary,
                                                secondaryAnimation: secondary,
                                                transitionType:
                                                    SharedAxisTransitionType
                                                        .horizontal,
                                                fillColor: Colors.transparent,
                                                child: child,
                                              ),
                                          child: _mediaCanvas(image),
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_navigating)
                  const LinearProgressIndicator(
                    key: Key('preview-loading-media'),
                    minHeight: 2,
                  ),
                if (!_item.isVideo || _sequence.length > 1) _previewToolbar(),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * .44,
                  ),
                  child: SingleChildScrollView(
                    key: const Key('preview-information-scroll'),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _previewHints(),
                        Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerLow,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(24),
                            ),
                          ),
                          child: Padding(
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
                                    onPressed: _loadingPreview
                                        ? null
                                        : _loadPreview,
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
                                      () =>
                                          widget.model.cancelDownload(item.key),
                                    ),
                                    onDiscard: () => _run(
                                      () => widget.model.discardDownload(
                                        item.key,
                                      ),
                                    ),
                                    onShare: () =>
                                        _run(() => widget.model.share(item)),
                                    onOpen: () =>
                                        _run(() => widget.model.open(item)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
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
