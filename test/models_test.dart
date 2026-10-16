import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tamayura/core/models.dart';

void main() {
  test(
    'shared folder configuration round-trips and rejects invalid fields',
    () {
      const folder = SharedFolder(
        id: 'camera',
        uri: 'content://media/tree/Camera',
        name: 'Camera',
      );
      final restored = SharedFolder.fromJson(folder.toJson());
      expect(restored.id, folder.id);
      expect(restored.uri, folder.uri);
      expect(restored.name, folder.name);
      for (final invalid in <Map<String, dynamic>>[
        {},
        {'id': 7, 'uri': folder.uri, 'name': folder.name},
        {'id': folder.id, 'uri': '', 'name': folder.name},
        {'id': folder.id, 'uri': folder.uri, 'name': ''},
      ]) {
        expect(() => SharedFolder.fromJson(invalid), throwsFormatException);
      }
    },
  );

  test('relative media paths preserve nested Unicode names', () {
    expect(mediaPathSegments('2026/旅行/照片.jpg'), ['2026', '旅行', '照片.jpg']);
    expect(mediaPathSegments('photo.jpg'), ['photo.jpg']);
    for (final path in [
      '',
      '/photo.jpg',
      '../photo.jpg',
      'a/../photo.jpg',
      './photo.jpg',
      'a/./photo.jpg',
      'a//photo.jpg',
      'a/photo.jpg/',
      r'a\photo.jpg',
      'C:/photo.jpg',
      'C:photo.jpg',
      'a/\u0000photo.jpg',
      'a/\u007fphoto.jpg',
      'a/\u0085photo.jpg',
    ]) {
      expect(
        () => mediaPathSegments(path),
        throwsFormatException,
        reason: path,
      );
    }
  });

  test(
    'location metadata survives thumbnails and affects revision equality',
    () {
      MediaMetadata item({
        String root = 'camera',
        String rootName = 'Camera',
        String path = '2026/photo.jpg',
      }) => MediaMetadata(
        id: 'photo',
        deviceId: 'phone',
        name: 'photo.jpg',
        mimeType: 'image/jpeg',
        size: 1,
        modifiedMs: 2,
        sharedFolderId: root,
        sharedFolderName: rootName,
        relativePath: path,
      );
      final metadata = item();
      final withThumbnail = metadata.withThumbnail(Uint8List.fromList([7]));
      expect(withThumbnail.sharedFolderId, metadata.sharedFolderId);
      expect(withThumbnail.sharedFolderName, metadata.sharedFolderName);
      expect(withThumbnail.relativePath, metadata.relativePath);
      expect(metadata.hasSameMetadata(withThumbnail), isTrue);
      expect(metadata.hasSameMetadata(item(root: 'sd-card')), isFalse);
      expect(metadata.hasSameMetadata(item(rootName: '旅行')), isFalse);
      expect(
        metadata.hasSameMetadata(item(path: 'Archive/photo.jpg')),
        isFalse,
      );
      expect(() => validateMediaLocation(metadata), returnsNormally);
      expect(
        () => validateMediaLocation(item(path: 'other.jpg')),
        throwsFormatException,
      );
    },
  );
}
