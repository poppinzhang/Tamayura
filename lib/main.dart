import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'app/app_controller.dart';
import 'app/app_lifecycle.dart';
import 'ui/app.dart';
import 'background/transfer_worker.dart';
import 'platform/macos_bridge.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _TamayuraRoot());
}

@pragma('vm:entry-point')
void backgroundTransferMain() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(runBackgroundTransfer());
}

class _TamayuraRoot extends StatefulWidget {
  const _TamayuraRoot();
  @override
  State<_TamayuraRoot> createState() => _TamayuraRootState();
}

class _TamayuraRootState extends State<_TamayuraRoot>
    with WidgetsBindingObserver {
  final controller = AppController();
  late final lifecycle = AppLifecycleCoordinator(
    isMacOS: Platform.isMacOS,
    isWindows: Platform.isWindows,
    setForeground: controller.setForeground,
    onResume: controller.refreshAfterResume,
    isWindowVisible: Platform.isMacOS
        ? const MacOSBridge().isMainWindowVisible
        : null,
  );
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(lifecycle.initialize(WidgetsBinding.instance.lifecycleState));
    unawaited(controller.initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(lifecycle.handleState(state));
  }

  @override
  void didChangeLocales(List<Locale>? locales) =>
      controller.systemLocalesChanged();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TamayuraApp(model: controller);
}
