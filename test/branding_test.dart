// Flutter 3.47 deprecates package:flutter/material.dart, and SemanticsData.hasFlag since 3.32;
// the replacements don't exist on Flutter 3.22, which the SDK still supports.
// ignore_for_file: deprecated_member_use

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:giovchat/giovchat.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fakes.dart';

const _key = ValueKey('giov-branding');

/// The footer's background, "Powered by" style and "GiovChat" style.
({Color background, TextStyle text, TextStyle brand}) _footer(
    WidgetTester tester) {
  final container = tester
      .widget<Container>(find.descendant(
          of: find.byKey(_key), matching: find.byType(Container)))
      .decoration as BoxDecoration;
  final rich = tester.widget<RichText>(
      find.descendant(of: find.byKey(_key), matching: find.byType(RichText)));
  // Text.rich wraps our span in the inherited default style.
  final outer = rich.text as TextSpan;
  final root =
      outer.children!.length == 1 ? outer.children!.single as TextSpan : outer;
  final brand = root.children!.last as TextSpan;
  return (
    background: container.color!,
    text: root.style!,
    brand: brand.style!,
  );
}

Widget _app(Widget child) =>
    MaterialApp(home: Scaffold(body: Column(children: [child])));

http.Client _config(Object? showBranding, {bool fail = false}) =>
    MockClient((request) async {
      if (fail) throw http.ClientException('offline');
      return http.Response(
          jsonEncode({
            'title': 'Acme',
            'theme': 'light',
            'primaryColor': '#123456',
            'greetingText': 'Hi',
            if (showBranding != null) 'showBranding': showBranding,
          }),
          200,
          headers: {'content-type': 'application/json'});
    });

Future<void> _loaded(WidgetTester tester) async {
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await tester.pump();
}

GiovChatController _controller(FakeServer server) => GiovChatController(
      tenantKey: 't',
      baseUrl: 'https://api.example.test',
      locale: 'en',
      httpClient: server.client,
      socketFactory: (url) => FakeSocket(url, Duration.zero),
    );

void main() {
  group('resolveGiovFooterStyle', () {
    test('defaults, and the top-level font', () {
      final plain = resolveGiovFooterStyle(const GiovChatStyleOverrides());
      expect(plain.color, const Color(0xFF52525B));
      expect(plain.brandColor, const Color(0xFF7C3AED));
      expect(plain.backgroundColor, const Color(0xFFFFFFFF));
      expect(plain.fontFamily, isNull);
      expect(
          resolveGiovFooterStyle(
                  const GiovChatStyleOverrides(fontFamily: 'App'))
              .fontFamily,
          'App');
      expect(
          resolveGiovFooterStyle(const GiovChatStyleOverrides(
                  fontFamily: 'App',
                  branding: GiovBrandingOverride(fontFamily: 'Own')))
              .fontFamily,
          'Own');
    });

    test('readable overrides apply', () {
      final style = resolveGiovFooterStyle(const GiovChatStyleOverrides(
          branding: GiovBrandingOverride(
              color: Color(0xFF111827),
              brandColor: Color(0xFF1D4ED8),
              backgroundColor: Color(0xFFF1F5F9))));
      expect(style.color, const Color(0xFF111827));
      expect(style.brandColor, const Color(0xFF1D4ED8));
      expect(style.backgroundColor, const Color(0xFFF1F5F9));
      expect(style.customBackground, isTrue);
    });

    test(
        'low contrast falls back to the default for that property, with a warning',
        () {
      final warnings = <String>[];
      final style = resolveGiovFooterStyle(
          const GiovChatStyleOverrides(
              branding: GiovBrandingOverride(
                  color: Color(0xFFCCCCCC), brandColor: Color(0xFFEEEEEE))),
          warn: warnings.add);
      expect(style.color, const Color(0xFF52525B));
      expect(style.brandColor, const Color(0xFF7C3AED));
      expect(warnings, hasLength(2));
      // Exactly AA passes, just under fails.
      expect(
          resolveGiovFooterStyle(const GiovChatStyleOverrides(
                  branding: GiovBrandingOverride(color: Color(0xFF767676))))
              .color,
          const Color(0xFF767676));
      expect(
          resolveGiovFooterStyle(const GiovChatStyleOverrides(
                  branding: GiovBrandingOverride(color: Color(0xFF777777))))
              .color,
          const Color(0xFF52525B));
    });

    test('transparent and any alpha below 1 are ignored', () {
      for (final value in const [
        Color(0x00000000),
        Colors.transparent,
        Color(0x80000000),
        Color(0xFE000000),
      ]) {
        final text = resolveGiovFooterStyle(GiovChatStyleOverrides(
            branding: GiovBrandingOverride(color: value, brandColor: value)));
        expect(text.color, const Color(0xFF52525B), reason: '$value');
        expect(text.brandColor, const Color(0xFF7C3AED), reason: '$value');
        final background = resolveGiovFooterStyle(GiovChatStyleOverrides(
            branding: GiovBrandingOverride(backgroundColor: value)));
        expect(background.backgroundColor, const Color(0xFFFFFFFF));
        expect(background.customBackground, isFalse);
      }
      expect(
          resolveGiovFooterStyle(const GiovChatStyleOverrides(
                  branding: GiovBrandingOverride(color: Color(0xFF000000))))
              .color,
          const Color(0xFF000000));
    });

    test('contrast is judged against the own background of the app', () {
      final dark = resolveGiovFooterStyle(const GiovChatStyleOverrides(
          branding: GiovBrandingOverride(backgroundColor: Color(0xFF0F172A))));
      expect(dark.backgroundColor, const Color(0xFF0F172A));
      // The default ink is unreadable on navy, so black or white is used.
      expect(dark.color, const Color(0xFFFFFFFF));
      expect(dark.brandColor, const Color(0xFFFFFFFF));
      final styled = resolveGiovFooterStyle(const GiovChatStyleOverrides(
          branding: GiovBrandingOverride(
              backgroundColor: Color(0xFF0F172A),
              color: Color(0xFFE2E8F0),
              brandColor: Color(0xFFA5B4FC))));
      expect(styled.color, const Color(0xFFE2E8F0));
      expect(styled.brandColor, const Color(0xFFA5B4FC));
    });
  });

  group('GiovBranding', () {
    testWidgets('follows the style and keeps its size and text',
        (tester) async {
      await tester.pumpWidget(_app(const GiovBranding(
          showBranding: true,
          styleOverrides: GiovChatStyleOverrides(
              fontFamily: 'AppFont',
              branding: GiovBrandingOverride(
                  backgroundColor: Color(0xFFF1F5F9),
                  color: Color(0xFF111827),
                  brandColor: Color(0xFF1D4ED8))))));
      final footer = _footer(tester);
      expect(footer.background, const Color(0xFFF1F5F9));
      expect(footer.text.color, const Color(0xFF111827));
      expect(footer.text.fontFamily, 'AppFont');
      expect(footer.text.fontSize, 12);
      expect(footer.brand.color, const Color(0xFF1D4ED8));
      expect(find.bySemanticsLabel('Powered by GiovChat'), findsOneWidget);
    });

    testWidgets('showBranding false omits it, whatever the style',
        (tester) async {
      await tester.pumpWidget(_app(const GiovBranding(
          showBranding: false,
          styleOverrides: GiovChatStyleOverrides(
              branding: GiovBrandingOverride(color: Color(0xFF000000))))));
      expect(find.byKey(_key), findsNothing);
    });

    testWidgets('opens the Giov site', (tester) async {
      final opened = <Uri>[];
      await tester.pumpWidget(_app(GiovBranding(
          showBranding: true,
          onOpenUrl: (url) async {
            opened.add(url);
            return true;
          })));
      await tester.tap(find.byKey(_key));
      expect(opened.single.host, 'giovchat.app');
    });

    testWidgets('reads the workspace config from a tenant key', (tester) async {
      for (final entry in <(Object?, bool)>[
        (false, false),
        (true, true),
        (null, true),
      ]) {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
            _app(GiovBranding(tenantKey: 't', httpClient: _config(entry.$1))));
        expect(find.byKey(_key), findsNothing, reason: 'while loading');
        await _loaded(tester);
        expect(find.byKey(_key), entry.$2 ? findsOneWidget : findsNothing,
            reason: '${entry.$1}');
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_app(
          GiovBranding(tenantKey: 't', httpClient: _config(null, fail: true))));
      await _loaded(tester);
      expect(find.byKey(_key), findsOneWidget, reason: 'offline shows it');
    });

    testWidgets('follows the config of a controller', (tester) async {
      for (final hide in [false, true]) {
        final server = FakeServer(DateTime.now);
        server.config = {...server.config, if (hide) 'showBranding': false};
        final controller = _controller(server);
        await tester.pumpWidget(_app(GiovBranding(controller: controller)));
        expect(find.byKey(_key), findsNothing, reason: 'before config');
        await tester.runAsync(controller.start);
        await tester.pump();
        expect(find.byKey(_key), hide ? findsNothing : findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      }
    });

    testWidgets('shows without any source', (tester) async {
      await tester.pumpWidget(_app(const GiovBranding()));
      expect(find.byKey(_key), findsOneWidget);
    });
  });

  testWidgets('GiovChat applies the branding slot and keeps it on',
      (tester) async {
    final controller = _controller(FakeServer(DateTime.now));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: GiovChat(
      controller: controller,
      styleOverrides: const GiovChatStyleOverrides(
          fontFamily: 'AppFont',
          branding: GiovBrandingOverride(
              backgroundColor: Color(0xFF0F172A), color: Color(0xFFE2E8F0))),
    ))));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
    final footer = _footer(tester);
    expect(footer.background, const Color(0xFF0F172A));
    expect(footer.text.color, const Color(0xFFE2E8F0));
    expect(footer.text.fontFamily, 'AppFont');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.pump(const Duration(seconds: 1));
  });
}
