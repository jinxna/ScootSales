import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

enum GallerySurface { dashboard, phone }

class GalleryScene {
  const GalleryScene({
    required this.id,
    required this.title,
    required this.surface,
    required this.builder,
    this.brightness = Brightness.light,
    this.height,
  });

  final String id;
  final String title;
  final GallerySurface surface;
  final Brightness brightness;
  final double? height;
  final WidgetBuilder builder;

  Size get size {
    final Size base = surface == GallerySurface.dashboard
        ? ScootSize.dashboardFrame
        : ScootSize.phoneFrame;
    return Size(base.width, height ?? base.height);
  }

  ThemeData get theme => themeFor(ScootType.fontFamily);

  ThemeData themeFor(String fontFamily) => surface == GallerySurface.dashboard
      ? ScootTheme.dashboard(brightness: brightness, fontFamily: fontFamily)
      : ScootTheme.phone(brightness: brightness, fontFamily: fontFamily);
}

class SceneFrame extends StatelessWidget {
  const SceneFrame({super.key, required this.scene, this.fontFamily});

  final GalleryScene scene;
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    final Widget content = Theme(
      data: fontFamily == null ? scene.theme : scene.themeFor(fontFamily!),
      child: Builder(builder: scene.builder),
    );
    return SizedBox.fromSize(
      size: scene.size,
      child: scene.surface == GallerySurface.phone
          ? Material(child: PhoneFrame(child: content))
          : Material(child: content),
    );
  }
}

class PhoneFrame extends StatelessWidget {
  const PhoneFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData base = MediaQuery.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _SystemStatusBar(),
        Expanded(
          child: MediaQuery(
            data: base.copyWith(
              size: Size(base.size.width, ScootSize.phoneFrame.height - 44),
              padding: const EdgeInsets.only(bottom: ScootSize.homeIndicator),
              viewPadding: const EdgeInsets.only(
                bottom: ScootSize.homeIndicator,
              ),
            ),
            child: child,
          ),
        ),
      ],
    );
  }
}

class _SystemStatusBar extends StatelessWidget {
  const _SystemStatusBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      color: const Color(0xFFFFFFFF),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: const Row(
        children: <Widget>[
          Text(
            '18:34',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: ScootPalette.ink,
            ),
          ),
          Spacer(),
          Icon(ScootIcons.signal, size: 16, color: ScootPalette.ink),
          SizedBox(width: 6),
          Icon(ScootIcons.wifi, size: 16, color: ScootPalette.ink),
          SizedBox(width: 6),
          Icon(ScootIcons.battery, size: 16, color: ScootPalette.ink),
        ],
      ),
    );
  }
}
