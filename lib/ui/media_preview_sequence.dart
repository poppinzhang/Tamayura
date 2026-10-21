import '../app/view_state.dart';

/// Keep the opening order stable while synchronization or downloads update the
/// underlying lists. Album entries contain identities, not full-size images or
/// a thumbnail for every item in a large collection.
class MediaPreviewSequence {
  MediaPreviewSequence.items(Iterable<MediaView> items)
    : _entries = [
        for (final item in items)
          (deviceId: item.deviceId, id: item.id, item: item),
      ];

  MediaPreviewSequence.album(TamayuraModel model)
    : _entries = model.mediaScrollEntries.isNotEmpty
          ? [
              for (final entry in model.mediaScrollEntries)
                (deviceId: entry.deviceId, id: entry.id, item: null),
            ]
          : [
              for (final item in model.media)
                (deviceId: item.deviceId, id: item.id, item: item),
            ];

  final List<({String deviceId, String id, MediaView? item})> _entries;

  int get length => _entries.length;

  int indexOf(MediaView item) => _entries.indexWhere(
    (entry) => entry.deviceId == item.deviceId && entry.id == item.id,
  );

  Future<MediaView?> resolve(TamayuraModel model, int index) async {
    final entry = _entries[index];
    return entry.item ??
        await model.resolvePreviewMedia(entry.deviceId, entry.id);
  }
}
