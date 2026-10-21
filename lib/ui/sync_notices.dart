import 'dart:async';

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';

import '../app/view_state.dart';

bool _isActive(SyncProgress progress) => switch (progress.phase) {
  SyncPhase.connecting || SyncPhase.receiving || SyncPhase.committing => true,
  SyncPhase.completed || SyncPhase.failed => false,
};

/// Ephemeral presentation state, independent of album filters and navigation.
class SyncNotices extends ChangeNotifier {
  SyncNotices({required TamayuraModel model, required TickerProvider vsync})
    : _model = model,
      _vsync = vsync {
    _update();
    _model.addListener(_update);
  }

  final TamayuraModel _model;
  final TickerProvider _vsync;
  final Map<Object, SyncNotice> _notices = {};
  bool _reduceMotion = false;

  Iterable<SyncNotice> get visible =>
      _notices.values.where((notice) => !notice.hidden);

  /// Change presentation without restarting the notices' retention timers.
  void setReduceMotion(bool value) {
    if (_reduceMotion == value) return;
    _reduceMotion = value;
    for (final notice in _notices.values) {
      notice._setReduceMotion(value);
    }
  }

  void _update() {
    final progress = _model.syncProgress;
    final current = progress
        .map((item) => item.sessionId ?? item.peerId)
        .toSet();
    for (final key in _notices.keys.toList()) {
      if (!current.contains(key)) _notices.remove(key)!.dispose();
    }
    for (final item in progress) {
      final key = item.sessionId ?? item.peerId;
      var notice = _notices[key];
      if (notice != null && !_isActive(notice.progress) && _isActive(item)) {
        notice.dispose();
        _notices.remove(key);
        notice = null;
      }
      if (notice == null) {
        // Restored failures and old completions are not new notifications.
        if (_isActive(item)) {
          _notices[key] = SyncNotice._(
            item,
            _vsync,
            notifyListeners,
            _reduceMotion,
          );
        }
      } else {
        notice._update(item);
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _model.removeListener(_update);
    for (final notice in _notices.values) {
      notice.dispose();
    }
    super.dispose();
  }
}

class SyncNotice {
  SyncNotice._(
    this.progress,
    TickerProvider vsync,
    this._changed,
    this._reduceMotion,
  ) : _animation = AnimationController(
        vsync: vsync,
        value: 1,
        duration: fadeDuration,
        // Reduced motion is applied explicitly, including changes mid-fade.
        animationBehavior: AnimationBehavior.preserve,
      ) {
    _animation.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) dismiss();
    });
  }

  SyncProgress progress;
  static const fadeDuration = Duration(milliseconds: 300);
  bool hidden = false;
  bool _reduceMotion;
  final VoidCallback _changed;
  final AnimationController _animation;
  Timer? _holdTimer;

  Animation<double> get animation => _animation.view;

  void _update(SyncProgress next) {
    final ended = _isActive(progress) && !_isActive(next);
    progress = next;
    if (ended && !hidden) {
      _holdTimer = Timer(const Duration(seconds: 5), () {
        if (_reduceMotion) {
          dismiss();
        } else {
          _animation.reverse();
        }
      });
    }
  }

  void _setReduceMotion(bool value) {
    _reduceMotion = value;
    if (value && _animation.status == AnimationStatus.reverse) dismiss();
  }

  void dismiss() {
    if (hidden) return;
    _holdTimer?.cancel();
    _animation.stop();
    hidden = true;
    _changed();
  }

  void dispose() {
    _holdTimer?.cancel();
    _animation.dispose();
  }
}
