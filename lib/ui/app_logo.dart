import 'package:material_ui/material_ui.dart';

/// The in-app mark is separate from the orange platform launcher icon.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 22.4});

  final double size;

  @override
  Widget build(BuildContext context) {
    final background = Theme.of(context).brightness == Brightness.dark
        ? 'white'
        : 'black';
    // The supplied SVG already defines its corners; retain its original shape.
    return Image.asset(
      'assets/branding/hibiki/hibiki-$background.png',
      width: size,
      height: size,
      excludeFromSemantics: true,
      filterQuality: FilterQuality.high,
    );
  }
}
