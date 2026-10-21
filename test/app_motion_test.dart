import 'package:animations/animations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tamayura/ui/app_motion.dart';
import 'package:tamayura/ui/app_theme.dart';

class _TabContent extends StatefulWidget {
  const _TabContent({super.key, required this.controller});

  final ScrollController controller;

  @override
  State<_TabContent> createState() => _TabContentState();
}

class _TabContentState extends State<_TabContent> {
  var count = 0;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextButton(
        onPressed: () => setState(() => count++),
        child: Text('Count: $count'),
      ),
      Expanded(
        child: ListView.builder(
          controller: widget.controller,
          itemExtent: 48,
          itemCount: 60,
          itemBuilder: (_, index) => Text('Photo $index'),
        ),
      ),
    ],
  );
}

class _TabHost extends StatefulWidget {
  const _TabHost({super.key, required this.content});

  final Widget content;

  @override
  State<_TabHost> createState() => _TabHostState();
}

class _TabHostState extends State<_TabHost> {
  var index = 0;
  var disableAnimations = false;
  var accessibleNavigation = false;

  void update(VoidCallback change) => setState(change);

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    home: MediaQuery(
      data: MediaQueryData(
        disableAnimations: disableAnimations,
        accessibleNavigation: accessibleNavigation,
      ),
      child: Scaffold(
        body: AppTabTransition(
          index: index,
          children: [
            widget.content,
            const Center(child: Text('Devices')),
          ],
        ),
      ),
    ),
  );
}

Widget _routesApp({
  required GlobalKey<NavigatorState> navigatorKey,
  required ValueNotifier<MediaQueryData> accessibility,
  Widget home = const Scaffold(body: Text('Album')),
}) => MaterialApp(
  navigatorKey: navigatorKey,
  theme: AppTheme.light.copyWith(platform: defaultTargetPlatform),
  builder: (context, child) => ValueListenableBuilder<MediaQueryData>(
    valueListenable: accessibility,
    builder: (context, settings, _) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: settings.disableAnimations,
        accessibleNavigation: settings.accessibleNavigation,
      ),
      child: child!,
    ),
  ),
  home: home,
);

class _DetailPage extends StatefulWidget {
  const _DetailPage({super.key});

  @override
  State<_DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<_DetailPage> {
  var count = 0;

  void increment() => setState(() => count++);

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('detail-page'),
    appBar: AppBar(title: const Text('Detail')),
    body: Column(
      children: [
        TextButton(onPressed: increment, child: Text('Count: $count')),
        const AppHero(tag: 'preview', child: Text('Photo')),
        TextButton(
          onPressed: () => Navigator.pop(context, 'selected'),
          child: const Text('Return selection'),
        ),
      ],
    ),
  );
}

class _HeroPage extends StatelessWidget {
  const _HeroPage({required this.destination});

  final bool destination;

  @override
  Widget build(BuildContext context) => Scaffold(
    key: Key(destination ? 'hero-destination-page' : 'hero-source-page'),
    body: Center(
      child: AppHero(
        tag: 'shared-photo',
        child: SizedBox(
          key: Key(destination ? 'hero-destination' : 'hero-source'),
          width: destination ? 240 : 80,
          height: destination ? 240 : 80,
          child: const ColoredBox(color: Colors.blue),
        ),
      ),
    ),
  );
}

class _LiveFramePainter extends CustomPainter {
  _LiveFramePainter(this.frame, this.paintedFrames) : super(repaint: frame);

  final ValueNotifier<int> frame;
  final List<int> paintedFrames;

  @override
  void paint(Canvas canvas, Size size) {
    paintedFrames.add(frame.value);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = frame.value.isEven ? Colors.blue : Colors.orange,
    );
  }

  @override
  bool shouldRepaint(_LiveFramePainter oldDelegate) =>
      oldDelegate.frame != frame;
}

void _expectHeroInPage(String name) {
  final child = find.byKey(Key('hero-$name'));
  expect(child, findsOneWidget);
  expect(find.ancestor(of: child, matching: find.byType(Hero)), findsOneWidget);
  expect(
    find.ancestor(of: child, matching: find.byKey(Key('hero-$name-page'))),
    findsOneWidget,
  );
}

Future<void> _backGesture(
  WidgetTester tester,
  String method, {
  double? progress,
}) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall(
        method,
        progress == null
            ? null
            : {
                'touchOffset': <double>[5 + 300 * progress, 300],
                'progress': progress,
                'swipeEdge': 0,
              },
      ),
    ),
    (_) {},
  );
  await tester.pump();
}

void _expectPageFullyVisible(WidgetTester tester) {
  final page = find.byKey(const Key('detail-page'));
  expect(tester.getTopLeft(page), Offset.zero);
  for (final fade in tester.widgetList<FadeTransition>(
    find.ancestor(of: page, matching: find.byType(FadeTransition)),
  )) {
    expect(fade.opacity.value, 1);
  }
}

void main() {
  testWidgets('tab changes animate once while preserving state and scroll', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final contentKey = GlobalKey<_TabContentState>();
    final hostKey = GlobalKey<_TabHostState>();
    await tester.pumpWidget(
      _TabHost(
        key: hostKey,
        content: _TabContent(key: contentKey, controller: scroll),
      ),
    );
    await tester.tap(find.text('Count: 0'));
    scroll.jumpTo(240);
    await tester.pump();
    final contentState = contentKey.currentState;
    final host = hostKey.currentState!;
    host.update(() => host.index = 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    final transition = tester.widget<FadeThroughTransition>(
      find.byType(FadeThroughTransition),
    );
    final progress = transition.animation.value;
    expect(progress, greaterThan(0));
    expect(progress, lessThan(1));
    expect(scroll.positions, hasLength(1));
    expect(contentKey.currentState, same(contentState));

    host.update(() {});
    await tester.pump();
    expect(transition.animation.value, progress);
    await tester.pumpAndSettle();
    host.update(() {});
    await tester.pump();
    expect(transition.animation.value, 1);

    host.update(() => host.index = 0);
    await tester.pumpAndSettle();
    expect(find.text('Count: 1'), findsOneWidget);
    expect(scroll.offset, 240);
    expect(scroll.positions, hasLength(1));
    expect(contentKey.currentState, same(contentState));
    expect(tester.takeException(), isNull);
  });

  for (final flag in ['disableAnimations', 'accessibleNavigation']) {
    testWidgets('$flag finishes active tab motion without remounting', (
      tester,
    ) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final contentKey = GlobalKey<_TabContentState>();
      final hostKey = GlobalKey<_TabHostState>();
      await tester.pumpWidget(
        _TabHost(
          key: hostKey,
          content: _TabContent(key: contentKey, controller: scroll),
        ),
      );
      await tester.tap(find.text('Count: 0'));
      await tester.pump();
      final state = contentKey.currentState;
      final host = hostKey.currentState!;
      host.update(() => host.index = 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      host.update(() {
        host.disableAnimations = flag == 'disableAnimations';
        host.accessibleNavigation = flag == 'accessibleNavigation';
      });
      await tester.pump();
      final transition = tester.widget<FadeThroughTransition>(
        find.byType(FadeThroughTransition),
      );
      expect(transition.animation.value, 1);
      host.update(() => host.index = 0);
      await tester.pump();
      expect(transition.animation.value, 1);
      expect(find.text('Count: 1').hitTestable(), findsOneWidget);
      expect(contentKey.currentState, same(state));
      expect(scroll.positions, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('$flag completes route visuals without remounting', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      final settings = ValueNotifier(const MediaQueryData());
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        _routesApp(navigatorKey: navigator, accessibility: settings),
      );
      final detailKey = GlobalKey<_DetailPageState>();
      navigator.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => _DetailPage(key: detailKey)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final state = detailKey.currentState!;
      state.increment();
      settings.value = MediaQueryData(
        disableAnimations: flag == 'disableAnimations',
        accessibleNavigation: flag == 'accessibleNavigation',
      );
      await tester.pump();
      _expectPageFullyVisible(tester);
      expect(detailKey.currentState, same(state));
      expect(find.text('Count: 1'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.desktop());
  }

  testWidgets('AppHero flies between matching page content in normal mode', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final settings = ValueNotifier(const MediaQueryData());
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      _routesApp(
        navigatorKey: navigator,
        accessibility: settings,
        home: const _HeroPage(destination: false),
      ),
    );
    _expectHeroInPage('source');
    navigator.currentState!.push<void>(
      MaterialPageRoute(builder: (_) => const _HeroPage(destination: true)),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final flying = find.byKey(const Key('hero-destination'));
    expect(flying, findsOneWidget);
    expect(
      find.ancestor(of: flying, matching: find.byType(Hero)),
      findsNothing,
      reason: 'The destination child must move into the flight overlay',
    );
    expect(tester.getSize(flying).width, greaterThan(80));
    expect(tester.getSize(flying).width, lessThan(240));
    await tester.pumpAndSettle();
    _expectHeroInPage('destination');
    expect(tester.getSize(flying).width, 240);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.desktop());

  for (final flag in ['disableAnimations', 'accessibleNavigation']) {
    for (final changedAtRuntime in [false, true]) {
      testWidgets('$flag prevents actual Hero flights when enabled '
          '${changedAtRuntime ? 'at runtime' : 'initially'}', (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        final reduced = MediaQueryData(
          disableAnimations: flag == 'disableAnimations',
          accessibleNavigation: flag == 'accessibleNavigation',
        );
        final settings = ValueNotifier(
          changedAtRuntime ? const MediaQueryData() : reduced,
        );
        addTearDown(settings.dispose);
        await tester.pumpWidget(
          _routesApp(
            navigatorKey: navigator,
            accessibility: settings,
            home: const _HeroPage(destination: false),
          ),
        );
        _expectHeroInPage('source');
        final sourceElement = tester.element(
          find.byKey(const Key('hero-source')),
        );
        if (changedAtRuntime) {
          settings.value = reduced;
          await tester.pump();
          expect(
            tester.element(find.byKey(const Key('hero-source'))),
            same(sourceElement),
          );
        }
        navigator.currentState!.push<void>(
          MaterialPageRoute(builder: (_) => const _HeroPage(destination: true)),
        );
        await tester.pump();
        await tester.pump();
        _expectHeroInPage('destination');
        await tester.pump(const Duration(milliseconds: 100));
        _expectHeroInPage('destination');
        expect(
          tester.getSize(find.byKey(const Key('hero-destination'))).width,
          240,
        );
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
        await tester.pump();
        await tester.pump();
        _expectHeroInPage('source');
        await tester.pump(const Duration(milliseconds: 100));
        _expectHeroInPage('source');
        expect(tester.getSize(find.byKey(const Key('hero-source'))).width, 80);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.desktop());
    }
  }

  testWidgets('desktop routes animate and return their pop result', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final settings = ValueNotifier(const MediaQueryData());
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      _routesApp(navigatorKey: navigator, accessibility: settings),
    );
    final route = MaterialPageRoute<String>(
      builder: (_) => const _DetailPage(),
    );
    final result = navigator.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(route.animation!.value, greaterThan(0));
    expect(route.animation!.value, lessThan(1));
    expect(find.byType(SharedAxisTransition), findsWidgets);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Return selection'));
    await tester.pumpAndSettle();
    expect(await result, 'selected');
    expect(find.text('Album'), findsOneWidget);
    expect(find.text('Detail'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('Android push keeps painting live frames during the transition', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final settings = ValueNotifier(const MediaQueryData());
    final frame = ValueNotifier(0);
    final paintedFrames = <int>[];
    addTearDown(settings.dispose);
    addTearDown(frame.dispose);
    await tester.pumpWidget(
      _routesApp(navigatorKey: navigator, accessibility: settings),
    );
    final route = MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        body: CustomPaint(
          painter: _LiveFramePainter(frame, paintedFrames),
          child: const SizedBox.expand(),
        ),
      ),
    );
    navigator.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(paintedFrames, contains(0));
    expect(navigator.currentState!.userGestureInProgress, isFalse);

    for (var next = 1; next <= 3; next++) {
      frame.value = next;
      await tester.pump(const Duration(milliseconds: 16));
      expect(route.animation!.value, inExclusiveRange(0, 1));
      expect(
        paintedFrames.last,
        next,
        reason: 'Live content must repaint before the route transition ends',
      );
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final flag in ['none', 'disableAnimations', 'accessibleNavigation']) {
    testWidgets('Android predictive back can cancel and commit with $flag', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      final settings = ValueNotifier(
        MediaQueryData(
          disableAnimations: flag == 'disableAnimations',
          accessibleNavigation: flag == 'accessibleNavigation',
        ),
      );
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        _routesApp(navigatorKey: navigator, accessibility: settings),
      );
      final route = MaterialPageRoute<void>(
        builder: (_) => const _DetailPage(),
      );
      navigator.currentState!.push(route);
      await tester.pumpAndSettle();
      final initial = tester.getTopLeft(find.byKey(const Key('detail-page')));

      await _backGesture(tester, 'startBackGesture', progress: 0);
      expect(navigator.currentState!.userGestureInProgress, isTrue);
      await _backGesture(tester, 'updateBackGestureProgress', progress: .35);
      expect(route.animation!.value, closeTo(.65, .001));
      if (flag == 'none') {
        expect(
          tester.getTopLeft(find.byKey(const Key('detail-page'))).dx,
          greaterThan(initial.dx),
        );
      }
      await _backGesture(tester, 'cancelBackGesture');
      await tester.pumpAndSettle();
      expect(navigator.currentState!.userGestureInProgress, isFalse);
      expect(find.text('Detail'), findsOneWidget);
      expect(route.animation!.value, 1);

      await _backGesture(tester, 'startBackGesture', progress: 0);
      expect(navigator.currentState!.userGestureInProgress, isTrue);
      await _backGesture(tester, 'updateBackGestureProgress', progress: .7);
      await _backGesture(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(navigator.currentState!.userGestureInProgress, isFalse);
      expect(find.text('Album'), findsOneWidget);
      expect(find.text('Detail'), findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
