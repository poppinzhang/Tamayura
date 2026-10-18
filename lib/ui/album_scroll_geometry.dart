import 'dart:math' as math;

import '../l10n/app_locale.dart';

/// Maps album grid items to scroll positions, including slivers before the grid.
class AlbumScrollGeometry {
  const AlbumScrollGeometry({
    required this.scrollOffset,
    required this.columns,
    required this.tileExtent,
    required this.rowStride,
    required this.itemCount,
  }) : assert(scrollOffset >= 0),
       assert(columns > 0),
       assert(tileExtent > 0),
       assert(rowStride >= tileExtent),
       assert(itemCount >= 0);

  final double scrollOffset;
  final int columns;
  final double tileExtent;
  final double rowStride;
  final int itemCount;

  int get _rowCount => (itemCount + columns - 1) ~/ columns;

  /// Selects the center column of the row nearest the viewport's center.
  ///
  /// An even column count selects the right of the two middle columns. Gaps
  /// between rows are split halfway between the neighboring images.
  int centerIndex(double pixels, double viewportExtent) {
    if (itemCount == 0) return 0;
    final center = pixels + viewportExtent / 2 - scrollOffset;
    final gap = rowStride - tileExtent;
    final row = ((center + gap / 2) / rowStride).floor().clamp(
      0,
      _rowCount - 1,
    );
    return math.min(row * columns + columns ~/ 2, itemCount - 1);
  }

  /// Centers an item's row, constrained to the album's scrollable extent.
  double offsetForIndex(int index, double viewportExtent) {
    if (itemCount == 0) return 0;
    final row = index.clamp(0, itemCount - 1) ~/ columns;
    final center = scrollOffset + row * rowStride + tileExtent / 2;
    final contentExtent =
        scrollOffset + (_rowCount - 1) * rowStride + tileExtent;
    final maxOffset = math.max(0.0, contentExtent - viewportExtent);
    return (center - viewportExtent / 2).clamp(0.0, maxOffset);
  }
}

/// Uses ASCII letters only; filenames starting with any other character use #.
String albumNameInitial(String name) {
  if (name.isEmpty) return '#';
  final first = name.codeUnitAt(0);
  if (first >= 65 && first <= 90) return String.fromCharCode(first);
  if (first >= 97 && first <= 122) return String.fromCharCode(first - 32);
  return '#';
}

/// The month heading of a date-sorted album, in the local calendar.
String albumMonthLabel(AppLocalizations l10n, DateTime date) =>
    l10n.albumMonthLabel(date.toLocal());

/// The full local date with its weekday, shown while fast scrolling.
String albumDateLabel(AppLocalizations l10n, DateTime date) =>
    l10n.albumDateLabel(date.toLocal());
