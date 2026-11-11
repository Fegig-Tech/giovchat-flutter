/// What every chat component shares: light/dark palette, brand colour, strings, style overrides,
/// and how links open. Provided by [GiovChat] through [GiovChatScope].
library;

import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/i18n.dart';
import '../core/markdown.dart';
import '../core/models.dart';
import 'style_overrides.dart';

/// Opens a link; resolves false when nothing could handle it.
typedef GiovUrlOpener = Future<bool> Function(Uri url);

Future<bool> defaultGiovUrlOpener(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } on Object {
    return false;
  }
}

/// `#rgb`, `#rrggbb` or `#aarrggbb`, else [fallback].
Color parseBrandColor(String? value,
    {Color fallback = const Color(0xFF7C3AED)}) {
  var hex = (value ?? '').trim();
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) return fallback;
  if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
  if (hex.length == 6) hex = 'ff$hex';
  if (hex.length != 8) return fallback;
  return Color(int.parse(hex, radix: 16));
}

/// The WCAG contrast ratio of two colours (1 to 21); a translucent [foreground] is first drawn on
/// [background].
double giovContrast(Color foreground, Color background) {
  final a = Color.alphaBlend(foreground, background).computeLuminance(),
      b = background.computeLuminance();
  return (a > b ? a + 0.05 : b + 0.05) / (a > b ? b + 0.05 : a + 0.05);
}

const _ink = Color(0xFF111111);
const _white = Color(0xFFFFFFFF);

/// White or near-black text on [background], whichever has the higher WCAG contrast.
Color giovReadableOn(Color background) =>
    giovContrast(_white, background) >= giovContrast(_ink, background)
        ? _white
        : _ink;

/// [preferred] for small secondary text when it reaches 4.5:1 on [background], else [fallback].
Color giovSecondaryOn(Color background, Color preferred, Color fallback) =>
    giovContrast(preferred, background) >= 4.5 ? preferred : fallback;

/// Only http(s) and mailto links are opened, whatever the text claims.
Future<void> openGiovLink(GiovUrlOpener open, String? href) async {
  if (!isOpenableHref(href)) return;
  final uri = Uri.tryParse(href!);
  if (uri == null) return;
  try {
    await open(uri);
  } on Object {
    // A link that cannot open is ignored.
  }
}

@immutable
class GiovLook {
  const GiovLook({
    required this.dark,
    required this.primary,
    required this.strings,
    required this.style,
    required this.openUrl,
    required this.attachmentUrl,
    this.botName,
    this.config,
  });

  final bool dark;
  final Color primary;
  final GiovChatStrings strings;
  final GiovChatStyleOverrides style;
  final GiovUrlOpener openUrl;

  /// Adds the download credential to an attachment URL.
  final String Function(String url) attachmentUrl;
  final String? botName;
  final GiovWidgetConfig? config;

  /// White or near-black, whichever reads on the brand colour.
  Color get onPrimary => giovReadableOn(primary);

  Color get background =>
      style.container ??
      (dark ? const Color(0xFF0A0A0A) : const Color(0xFFFFFFFF));
  Color get headerColor => style.header ?? primary;
  Color get buttonColor => style.button ?? primary;
  Color get visitorBubble => style.visitorBubble ?? primary;
  Color get agentBubble =>
      style.agentBubble ??
      (dark ? const Color(0xFF242424) : const Color(0xFFF0F0F0));
  Color get composerColor => style.composer ?? background;
  Color get divider => dark ? const Color(0xFF1E1E1E) : const Color(0xFFEBEBEB);
  Color get inputFill =>
      style.inputBackground ??
      (dark ? const Color(0xFF1C1C1C) : const Color(0xFFF5F5F5));
  Color get inputBorder =>
      dark ? const Color(0xFF2E2E2E) : const Color(0xFFE5E5E5);
  Color get text => dark ? const Color(0xFFF0F0F0) : const Color(0xFF111111);
  Color get secondaryText =>
      dark ? const Color(0xFFAAAAAA) : const Color(0xFF555555);
  Color get error => const Color(0xFFDC2626);

  /// Text on the visitor bubble: the override, else a colour that reads on the bubble.
  Color get onVisitorBubble =>
      style.visitorText?.color ?? giovReadableOn(visitorBubble);
  Color get onAgentBubble => style.agentText?.color ?? text;

  TextStyle get hintStyle => style.text(
      TextStyle(
          fontSize: 14,
          color: dark ? const Color(0xFF8A8A8A) : const Color(0xFF777777)),
      style.hint);
  TextStyle get errorStyle => style.text(
      TextStyle(fontSize: 14, height: 1.4, color: error), style.errorText);
  TextStyle get buttonTextStyle => style.text(
      TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: giovReadableOn(buttonColor)),
      style.buttonText);
}

class GiovChatScope extends InheritedWidget {
  const GiovChatScope({super.key, required this.look, required super.child});

  final GiovLook look;

  static GiovLook of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<GiovChatScope>();
    assert(
        scope != null, 'Giov chat components must be placed under a GiovChat.');
    return scope!.look;
  }

  @override
  bool updateShouldNotify(GiovChatScope oldWidget) => true;
}
