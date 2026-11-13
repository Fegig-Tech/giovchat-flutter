/// The "Powered by GiovChat" footer: the style rules ([resolveGiovFooterStyle]) and the drop-in
/// [GiovBranding] widget for apps that build their own chat screen.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
// Flutter 3.47 deprecates this import (Material moves to its own package); the SDK still supports Flutter 3.22.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/client.dart' show GiovChatClient, giovDefaultBaseUrl;
import '../core/controller.dart';
import 'look.dart';
import 'style_overrides.dart';

/// WCAG AA for normal text.
const giovFooterMinContrast = 4.5;

/// The footer text is never smaller than this, whatever the app's style.
const giovFooterFontSize = 12.0;

const _defaultBackground = Color(0xFFFFFFFF);
const _defaultText = Color(0xFF52525B);
const _defaultBrand = Color(0xFF7C3AED);

/// The footer as drawn: the app's colours after the accessibility rules.
@immutable
class GiovFooterStyle {
  const GiovFooterStyle({
    required this.color,
    required this.brandColor,
    required this.backgroundColor,
    required this.customBackground,
    this.fontFamily,
  });

  final Color color;
  final Color brandColor;
  final Color backgroundColor;
  final String? fontFamily;

  /// True when the app changed the background (the divider is then a neutral translucent grey).
  final bool customBackground;
}

/// Applies the app's footer colours under the rules: an override that is see-through (any alpha
/// below 1) or below 4.5:1 against the effective background falls back to the SDK's default for
/// that property (or black/white when the default is unreadable on the app's own background).
/// [warn] gets one message per rejected value; the footer widgets log them in debug builds.
GiovFooterStyle resolveGiovFooterStyle(
  GiovChatStyleOverrides style, {
  void Function(String message)? warn,
}) {
  final slot = style.branding;
  var background = _defaultBackground;
  var customBackground = false;
  final wantedBackground = slot?.backgroundColor;
  if (wantedBackground != null) {
    if (_opaque(wantedBackground)) {
      background = wantedBackground;
      customBackground = true;
    } else {
      warn?.call(
          'GiovChat: branding.backgroundColor is ignored (it must be opaque).');
    }
  }
  bool readable(Color c) =>
      _opaque(c) && giovContrast(c, background) >= giovFooterMinContrast;
  Color pick(String name, Color? wanted, Color fallback) {
    if (wanted != null) {
      if (readable(wanted)) return wanted;
      warn?.call('GiovChat: branding.$name is ignored (an opaque colour with '
          'at least $giovFooterMinContrast:1 contrast against the footer '
          'background is required).');
    }
    return readable(fallback) ? fallback : giovReadableOn(background);
  }

  return GiovFooterStyle(
    color: pick('color', slot?.color, _defaultText),
    brandColor: pick('brandColor', slot?.brandColor, _defaultBrand),
    backgroundColor: background,
    customBackground: customBackground,
    fontFamily: slot?.fontFamily ?? style.fontFamily,
  );
}

bool _opaque(Color color) => color == color.withAlpha(0xFF);

/// What the chat screen draws: the footer itself, following [style].
class GiovFooter extends StatelessWidget {
  const GiovFooter({super.key, required this.style, required this.onOpen});

  final GiovChatStyleOverrides style;
  final GiovUrlOpener onOpen;

  @override
  Widget build(BuildContext context) {
    final footer = resolveGiovFooterStyle(style,
        warn: kDebugMode ? (message) => debugPrint(message) : null);
    return Semantics(
      link: true,
      label: 'Powered by GiovChat',
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('giov-branding'),
        onTap: () => unawaited(onOpen(Uri.parse(
                'https://giovchat.app/?utm_source=flutter_widget&utm_medium=powered_by'))
            .catchError((Object _) => false)),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 44),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          decoration: BoxDecoration(
              color: footer.backgroundColor,
              border: Border(
                  top: BorderSide(
                      color: footer.customBackground
                          ? const Color(0x40808080)
                          : const Color(0xFFEBEBEB),
                      width: 0.5))),
          child: Text.rich(
            TextSpan(
              style: TextStyle(
                  color: footer.color,
                  fontSize: giovFooterFontSize,
                  fontFamily: footer.fontFamily),
              children: [
                const TextSpan(text: 'Powered by '),
                TextSpan(
                    text: 'GiovChat',
                    style: TextStyle(
                        color: footer.brandColor, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Drop-in "Powered by GiovChat" footer for apps that build their own chat screen on
/// [GiovChatController] or `GiovChatClient`. It follows the same [styleOverrides] as `GiovChat`
/// (`fontFamily` and `branding`); layout, size and text are fixed.
///
/// Whether it shows comes from the first of: [showBranding]; the [controller]'s workspace config;
/// the config fetched for [tenantKey]; otherwise it shows. It renders nothing while the setting
/// loads and when the plan removed branding (`showBranding: false`), and shows when the setting is
/// missing or cannot be loaded. Starter and Pro workspaces: please show it on your own screens.
class GiovBranding extends StatefulWidget {
  const GiovBranding({
    super.key,
    this.showBranding,
    this.controller,
    this.tenantKey,
    this.baseUrl = giovDefaultBaseUrl,
    this.styleOverrides = const GiovChatStyleOverrides(),
    this.onOpenUrl,
    this.httpClient,
  });

  final bool? showBranding;
  final GiovChatController? controller;
  final String? tenantKey;
  final String baseUrl;
  final GiovChatStyleOverrides styleOverrides;

  /// How the link opens (default: `url_launcher`).
  final GiovUrlOpener? onOpenUrl;

  /// For tests.
  final http.Client? httpClient;

  @override
  State<GiovBranding> createState() => _GiovBrandingState();
}

class _GiovBrandingState extends State<GiovBranding> {
  bool? _fetched;

  bool get _needsFetch =>
      widget.showBranding == null &&
      widget.controller == null &&
      widget.tenantKey != null;

  @override
  void initState() {
    super.initState();
    if (_needsFetch) unawaited(_fetch());
  }

  @override
  void didUpdateWidget(GiovBranding old) {
    super.didUpdateWidget(old);
    if (_needsFetch &&
        (old.tenantKey != widget.tenantKey ||
            old.baseUrl != widget.baseUrl ||
            old.showBranding != null ||
            old.controller != null)) {
      _fetched = null;
      unawaited(_fetch());
    }
  }

  Future<void> _fetch() async {
    final tenantKey = widget.tenantKey!;
    final baseUrl = widget.baseUrl;
    final client = GiovChatClient(
        tenantKey: tenantKey, baseUrl: baseUrl, httpClient: widget.httpClient);
    bool shown;
    try {
      shown = (await client.fetchWidgetConfig()).showBranding;
    } on Object {
      shown = true;
    } finally {
      client.dispose();
    }
    if (mounted && widget.tenantKey == tenantKey && widget.baseUrl == baseUrl) {
      setState(() => _fetched = shown);
    }
  }

  Widget _footer() => GiovFooter(
      style: widget.styleOverrides,
      onOpen: widget.onOpenUrl ?? defaultGiovUrlOpener);

  @override
  Widget build(BuildContext context) {
    final explicit = widget.showBranding;
    if (explicit != null) return explicit ? _footer() : const SizedBox.shrink();
    final controller = widget.controller;
    if (controller != null) {
      return ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final config = controller.config;
          if (config == null) {
            return controller.phase == GiovChatPhase.error
                ? _footer()
                : const SizedBox.shrink();
          }
          return config.showBranding ? _footer() : const SizedBox.shrink();
        },
      );
    }
    if (widget.tenantKey != null) {
      final fetched = _fetched;
      return fetched == null || !fetched ? const SizedBox.shrink() : _footer();
    }
    return _footer();
  }
}
