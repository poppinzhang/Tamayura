import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

bool get isMacDesktop => defaultTargetPlatform == TargetPlatform.macOS;
bool get isWindowsDesktop => defaultTargetPlatform == TargetPlatform.windows;
bool get isLinuxDesktop => defaultTargetPlatform == TargetPlatform.linux;
bool get isDesktop => isMacDesktop || isWindowsDesktop || isLinuxDesktop;

/// Windows and Linux use Ctrl where macOS uses ⌘.
bool get usesControlShortcuts => isWindowsDesktop || isLinuxDesktop;

/// Without a system share sheet, saved files are shown in the file manager.
bool get revealsSavedFiles => isWindowsDesktop || isLinuxDesktop;

/// The QR scanner plugin has no Windows or Linux implementation.
bool get hasCameraScanner => !isWindowsDesktop && !isLinuxDesktop;

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
