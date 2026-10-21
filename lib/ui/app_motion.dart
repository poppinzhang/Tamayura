import 'package:animations/animations.dart';
import 'package:material_ui/material_ui.dart';

/// Shared accessibility policy for app-authored motion.
abstract final class AppMotion {
  static bool reduce(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ||
      MediaQuery.accessibleNavigationOf(context);
}

/// HeroMode must be inside the page content: HeroController discovers heroes
/// below a route's subtreeContext, which excludes its transition wrappers.
class AppHero extends StatelessWidget {
  const AppHero({
    super.key,
    required this.tag,
    required this.child,
    this.transitionOnUserGestures = false,
  });

  final Object tag;
  final Widget child;
  final bool transitionOnUserGestures;

  @override
  Widget build(BuildContext context) => HeroMode(
    enabled: !AppMotion.reduce(context),
    child: Hero(
      tag: tag,
      transitionOnUserGestures: transitionOnUserGestures,
      child: child,
    ),
  );
}

/// Animate only the newly selected tab, with one persistent subtree per tab.
/// A switcher that mounts old/new stacks at once would attach album scroll
/// controllers twice and lose the state of the inactive tabs.
class AppTabTransition extends StatefulWidget {
  const AppTabTransition({
    super.key,
    required this.index,
    required this.children,
  });

  final int index;
  final List<Widget> children;

  @override
  State<AppTabTransition> createState() => _AppTabTransitionState();
}

class _AppTabTransitionState extends State<AppTabTransition>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 220),
  );
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = AppMotion.reduce(context);
    if (_reduced) _controller.value = 1;
  }

  @override
  void didUpdateWidget(AppTabTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index && !_reduced) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeThroughTransition(
    animation: _controller,
    secondaryAnimation: kAlwaysDismissedAnimation,
    child: IndexedStack(index: widget.index, children: widget.children),
  );
}

/// Keep MaterialPageRoute's navigation, results and Hero lifecycle intact.
/// Android must retain Flutter's predictive-back gesture observer.
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final reduced = AppMotion.reduce(context);
    final primary = reduced ? kAlwaysCompleteAnimation : animation;
    final secondary = reduced ? kAlwaysDismissedAnimation : secondaryAnimation;
    if (Theme.of(context).platform == TargetPlatform.android) {
      // Keep camera frames and transfer progress live during page transitions.
      return const PredictiveBackPageTransitionsBuilder(
        allowSnapshotting: false,
      ).buildTransitions(route, context, primary, secondary, child);
    }
    return const SharedAxisPageTransitionsBuilder(
      transitionType: SharedAxisTransitionType.horizontal,
    ).buildTransitions(route, context, primary, secondary, child);
  }
}
