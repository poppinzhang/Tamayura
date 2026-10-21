import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

bool get isMacDesktop => defaultTargetPlatform == TargetPlatform.macOS;
bool get isWindowsDesktop => defaultTargetPlatform == TargetPlatform.windows;
bool get isDesktop => isMacDesktop || isWindowsDesktop;
bool get isMobile =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Keep desktop reading surfaces comfortable without changing phone layouts.
class DesktopContent extends StatelessWidget {
  const DesktopContent({super.key, required this.child, this.maxWidth = 840});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => isDesktop
      ? Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: child,
          ),
        )
      : child;
}
