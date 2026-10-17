import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/ui/album_scroll_geometry.dart';

void main() {
  group('AlbumScrollGeometry', () {
    const geometry = AlbumScrollGeometry(
      scrollOffset: 200,
      columns: 4,
      tileExtent: 100,
      rowStride: 110,
      itemCount: 39,
    );

    test('uses the viewport center and accounts for preceding slivers', () {
      expect(geometry.centerIndex(0, 100), 2);
      expect(geometry.centerIndex(100, 300), 2);
      expect(geometry.centerIndex(210, 300), 6);
      expect(geometry.centerIndex(430, 300), 14);
    });

    test('splits a row gap between neighboring rows', () {
      expect(geometry.centerIndex(254.9, 100), 2);
      expect(geometry.centerIndex(255, 100), 6);
      expect(geometry.centerIndex(260, 100), 6);
    });

    test('clamps overscroll and the incomplete final row', () {
      expect(geometry.centerIndex(-1000, 100), 2);
      expect(geometry.centerIndex(10000, 100), 38);
      const incomplete = AlbumScrollGeometry(
        scrollOffset: 0,
        columns: 4,
        tileExtent: 100,
        rowStride: 100,
        itemCount: 9,
      );
      expect(incomplete.centerIndex(200, 100), 8);
    });

    test('handles odd column counts and a single column', () {
      const odd = AlbumScrollGeometry(
        scrollOffset: 0,
        columns: 3,
        tileExtent: 100,
        rowStride: 100,
        itemCount: 30,
      );
      const single = AlbumScrollGeometry(
        scrollOffset: 0,
        columns: 1,
        tileExtent: 100,
        rowStride: 100,
        itemCount: 10,
      );
      expect(odd.centerIndex(100, 100), 4);
      expect(single.centerIndex(100, 100), 1);
    });

    test('centers a target row and includes grid spacing and header', () {
      expect(geometry.offsetForIndex(12, 300), 430);
      expect(geometry.offsetForIndex(15, 300), 430);
      expect(geometry.centerIndex(geometry.offsetForIndex(14, 300), 300), 14);
    });

    test('clamps target indices and reachable scroll positions', () {
      expect(geometry.offsetForIndex(-1, 300), 100);
      expect(geometry.offsetForIndex(100, 300), 990);
      expect(geometry.offsetForIndex(0, 1000), 0);
    });

    test('handles empty albums and albums shorter than the viewport', () {
      const empty = AlbumScrollGeometry(
        scrollOffset: 200,
        columns: 4,
        tileExtent: 100,
        rowStride: 110,
        itemCount: 0,
      );
      const short = AlbumScrollGeometry(
        scrollOffset: 200,
        columns: 4,
        tileExtent: 100,
        rowStride: 110,
        itemCount: 1,
      );
      expect(empty.centerIndex(10, 100), 0);
      expect(empty.offsetForIndex(10, 100), 0);
      expect(short.centerIndex(0, 800), 0);
      expect(short.offsetForIndex(0, 800), 0);
    });
  });

  group('albumNameInitial', () {
    test('normalizes ASCII initials only', () {
      expect(albumNameInitial('Album.jpg'), 'A');
      expect(albumNameInitial('apple.jpg'), 'A');
      expect(albumNameInitial('zebra.jpg'), 'Z');
      expect(albumNameInitial('Zoo.jpg'), 'Z');
    });

    test('does not trim or transliterate nonletter initials', () {
      for (final name in [
        '',
        '1.jpg',
        '_a.jpg',
        ' a.jpg',
        '相片.jpg',
        'é.jpg',
        '😀',
      ]) {
        expect(albumNameInitial(name), '#', reason: name);
      }
    });
  });

  group('album date labels', () {
    test('formats dates and all weekdays without padding', () {
      expect(albumMonthLabel(DateTime(2026, 10, 17)), '2026年10月');
      expect(albumMonthLabel(DateTime(2026, 1, 1)), '2026年1月');
      const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
      for (var index = 0; index < weekdays.length; index++) {
        expect(
          albumDateLabel(DateTime(2026, 10, 12 + index)),
          '2026年10月${12 + index}日 周${weekdays[index]}',
        );
      }
    });

    test('UTC timestamps use the local calendar date', () {
      final utc = DateTime.utc(2026, 12, 31, 23, 59);
      final local = utc.toLocal();
      const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
      expect(albumMonthLabel(utc), '${local.year}年${local.month}月');
      expect(
        albumDateLabel(utc),
        '${local.year}年${local.month}月${local.day}日 周${weekdays[local.weekday - 1]}',
      );
    });
  });
}
