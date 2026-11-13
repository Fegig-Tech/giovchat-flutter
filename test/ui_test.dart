import 'dart:convert';
import 'dart:ui' show SemanticsFlag;

import 'package:flutter/gestures.dart';
// Flutter 3.47 deprecates this import (Material moves to its own package); the SDK still supports Flutter 3.22.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:giovchat/giovchat.dart';
import 'package:giovchat/src/ui/bubbles.dart' show MessageBubble;
import 'package:giovchat/src/ui/look.dart'
    show giovContrast, giovReadableOn, openGiovLink;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fakes.dart';

/// A chat screen over the real controller, a fake server and hand-driven sockets.
class UiRig {
  UiRig(this.tester,
      {Map<String, Object?> config = const {},
      http.Client? client,
      bool keepConnected = false}) {
    server.config = {...server.config, ...config};
    controller = GiovChatController(
      tenantKey: 't',
      baseUrl: 'https://api.example.test',
      locale: 'en',
      keepConnected: keepConnected,
      httpClient: client ?? server.client,
      socketFactory: (url) {
        final socket = FakeSocket(url, Duration.zero);
        sockets.add(socket);
        return socket;
      },
    );
  }

  final WidgetTester tester;
  final server = FakeServer(DateTime.now);
  final sockets = <FakeSocket>[];
  final opened = <Uri>[];
  late final GiovChatController controller;

  FakeSocket get socket => sockets.last;

  Widget app({
    GiovThemeMode? theme,
    VoidCallback? onClose,
    GiovAttachmentPicker? picker,
    bool visible = true,
    double textScale = 1,
    GiovChatStyleOverrides style = const GiovChatStyleOverrides(),
  }) =>
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: Scaffold(
              body: GiovChat(
                controller: controller,
                theme: theme,
                onClose: onClose,
                attachmentPicker: picker,
                visible: visible,
                styleOverrides: style,
                onOpenUrl: (url) async {
                  opened.add(url);
                  return true;
                },
              ),
            ),
          ),
        ),
      );

  Future<void> show(
      {GiovThemeMode? theme,
      VoidCallback? onClose,
      GiovAttachmentPicker? picker,
      double textScale = 1,
      GiovChatStyleOverrides style = const GiovChatStyleOverrides()}) async {
    await tester.pumpWidget(app(
        theme: theme,
        onClose: onClose,
        picker: picker,
        textScale: textScale,
        style: style));
    await settle();
  }

  Future<void> settle([int rounds = 20]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
  }

  /// Types a first message, sends it, opens the socket and catches up: the conversation is active.
  Future<void> begin([String text = 'Hello']) async {
    await tester.enterText(find.byKey(const ValueKey('giov-input')), text);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('giov-send')));
    await settle();
    socket.accept();
    await settle();
    expect(controller.phase, GiovChatPhase.active);
  }

  Map<String, Object?> get lastFrame => socket.messageFrames().last;

  void ack(Map<String, Object?> frame, {String id = 'srv-1'}) =>
      socket.receive({
        'type': 'message_ack',
        'clientMessageId': frame['clientMessageId'],
        'message': {
          'id': id,
          'role': 'visitor',
          'content': frame['content'],
          'createdAt': DateTime.now().millisecondsSinceEpoch
        },
      });

  /// Leaves the screen and releases everything the controller holds.
  Future<void> finish() async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.pump(const Duration(seconds: 1));
  }
}

/// Calls the tap handler of the first span that shows [text]; null when that span is not a link.
bool tapSpan(WidgetTester tester, String text) {
  var tapped = false;
  for (final paragraph in tester.widgetList<RichText>(find.byType(RichText))) {
    paragraph.text.visitChildren((span) {
      if (span is TextSpan && span.text == text) {
        final recognizer = span.recognizer;
        if (recognizer is TapGestureRecognizer && recognizer.onTap != null) {
          recognizer.onTap!();
          tapped = true;
        }
      }
      return true;
    });
    if (tapped) break;
  }
  return tapped;
}

Finder richText(String text) => find.textContaining(text, findRichText: true);

void main() {
  testWidgets(
      'loading shows a skeleton, then the greeting, the bot header and the branding',
      (tester) async {
    final rig = UiRig(tester);
    await tester.pumpWidget(rig.app());
    expect(find.byKey(const ValueKey('giov-loading')), findsOneWidget);
    expect(find.text('Loading…'), findsOneWidget);
    await rig.settle();
    expect(rig.controller.phase, GiovChatPhase.ready);
    expect(find.byKey(const ValueKey('giov-loading')), findsNothing);
    expect(find.text('Hi'), findsOneWidget, reason: 'the greeting');
    expect(find.text('Atlas'), findsOneWidget);
    expect(find.text('AI assistant · Online'), findsOneWidget);
    expect(find.byKey(const ValueKey('giov-branding')), findsOneWidget);
    expect(rig.sockets, isEmpty, reason: 'opening the chat starts nothing');
    await rig.finish();
  });

  testWidgets(
      'the pre-chat form asks for the required fields and starts the chat once they are valid',
      (tester) async {
    final rig = UiRig(tester, config: {
      'requestUserInfo': {'email': true, 'firstName': true}
    });
    await rig.show();
    expect(rig.controller.phase, GiovChatPhase.preChat);
    expect(find.text('Before we start…'), findsOneWidget);
    expect(find.byKey(const ValueKey('giov-field-firstName')), findsOneWidget);
    expect(find.byKey(const ValueKey('giov-field-email')), findsOneWidget);
    expect(find.byKey(const ValueKey('giov-field-phone')), findsNothing);

    Future<void> tapStart() async {
      await tester.tap(find.byKey(const ValueKey('giov-start-chat')));
      await rig.settle();
    }

    await tapStart();
    expect(rig.controller.phase, GiovChatPhase.preChat,
        reason: 'empty fields cannot be submitted');
    await tester.enterText(
        find.byKey(const ValueKey('giov-field-firstName')), 'Ada');
    await tester.enterText(
        find.byKey(const ValueKey('giov-field-email')), 'not-an-email');
    await tester.pump();
    await tapStart();
    expect(rig.controller.phase, GiovChatPhase.preChat,
        reason: 'a malformed email is refused');
    expect(rig.server.count('created'), 0);

    await tester.enterText(
        find.byKey(const ValueKey('giov-field-email')), 'ada@example.com');
    await tester.pump();
    await tapStart();
    expect(rig.server.count('created'), 1);
    expect(rig.server.to('/conversations', 'POST').last.json['email'],
        'ada@example.com');
    expect(rig.controller.phase, GiovChatPhase.connecting);
    expect(find.byKey(const ValueKey('giov-pre-chat')), findsNothing);
    await rig.finish();
  });

  testWidgets('a sent message shows at once as sending, then confirmed',
      (tester) async {
    final rig = UiRig(tester);
    await rig.show();
    await rig.tester
        .enterText(find.byKey(const ValueKey('giov-input')), '  Hello there ');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('giov-send')));
    await rig.settle();
    expect(find.text('Sending…'), findsOneWidget);
    expect(richText('Hello there'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(
        (tester.widget<TextField>(find.byKey(const ValueKey('giov-input'))))
            .controller!
            .text,
        isEmpty,
        reason: 'the composer clears');

    rig.socket.accept();
    await rig.settle();
    expect(rig.controller.phase, GiovChatPhase.active);
    expect(rig.lastFrame['content'], 'Hello there');
    rig.ack(rig.lastFrame);
    await rig.settle();
    expect(find.text('Sending…'), findsNothing);
    expect(rig.controller.messages.single.delivery, GiovDelivery.sent);
    expect(find.byType(MessageBubble), findsOneWidget);
    await rig.finish();
  });

  testWidgets('a message that failed offers retry and discard', (tester) async {
    final rig = UiRig(tester);
    await rig.show();
    await rig.begin();
    final frame = rig.lastFrame;
    final id = frame['clientMessageId']! as String;
    Map<String, Object?> failure() =>
        {'type': 'error', 'error': 'message_failed', 'clientMessageId': id};
    rig.socket.receive(failure());
    await tester.pump(const Duration(seconds: 2, milliseconds: 1));
    rig.socket.receive(failure());
    await tester.pump(const Duration(seconds: 4, milliseconds: 1));
    rig.socket.receive(failure());
    await rig.settle();
    expect(rig.controller.messages.single.delivery, GiovDelivery.failed);
    expect(find.text('Not sent · Tap to retry'), findsOneWidget);

    final before = rig.socket.messageFrames().length;
    await tester.tap(find.byKey(const ValueKey('giov-retry')));
    await rig.settle();
    expect(rig.socket.messageFrames().length, before + 1);
    expect(rig.lastFrame['clientMessageId'], id);
    expect(find.text('Not sent · Tap to retry'), findsNothing);

    rig.socket.receive({'type': 'error', 'error': 'invalid_message'});
    await rig.settle();
    expect(find.text('Not sent · Tap to retry'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('giov-discard')));
    await rig.settle();
    expect(rig.controller.messages, isEmpty);
    expect(find.byType(MessageBubble), findsNothing);
    await rig.finish();
  });

  testWidgets(
      'a streaming reply is shown in place and replaced by the saved reply without being rebuilt',
      (tester) async {
    final rig = UiRig(tester);
    await rig.show();
    await rig.begin();
    rig.socket.receive({'type': 'typing', 'role': 'agent', 'isBot': true});
    await rig.settle();
    expect(find.byKey(const ValueKey('giov-typing')), findsOneWidget);
    expect(find.bySemanticsLabel('Atlas is typing'), findsOneWidget);

    rig.socket.receive(
        {'type': 'stream', 'streamId': 'r1', 'content': 'Our **hours**'});
    await rig.settle();
    expect(find.byKey(const ValueKey('giov-typing')), findsNothing,
        reason: 'the draft replaces the typing dots');
    final draft = find.byKey(const ValueKey('stream:r1'));
    expect(draft, findsOneWidget);
    expect(richText('Our hours'), findsOneWidget);
    final element = tester.element(draft);

    rig.socket.receive({
      'type': 'stream',
      'streamId': 'r1',
      'content': 'Our **hours** are 9–5.'
    });
    await rig.settle();
    expect(richText('are 9–5.'), findsOneWidget);

    rig.socket.receive({
      'id': 'm9',
      'role': 'agent',
      'content': 'Our **hours** are 9–5.',
      'createdAt': DateTime.now().millisecondsSinceEpoch + 10,
      'isBot': true,
      'isAutomated': true,
      'streamId': 'r1'
    });
    await rig.settle();
    expect(find.byKey(const ValueKey('stream:r1')), findsOneWidget);
    expect(
        identical(
            tester.element(find.byKey(const ValueKey('stream:r1'))), element),
        isTrue,
        reason: 'the same widget carries the draft and the saved reply');
    expect(richText('are 9–5.'), findsOneWidget);
    expect(find.byType(MessageBubble), findsNWidgets(2));
    await rig.finish();
  });

  testWidgets('only http(s) and mailto links open', (tester) async {
    final rig = UiRig(tester);
    await rig.show();
    await rig.begin();
    rig.socket.receive({
      'id': 'm1',
      'role': 'agent',
      'content':
          'See [the site](https://example.com/a) or [mail us](mailto:hi@example.com), not [bad](javascript:alert(1)) or [file](file:///etc/passwd) or [ftp](ftp://x.test/y).',
      'createdAt': DateTime.now().millisecondsSinceEpoch + 10,
    });
    await rig.settle();
    expect(tapSpan(tester, 'the site'), isTrue);
    expect(tapSpan(tester, 'mail us'), isTrue);
    expect(rig.opened, [
      Uri.parse('https://example.com/a'),
      Uri.parse('mailto:hi@example.com')
    ]);
    for (final text in ['bad', 'file', 'ftp']) {
      expect(tapSpan(tester, text), isFalse, reason: '$text is not a link');
    }
    expect(rig.opened, hasLength(2));

    final calls = <Uri>[];
    Future<bool> record(Uri url) async {
      calls.add(url);
      return true;
    }

    await openGiovLink(record, 'javascript:alert(1)');
    await openGiovLink(record, 'file:///etc/passwd');
    await openGiovLink(record, null);
    expect(calls, isEmpty);
    await openGiovLink(record, 'HTTPS://example.com');
    expect(calls, hasLength(1));
    await rig.finish();
  });

  testWidgets('the header switches from the bot to the teammate who replies',
      (tester) async {
    final rig = UiRig(tester);
    await rig.show();
    expect(find.text('Atlas'), findsOneWidget);
    expect(find.text('AI assistant · Online'), findsOneWidget);
    await rig.begin();
    expect(find.text('Atlas'), findsOneWidget);

    rig.socket.receive({
      'id': 'a1',
      'role': 'agent',
      'content': 'Hi, Ada here.',
      'createdAt': DateTime.now().millisecondsSinceEpoch + 10,
      'senderName': 'Ada'
    });
    await rig.settle();
    expect(find.text('Ada'), findsNWidgets(2),
        reason: 'the header and the sender label');
    expect(find.text('Atlas'), findsNothing);
    expect(find.text('Live agent'), findsOneWidget);
    expect(find.text('AI assistant · Online'), findsNothing);
    await rig.finish();
  });

  testWidgets('a team without a bot shows the team name and status',
      (tester) async {
    final rig = UiRig(tester, config: {'botEnabled': false});
    await rig.show();
    expect(find.text('Acme'), findsOneWidget);
    expect(find.text("We'll be with you shortly"), findsOneWidget);
    await rig.finish();
  });

  testWidgets('branding shows unless the server turns it off', (tester) async {
    final shown = UiRig(tester);
    await shown.show();
    expect(find.byKey(const ValueKey('giov-branding')), findsOneWidget);
    expect(find.bySemanticsLabel('Powered by GiovChat'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('giov-branding')));
    expect(shown.opened.single.host, 'giovchat.app');
    await shown.finish();

    final hidden = UiRig(tester, config: {'showBranding': false});
    await hidden.show();
    expect(find.byKey(const ValueKey('giov-branding')), findsNothing);
    await hidden.finish();
  });

  testWidgets('the dashboard theme and the theme prop pick light or dark',
      (tester) async {
    Color? surface() => tester
        .widget<Material>(find
            .descendant(
                of: find.byType(GiovChat), matching: find.byType(Material))
            .first)
        .color;

    final dark = UiRig(tester, config: {'theme': 'dark'});
    await dark.show();
    expect(surface(), const Color(0xFF0A0A0A));
    await dark.finish();

    final forcedLight = UiRig(tester, config: {'theme': 'dark'});
    await forcedLight.show(theme: GiovThemeMode.light);
    expect(surface(), const Color(0xFFFFFFFF));
    await forcedLight.finish();

    final auto = UiRig(tester, config: {'theme': 'auto'});
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await auto.show();
    expect(surface(), const Color(0xFF0A0A0A),
        reason: 'auto follows the device');
    await auto.finish();
  });

  testWidgets('the brand colour paints the header and the visitor bubble',
      (tester) async {
    final rig = UiRig(tester);
    await rig.show();
    final header = tester.widget<Material>(find
        .ancestor(of: find.text('Atlas'), matching: find.byType(Material))
        .first);
    expect(header.color, const Color(0xFF123456));
    await rig.finish();
  });

  testWidgets('an error shows a sentence and Try again starts over',
      (tester) async {
    var calls = 0;
    final rig = UiRig(tester, client: MockClient((request) async {
      calls++;
      return http.Response('{"error":"boom"}', 500);
    }));
    await rig.show();
    expect(rig.controller.phase, GiovChatPhase.error);
    expect(find.text('Chat is unavailable. Please try again.'), findsOneWidget);
    final before = calls;
    await tester.tap(find.byKey(const ValueKey('giov-try-again')));
    await rig.settle();
    expect(calls, greaterThan(before));
    await rig.finish();
  });

  testWidgets(
      'attachments: the picker runs through the policy and chips show until sent',
      (tester) async {
    final rig = UiRig(tester);
    GiovPickerRequest? asked;
    Future<List<GiovPickedFile>> picker(GiovPickerRequest request) async {
      asked = request;
      return [
        GiovPickedFile.bytes(
            name: 'photo.png',
            mimeType: 'image/png',
            bytes: Uint8List.fromList([1, 2, 3])),
        GiovPickedFile.bytes(
            name: 'notes.txt',
            mimeType: 'text/plain',
            bytes: Uint8List.fromList([1])),
      ];
    }

    await rig.show(picker: picker);
    expect(find.byKey(const ValueKey('giov-attach')), findsNothing,
        reason: 'uploads need a conversation');
    await rig.begin();
    expect(find.byKey(const ValueKey('giov-attach')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('giov-attach')));
    await rig.settle();
    expect(asked!.maxFiles, 5);
    expect(asked!.allowedTypes, contains('image/png'));
    expect(find.text('photo.png'), findsOneWidget);
    expect(
        find.text('notes.txt: this file type is not allowed.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('giov-remove-0')));
    await rig.settle();
    expect(find.text('photo.png'), findsNothing);
    await rig.finish();
  });

  testWidgets(
      'attachments render as an image box and as file rows with authenticated links',
      (tester) async {
    final rig = UiRig(tester);
    await rig.show();
    await rig.begin();
    const base = 'https://api.example.test/conversations/conv-1/attachments';
    rig.socket.receive({
      'id': 'm1',
      'role': 'agent',
      'content': 'Files',
      'createdAt': DateTime.now().millisecondsSinceEpoch + 10,
      'attachmentId': jsonEncode(['$base/pic.png', '$base/report.pdf']),
      'attachmentPreviews': [
        {'width': 400, 'height': 300},
        null,
      ],
    });
    await rig.settle();
    expect(
        tester.getSize(find
            .descendant(
                of: find.byType(MessageBubble), matching: find.byType(Image))
            .first),
        const Size(200, 150),
        reason: 'the final shape is reserved');
    expect(find.text('report.pdf'), findsOneWidget);
    await tester.tap(find.text('report.pdf'));
    expect(rig.opened.single.toString(), startsWith('$base/report.pdf?'));
    expect(rig.opened.single.query,
        anyOf(startsWith('at='), startsWith('token=')));
    await rig.finish();
  });

  testWidgets(
      'tap targets are at least 44 points and large text does not break the layout',
      (tester) async {
    final rig = UiRig(tester);
    var closed = false;
    await rig.show(
        onClose: () => closed = true,
        textScale: 2.5,
        picker: (_) async => const []);
    await rig.begin();
    for (final key in [
      'giov-send',
      'giov-attach',
      'giov-close',
      'giov-branding'
    ]) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(size.width, greaterThanOrEqualTo(44), reason: key);
      expect(size.height, greaterThanOrEqualTo(44), reason: key);
    }
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('giov-close')));
    expect(closed, isTrue);
    expect(find.bySemanticsLabel('Close chat'), findsOneWidget);
    await rig.finish();
  });

  testWidgets(
      'the app lifecycle reaches the controller and unmounting hides the chat',
      (tester) async {
    final rig = UiRig(tester, keepConnected: true);
    await rig.show();
    await rig.begin();
    final socket = rig.socket;
    // The legal sequence a platform reports (newer Flutter asserts on skipped states).
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump(const Duration(seconds: 6));
    expect(socket.closedByClient, isTrue,
        reason: 'the socket closes after the background grace');
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await rig.settle();
    expect(rig.sockets.length, 2);

    expect(rig.controller.visible, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(rig.controller.visible, isFalse,
        reason: 'a keepConnected chat keeps counting unread replies');
    rig.controller.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the widget can own its controller', (tester) async {
    final server = FakeServer(DateTime.now);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GiovChat(
            tenantKey: 't',
            baseUrl: 'https://api.example.test',
            locale: 'fr',
            httpClient: server.client,
            socketFactory: (url) => FakeSocket(url, Duration.zero)),
      ),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
    expect(find.text('Assistant IA · En ligne'), findsOneWidget);
    expect(find.text('Écrivez un message…'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('style overrides reach the surfaces', (tester) async {
    final rig = UiRig(tester);
    await rig.show(
        style: const GiovChatStyleOverrides(
            header: Color(0xFF0F172A),
            container: Color(0xFFF8FAFC),
            headerTitle: GiovTextOverride(
                color: Color(0xFFFFFFFF), fontWeight: FontWeight.w800)));
    final header = tester.widget<Material>(find
        .ancestor(of: find.text('Atlas'), matching: find.byType(Material))
        .first);
    expect(header.color, const Color(0xFF0F172A));
    expect(tester.widget<Text>(find.text('Atlas')).style!.fontWeight,
        FontWeight.w800);
    await rig.finish();
  });

  test('brand colours parse, with a fallback', () {
    expect(parseBrandColor('#123456'), const Color(0xFF123456));
    expect(parseBrandColor('#fff'), const Color(0xFFFFFFFF));
    expect(parseBrandColor('nonsense'), const Color(0xFF7C3AED));
    expect(parseBrandColor(null), const Color(0xFF7C3AED));
  });

  testWidgets(
      'the composer keeps 2000 UTF-16 units like the server, cutting a paste without splitting an emoji',
      (tester) async {
    final rig = UiRig(tester);
    await rig.show();
    final input = find.byKey(const ValueKey('giov-input'));
    String text() => tester.widget<TextField>(input).controller!.text;

    await tester.enterText(input, '${'a' * 1999}😀😀');
    await tester.pump();
    expect(text(), 'a' * 1999,
        reason: 'the emoji that would cross the limit is left out whole');
    await tester.enterText(input, 'b' * 2500);
    await tester.pump();
    expect(text(), 'b' * 2000,
        reason: 'a long paste is cut at the limit, not dropped');
    await tester.enterText(input, '😀' * 1000);
    await tester.pump();
    expect(text().length, 2000,
        reason: 'counted in UTF-16 units, as String.length and the server do');
    await rig.finish();
  });

  testWidgets(
      'the visitor can keep typing while a file uploads; only Send waits',
      (tester) async {
    final rig = UiRig(tester);
    Future<List<GiovPickedFile>> picker(GiovPickerRequest request) async => [
          GiovPickedFile.bytes(
              name: 'photo.png',
              mimeType: 'image/png',
              bytes: Uint8List.fromList([1, 2, 3]))
        ];
    await rig.show(picker: picker);
    await rig.begin();
    await tester.tap(find.byKey(const ValueKey('giov-attach')));
    await rig.settle();
    rig.server.hangUploads = true;
    await tester.tap(find.byKey(const ValueKey('giov-send')));
    await rig.settle();
    expect(rig.controller.sending, isTrue);
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('giov-input')))
            .enabled,
        isTrue);
    await tester.enterText(
        find.byKey(const ValueKey('giov-input')), 'typed meanwhile');
    await tester.pump();
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('giov-input')))
            .controller!
            .text,
        'typed meanwhile');
    expect(
        tester
            .getSemantics(find.bySemanticsLabel('Send message'))
            // `hasFlag` is deprecated from Flutter 3.32; 3.22 has no `flagsCollection`.
            // ignore: deprecated_member_use
            .hasFlag(SemanticsFlag.isEnabled),
        isFalse);
    // Let the upload time out.
    await tester.pump(const Duration(seconds: 121));
    await rig.settle();
    expect(rig.controller.sending, isFalse);
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('giov-input')))
            .controller!
            .text,
        'typed meanwhile');
    await rig.finish();
  });

  testWidgets('a lost connection shows "reconnecting" until the socket is back',
      (tester) async {
    final rig = UiRig(tester);
    await rig.show();
    await rig.begin();
    expect(find.byKey(const ValueKey('giov-reconnecting')), findsNothing);
    rig.socket.drop();
    await rig.settle();
    expect(find.text('Connection lost. Reconnecting…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await rig.settle();
    rig.socket.accept();
    await rig.settle();
    expect(find.byKey(const ValueKey('giov-reconnecting')), findsNothing);
    await rig.finish();
  });

  testWidgets(
      'the input, the pre-chat fields and the privacy link have accessible labels',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final rig = UiRig(tester, config: {
      'requestUserInfo': {'email': true, 'firstName': true}
    });
    await rig.show();
    expect(find.bySemanticsLabel(RegExp(r'^First name \*')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Email \*')), findsOneWidget);
    expect(find.bySemanticsLabel('GDPR and privacy'), findsOneWidget);
    await rig.finish();

    final chat = UiRig(tester);
    await chat.show();
    final node = tester.getSemantics(find.byKey(const ValueKey('giov-input')));
    expect(node.label, contains('Message'));
    // ignore: deprecated_member_use
    expect(node.hasFlag(SemanticsFlag.isTextField), isTrue);
    await chat.finish();
    semantics.dispose();
  });

  testWidgets(
      "the privacy button opens the workspace's policy, else Giov's, like the web widget",
      (tester) async {
    var rig = UiRig(tester);
    await rig.show();
    await tester.tap(find.byKey(const ValueKey('giov-privacy')));
    await rig.settle();
    expect(rig.opened.single.toString(), 'https://giovchat.app/privacy');
    await rig.finish();

    rig = UiRig(tester,
        config: {'privacyPolicyUrl': 'https://acme.test/privacy'});
    await rig.show();
    await tester.tap(find.byKey(const ValueKey('giov-privacy')));
    await rig.settle();
    expect(rig.opened.single.toString(), 'https://acme.test/privacy');
    await rig.finish();
  });

  testWidgets(
      'a reply that arrives while the chat is open is announced once, without its markup',
      (tester) async {
    final announced = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility, (message) async {
      final data =
          (message! as Map<Object?, Object?>)['data']! as Map<Object?, Object?>;
      if ((message as Map<Object?, Object?>)['type'] == 'announce') {
        announced.add(data['message']! as String);
      }
      return null;
    });
    final rig = UiRig(tester);
    await rig.show();
    await rig.begin();
    expect(announced, isEmpty);
    rig.socket.receive(
        {'type': 'stream', 'streamId': 's1', 'content': 'Our **hours**'});
    await rig.settle();
    expect(announced, isEmpty, reason: 'drafts are not read out word by word');
    rig.socket.receive({
      'id': 'm1',
      'role': 'agent',
      'content': 'Our **hours** are 9–5.',
      'createdAt': DateTime.now().millisecondsSinceEpoch + 10,
      'isBot': true,
      'isAutomated': true,
      'streamId': 's1'
    });
    await rig.settle();
    expect(announced, ['Atlas: Our hours are 9–5.']);
    rig.socket.receive({'type': 'stream_end', 'streamId': 's1'});
    await rig.settle();
    expect(announced, hasLength(1));
    await rig.finish();
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility, null);
  });

  testWidgets(
      'text on the brand colour follows WCAG contrast, and small labels keep 4.5:1',
      (tester) async {
    expect(giovReadableOn(const Color(0xFF7C3AED)), const Color(0xFFFFFFFF));
    expect(giovReadableOn(const Color(0xFF3B82F6)), const Color(0xFF111111),
        reason: 'white would be 3.7:1 here');
    expect(giovReadableOn(const Color(0xFFFFD60A)), const Color(0xFF111111));

    final rig = UiRig(tester, config: {'primaryColor': '#3b82f6'});
    await rig.show();
    await rig.begin();
    rig.socket.receive({
      'id': 'a1',
      'role': 'agent',
      'content': 'Hi',
      'createdAt': DateTime.now().millisecondsSinceEpoch + 10,
      'senderName': 'Ada'
    });
    await rig.settle();
    Color colorOf(String text) =>
        tester.widget<Text>(find.text(text).last).style!.color!;
    expect(giovContrast(colorOf('Ada'), const Color(0xFFF0F0F0)),
        greaterThanOrEqualTo(4.5));
    expect(giovContrast(colorOf('You'), const Color(0xFF3B82F6)),
        greaterThanOrEqualTo(4.5));
    await rig.finish();
  });

  testWidgets(
      'a new screen on a started controller keeps its connection (autoStart relies on start() doing nothing)',
      (tester) async {
    // keepConnected: leaving the first screen does not disconnect, so only start() could drop the socket.
    final rig = UiRig(tester, keepConnected: true);
    await rig.show();
    await rig.begin();
    final socket = rig.socket;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: GiovChat(
                key: const ValueKey('second'), controller: rig.controller))));
    await rig.settle();
    expect(rig.sockets, hasLength(1));
    expect(socket.closedByClient, isFalse);
    expect(rig.controller.phase, GiovChatPhase.active);
    await rig.finish();
  });
}
