import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app/view_state.dart';

/// Reads the saved original through the platform's URI-aware image decoder.
/// Local reads follow each card's lifetime; offline thumbnails are the fallback.
class AlbumImage extends StatefulWidget {
  const AlbumImage({
    super.key,
    required this.model,
    required this.item,
    required this.placeholder,
  });

  final TamayuraModel model;
  final MediaView item;
  final Widget placeholder;

  @override
  State<AlbumImage> createState() => _AlbumImageState();
}

class _AlbumImageState extends State<AlbumImage> with WidgetsBindingObserver {
  static const _maxDimension = 1024;
  Uint8List? _localImage;
  String? _uri;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.model.addListener(_onModel);
    _updateSource();
  }

  @override
  void didUpdateWidget(covariant AlbumImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final modelChanged = oldWidget.model != widget.model;
    if (modelChanged) {
      oldWidget.model.removeListener(_onModel);
      widget.model.addListener(_onModel);
    }
    _updateSource(
      reload: modelChanged || oldWidget.item.key != widget.item.key,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Files may have been deleted outside the app while it was in the background.
    if (state == AppLifecycleState.resumed) {
      setState(() => _updateSource(reload: true));
    }
  }

  void _onModel() {
    final uri = widget.item.isVideo
        ? null
        : widget.model.transfers[widget.item.key]?.savedUri;
    if (uri != _uri) setState(_updateSource);
  }

  void _updateSource({bool reload = false}) {
    final uri = widget.item.isVideo
        ? null
        : widget.model.transfers[widget.item.key]?.savedUri;
    if (!reload && uri == _uri) return;
    _uri = uri;
    _localImage = null;
    final generation = ++_generation;
    if (uri != null) unawaited(_load(generation));
  }

  Future<void> _load(int generation) async {
    Uint8List? bytes;
    try {
      bytes = await widget.model.loadPreview(
        widget.item,
        maxDimension: _maxDimension,
        isCurrent: () => mounted && generation == _generation,
      );
    } catch (_) {
      // Missing files, revoked permissions and decoder failures use the cache.
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _localImage =
          bytes != null && bytes.isNotEmpty && bytes.length <= 8 * 1024 * 1024
          ? bytes
          : null;
    });
  }

  Widget _thumbnail() => widget.item.thumbnail.isEmpty
      ? widget.placeholder
      : Image.memory(
          widget.item.thumbnail,
          key: ValueKey('cached-album-image-${widget.item.key}'),
          fit: BoxFit.cover,
          cacheWidth: 640,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => widget.placeholder,
        );

  @override
  Widget build(BuildContext context) => _localImage == null
      ? _thumbnail()
      : Image(
          key: ValueKey('local-album-image-${widget.item.key}'),
          image: ResizeImage(
            MemoryImage(_localImage!),
            width: _maxDimension,
            height: _maxDimension,
            policy: ResizeImagePolicy.fit,
          ),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _thumbnail(),
        );

  @override
  void dispose() {
    _generation++;
    widget.model.removeListener(_onModel);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
