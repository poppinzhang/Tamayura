import 'package:flutter/widgets.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'app_motion.dart';
import 'sync_notices.dart';

/// Displays a notice's independently owned animation without restarting it
/// when a device filter removes and later restores this widget.
class SyncNoticeTransition extends StatefulWidget {
  const SyncNoticeTransition({
    super.key,
    required this.notice,
    required this.child,
  });

  final SyncNotice notice;
  final Widget child;

  @override
  State<SyncNoticeTransition> createState() => _SyncNoticeTransitionState();
}

class _SyncNoticeTransitionState extends State<SyncNoticeTransition> {
  late _NoticeAnimationAdapter _adapter;

  @override
  void initState() {
    super.initState();
    _adapter = _NoticeAnimationAdapter(widget.notice.animation);
  }

  @override
  void didUpdateWidget(SyncNoticeTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.notice != widget.notice) {
      _adapter = _NoticeAnimationAdapter(widget.notice.animation);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduce(context)) return widget.child;
    return Animate(autoPlay: false, adapter: _adapter, child: widget.child)
        .fade(duration: SyncNotice.fadeDuration)
        .custom(
          duration: SyncNotice.fadeDuration,
          builder: (context, value, child) => ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: value,
              child: child,
            ),
          ),
        );
  }
}

/// Animate owns its rendering controller; the notice owns timing and progress.
/// Pair listeners explicitly so filtering out a notice releases the widget.
class _NoticeAnimationAdapter extends Adapter {
  _NoticeAnimationAdapter(this.animation);

  final Animation<double> animation;

  @override
  void attach(AnimationController controller) {
    config(controller, animation.value);
    animation.addListener(_update);
  }

  void _update() => updateValue(animation.value);

  @override
  void detach() {
    animation.removeListener(_update);
    super.detach();
  }
}
