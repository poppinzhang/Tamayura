import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/view_state.dart';
import 'album_scroll_geometry.dart';

/// An overlay for a single, uniformly laid out album grid. Geometry comes from
/// the sliver's actual layout, so headers, text scaling and rotation are included.
class AlbumFastScroll extends StatefulWidget {
  const AlbumFastScroll({
    super.key,
    required this.controller,
    required this.geometry,
    required this.entries,
    required this.sortOrder,
    required this.identity,
    required this.child,
    this.active = true,
    this.onVisibleRange,
  });

  final ScrollController controller;
  final AlbumScrollGeometry? Function() geometry;
  final List<MediaScrollEntry> entries;
  final MediaSortOrder sortOrder;
  final Object identity;
  final Widget child;
  final bool active;
  final void Function(int first, int last)? onVisibleRange;

  @override
  State<AlbumFastScroll> createState() => _AlbumFastScrollState();
}

class _AlbumFastScrollState extends State<AlbumFastScroll> {
  static const _hold = Duration(seconds: 3);
  static const _fade = Duration(milliseconds: 300);
  static const _thumbHeight = 56.0;
  final _trackKey = GlobalKey();
  Timer? _hideTimer;
  bool _visible = false;
  bool _dragging = false;
  bool _scrolling = false;
  bool _scheduled = false;
  double _dragAnchor = _thumbHeight / 2;
  double _pixels = 0;
  double _viewport = 0;
  double _maxScroll = 0;
  int _center = 0;
  (int, int)? _lastRange;
  List<(int, String)> _sections = [];

  bool get _byDate =>
      widget.sortOrder == MediaSortOrder.dateAscending ||
      widget.sortOrder == MediaSortOrder.dateDescending;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scheduleUpdate);
    _rebuildSections();
    _scheduleUpdate();
  }

  @override
  void didUpdateWidget(AlbumFastScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_scheduleUpdate);
      widget.controller.addListener(_scheduleUpdate);
    }
    if (oldWidget.identity != widget.identity || !widget.active) {
      _hideTimer?.cancel();
      _visible = _dragging = _scrolling = false;
      _lastRange = null;
    }
    if (!identical(oldWidget.entries, widget.entries) ||
        oldWidget.sortOrder != widget.sortOrder) {
      _rebuildSections();
      // A refreshed catalog may replace items at the same visible indices.
      _lastRange = null;
    }
    _scheduleUpdate();
  }

  void _rebuildSections() {
    _sections = [];
    String? previous;
    for (var i = 0; i < widget.entries.length; i++) {
      final entry = widget.entries[i];
      final label = _byDate
          ? albumMonthLabel(entry.modified)
          : albumNameInitial(entry.name);
      if (label != previous) _sections.add((i, label));
      previous = label;
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_scheduleUpdate);
    super.dispose();
  }

  void _updateScrollMetrics(
    ScrollPosition position,
    AlbumScrollGeometry geometry,
  ) {
    final center = geometry
        .centerIndex(position.pixels, position.viewportDimension)
        .clamp(0, widget.entries.length - 1);
    if (_pixels != position.pixels ||
        _viewport != position.viewportDimension ||
        _maxScroll != position.maxScrollExtent ||
        _center != center) {
      setState(() {
        _pixels = position.pixels;
        _viewport = position.viewportDimension;
        _maxScroll = position.maxScrollExtent;
        _center = center;
      });
    }
  }

  void _scheduleUpdate() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !widget.controller.hasClients) return;
      final position = widget.controller.position;
      if (!position.hasContentDimensions) return;
      final geometry = widget.geometry();
      if (geometry == null || widget.entries.isEmpty) return;
      _updateScrollMetrics(position, geometry);
      if (widget.active && widget.onVisibleRange != null) {
        final first = geometry.centerIndex(
          position.pixels - position.viewportDimension,
          0,
        );
        final last = geometry.centerIndex(
          position.pixels + position.viewportDimension * 2,
          0,
        );
        // Cover complete rows, with a viewport of prefetch on either side.
        final paddedFirst = (first ~/ geometry.columns * geometry.columns)
            .clamp(0, widget.entries.length - 1);
        final paddedLast =
            ((last ~/ geometry.columns + 1) * geometry.columns - 1).clamp(
              0,
              widget.entries.length - 1,
            );
        final visibleFirst =
            (geometry.centerIndex(position.pixels, 0) ~/
                    geometry.columns *
                    geometry.columns)
                .clamp(0, widget.entries.length - 1);
        final visibleLast =
            ((geometry.centerIndex(
                                  position.pixels + position.viewportDimension,
                                  0,
                                ) ~/
                                geometry.columns +
                            1) *
                        geometry.columns -
                    1)
                .clamp(0, widget.entries.length - 1);
        // Keep all visible rows on tall tablets; spend only the remaining
        // budget on prefetch. The data layer reads this window in 200-item chunks.
        final budget = math.max(200, visibleLast - visibleFirst + 1);
        final rangeFirst = paddedLast - paddedFirst < budget
            ? paddedFirst
            : (_center - budget ~/ 2)
                  .clamp(
                    math.max(paddedFirst, visibleLast - budget + 1),
                    math.min(visibleFirst, paddedLast - budget + 1),
                  )
                  .toInt();
        final range = (
          rangeFirst,
          math.min(paddedLast, rangeFirst + budget - 1),
        );
        if (range != _lastRange) {
          _lastRange = range;
          widget.onVisibleRange!(range.$1, range.$2);
        }
      }
    });
  }

  void _show() {
    _hideTimer?.cancel();
    if (!_visible && widget.active) setState(() => _visible = true);
  }

  void _hideLater() {
    _hideTimer?.cancel();
    if (_dragging || _scrolling) return;
    _hideTimer = Timer(_hold, () {
      if (mounted) setState(() => _visible = false);
    });
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical ||
        !widget.active) {
      return false;
    }
    if (notification is ScrollStartNotification) {
      _scrolling = true;
      _show();
    } else if (notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      _show();
      _scheduleUpdate();
    } else if (notification is ScrollEndNotification) {
      _scrolling = false;
      _hideLater();
    }
    return false;
  }

  void _dragTo(Offset globalPosition) {
    final box = _trackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !widget.controller.hasClients) return;
    final travel = box.size.height - _thumbHeight;
    if (travel <= 0) return;
    final fraction =
        ((box.globalToLocal(globalPosition).dy - _dragAnchor) / travel).clamp(
          0.0,
          1.0,
        );
    final position = widget.controller.position;
    widget.controller.jumpTo(fraction * position.maxScrollExtent);
    // Input callbacks run before layout: paint the thumb with the grid in the
    // next frame, rather than waiting an extra frame for the metrics callback.
    // Layout corrections and thumbnail window requests still run post-frame.
    final geometry = widget.geometry();
    if (geometry != null && widget.entries.isNotEmpty) {
      _updateScrollMetrics(position, geometry);
    }
    _scheduleUpdate();
  }

  void _endDrag() {
    _dragging = false;
    _scrolling = false;
    _hideLater();
  }

  void _step(int direction) {
    _show();
    final position = widget.controller.position;
    widget.controller.jumpTo(
      (position.pixels + direction * position.viewportDimension).clamp(
        0.0,
        position.maxScrollExtent,
      ),
    );
    _hideLater();
  }

  Widget _pill(BuildContext context, Widget child, {bool prominent = false}) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: prominent
            ? colors.primaryContainer
            : colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(color: colors.shadow.withValues(alpha: .12), blurRadius: 6),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: prominent ? 14 : 9,
          vertical: prominent ? 9 : 4,
        ),
        child: DefaultTextStyle.merge(
          style: TextStyle(
            color: prominent ? colors.onPrimaryContainer : colors.onSurface,
            fontWeight: prominent ? FontWeight.w600 : FontWeight.w500,
          ),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final geometry = widget.geometry();
    final gridHeight = geometry == null || geometry.itemCount == 0
        ? 0.0
        : ((geometry.itemCount - 1) ~/ geometry.columns) * geometry.rowStride +
              geometry.tileExtent;
    final enabled =
        widget.active &&
        widget.entries.length > 1 &&
        _maxScroll > 0 &&
        gridHeight > _viewport;
    final entry = widget.entries.isEmpty
        ? null
        : widget.entries[_center.clamp(0, widget.entries.length - 1)];
    final label = entry == null
        ? ''
        : _byDate
        ? albumMonthLabel(entry.modified)
        : albumNameInitial(entry.name);
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _scheduleUpdate();
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !enabled || !_visible,
                child: AnimatedOpacity(
                  key: const Key('album-fast-scroll-opacity'),
                  opacity: enabled && _visible ? 1 : 0,
                  duration: _fade,
                  child: Stack(
                    children: [
                      if (_byDate && entry != null)
                        Positioned(
                          top: 12,
                          left: 48,
                          right: 48,
                          child: IgnorePointer(
                            child: Center(
                              child: _pill(
                                context,
                                Text(
                                  albumDateLabel(entry.modified),
                                  key: const Key('album-fast-scroll-date'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 14),
                                ),
                                prominent: true,
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        top: 64,
                        bottom: 16,
                        left: 0,
                        right: 0,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final travel = math.max(
                              0.0,
                              constraints.maxHeight - _thumbHeight,
                            );
                            final thumbTop = _maxScroll <= 0
                                ? 0.0
                                : (_pixels / _maxScroll).clamp(0.0, 1.0) *
                                      travel;
                            var previousTop = -60.0;
                            final markers = <Widget>[];
                            for (final section in _sections) {
                              final top = geometry == null || _maxScroll <= 0
                                  ? 0.0
                                  : (geometry.offsetForIndex(
                                                  section.$1,
                                                  _viewport,
                                                ) /
                                                _maxScroll)
                                            .clamp(0.0, 1.0) *
                                        travel;
                              if (top - previousTop < 54 ||
                                  (top - thumbTop).abs() < 45) {
                                continue;
                              }
                              previousTop = top;
                              markers.add(
                                Positioned(
                                  key: ValueKey(('section', section.$1)),
                                  top: top + 14,
                                  right: 48,
                                  child: IgnorePointer(
                                    child: _pill(
                                      context,
                                      Text(
                                        section.$2,
                                        key: Key(
                                          'album-fast-scroll-marker-${section.$1}',
                                        ),
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }
                            return Stack(
                              key: _trackKey,
                              fit: StackFit.expand,
                              children: [
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: SizedBox(
                                      key: const Key('album-fast-scroll-track'),
                                    ),
                                  ),
                                ),
                                ...markers,
                                Positioned(
                                  key: const Key(
                                    'album-fast-scroll-label-slot',
                                  ),
                                  top: thumbTop,
                                  right: 52,
                                  height: _thumbHeight,
                                  child: IgnorePointer(
                                    child: Center(
                                      child: _pill(
                                        context,
                                        Text(
                                          label,
                                          key: const Key(
                                            'album-fast-scroll-label',
                                          ),
                                          style: const TextStyle(fontSize: 16),
                                        ),
                                        prominent: true,
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  // Markers appear/disappear as the thumb moves.
                                  // Keep the entire gesture subtree alive when
                                  // its index among these siblings changes.
                                  key: const Key(
                                    'album-fast-scroll-thumb-slot',
                                  ),
                                  top: thumbTop,
                                  right: 0,
                                  width: 48,
                                  height: _thumbHeight,
                                  child: Semantics(
                                    label: '快速滚动相册，$label',
                                    onIncrease: () => _step(1),
                                    onDecrease: () => _step(-1),
                                    child: GestureDetector(
                                      key: const Key('album-fast-scroll-thumb'),
                                      behavior: HitTestBehavior.opaque,
                                      onVerticalDragDown: (details) {
                                        _dragging = true;
                                        _dragAnchor = details.localPosition.dy
                                            .clamp(0.0, _thumbHeight);
                                        _show();
                                      },
                                      onVerticalDragStart: (details) {
                                        _dragging = true;
                                        _show();
                                        // Cancel an ongoing fling without jumping.
                                        widget.controller.jumpTo(
                                          widget.controller.position.pixels,
                                        );
                                        _dragTo(details.globalPosition);
                                      },
                                      onVerticalDragUpdate: (details) =>
                                          _dragTo(details.globalPosition),
                                      onVerticalDragEnd: (_) => _endDrag(),
                                      onVerticalDragCancel: _endDrag,
                                      child: Center(
                                        child: Container(
                                          width: 32,
                                          height: 52,
                                          decoration: BoxDecoration(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primaryContainer,
                                            borderRadius: BorderRadius.circular(
                                              24,
                                            ),
                                          ),
                                          child: Icon(
                                            Icons.unfold_more_rounded,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onPrimaryContainer,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
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
    );
  }
}
