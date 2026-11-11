import 'package:flutter_test/flutter_test.dart';
import 'package:giovchat/giovchat.dart';

GiovWidgetConfig config({bool botEnabled = true, String? botName = 'Atlas'}) =>
    GiovWidgetConfig(
      title: 'Acme support',
      botEnabled: botEnabled,
      botName: botName,
      botAvatarUrl: 'https://cdn.test/atlas.png',
      avatarUrl: 'https://cdn.test/team.png',
    );

GiovMessage message(
        {GiovRole role = GiovRole.agent,
        bool isBot = false,
        bool isAutomated = false,
        String? senderName}) =>
    GiovMessage(
        id: 'm',
        role: role,
        content: 'x',
        createdAt: 1,
        isBot: isBot,
        isAutomated: isAutomated,
        senderName: senderName);

void main() {
  group('header identity', () {
    test(
        'the person once one takes over, else the bot while it answers, else the team',
        () {
      expect(
          headerIdentity(config(),
              agentName: 'Ada', agentAvatar: 'https://cdn.test/ada.png'),
          const GiovHeaderIdentity(
              kind: GiovHeaderKind.person,
              title: 'Ada',
              avatar: 'https://cdn.test/ada.png'));
      expect(
          headerIdentity(config()),
          const GiovHeaderIdentity(
              kind: GiovHeaderKind.bot,
              title: 'Atlas',
              avatar: 'https://cdn.test/atlas.png'));
      expect(
          headerIdentity(config(botEnabled: false)),
          const GiovHeaderIdentity(
              kind: GiovHeaderKind.team,
              title: 'Acme support',
              avatar: 'https://cdn.test/team.png'));
      expect(headerIdentity(config(botName: null)).kind, GiovHeaderKind.team);
      expect(
          headerIdentity(config(),
                  agentName: 'Ada', agentAvatar: 'javascript:alert(1)')
              .avatar,
          isNull,
          reason: 'only http(s) images load');
      expect(headerIdentity(config(), agentName: 'Ada').avatar, isNull);
      expect(headerIdentity(config(), agentName: '').kind, GiovHeaderKind.bot,
          reason: 'an empty name is no person');
    });

    test('status lines come from the strings', () {
      final strings = giovStrings['en']!;
      expect(headerIdentity(config(), agentName: 'Ada').status(strings),
          'Live agent');
      expect(headerIdentity(config()).status(strings), 'AI assistant · Online');
      expect(headerIdentity(config(botEnabled: false)).status(strings),
          "We'll be with you shortly");
    });
  });

  group('sender labels', () {
    final strings = giovStrings['en']!;
    test('AI identity wins over automated, people by name, visitors as you',
        () {
      expect(
          messageSenderLabel(message(isBot: true, isAutomated: true), strings,
              botName: 'Atlas'),
          'Atlas');
      expect(messageSenderLabel(message(isBot: true), strings, botName: ' '),
          'GiovBot');
      expect(
          messageSenderLabel(
              message(isAutomated: true, senderName: 'x'), strings),
          'Automated');
      expect(messageSenderLabel(message(senderName: ' Ada '), strings), 'Ada');
      expect(messageSenderLabel(message(), strings, agentName: 'Bola'), 'Bola');
      expect(messageSenderLabel(message(), strings), 'Agent');
      expect(
          messageSenderLabel(
              message(role: GiovRole.visitor, isBot: true), strings),
          'You');
    });
  });

  group('typing', () {
    test(
        'only explicit server AI metadata brands it; a mismatched end keeps the other indicator',
        () {
      var state = const GiovTypingState();
      state = reduceAgentTyping(
          state, {'type': 'typing', 'role': 'agent', 'isBot': true});
      expect(state, const GiovTypingState(visible: true, isBot: true));
      expect(
          reduceAgentTyping(
              state, {'type': 'typing_end', 'role': 'agent', 'isBot': false}),
          state);
      expect(reduceAgentTyping(state, {'type': 'typing_end', 'role': 'agent'}),
          const GiovTypingState());
      expect(reduceAgentTyping(state, {'type': 'typing', 'role': 'visitor'}),
          state);
      expect(
          reduceAgentTyping(const GiovTypingState(),
              {'type': 'typing', 'role': 'agent', 'isBot': 'true'}),
          const GiovTypingState(visible: true));
    });
  });

  group('i18n', () {
    test('every shipped language builds every string, and none is empty', () {
      expect(giovStrings.keys.toSet(), giovLocales.toSet());
      for (final entry in giovStrings.entries) {
        final s = entry.value;
        final plain = [
          s.loading,
          s.tryAgain,
          s.retry,
          s.closeChat,
          s.connecting,
          s.reconnecting,
          s.statusPerson,
          s.statusBot,
          s.statusTeam,
          s.composerPlaceholder,
          s.messageInput,
          s.sendMessage,
          s.attachFile,
          s.you,
          s.agent,
          s.automated,
          s.teamTyping,
          s.sending,
          s.notSent,
          s.tapToRetry,
          s.uploadFailed,
          s.sessionExpired,
          s.conversationEnded,
          s.unavailable,
          s.sendFailed,
          s.busy,
          s.attachmentsOff,
          s.attachment,
          s.image,
          s.preChatTitle,
          s.firstName,
          s.lastName,
          s.email,
          s.phone,
          s.startChat,
          s.removeAttachment('f.png'),
          s.botTyping('Atlas'),
          s.uploading(42),
          s.typeNotAllowed('a.pdf'),
          s.fileTooLarge('a.pdf', 5),
          s.tooManyFiles(5),
          s.openAttachment('a.pdf'),
          s.required('Email'),
        ];
        for (final text in plain) {
          expect(text.trim(), isNotEmpty, reason: entry.key);
        }
        expect(s.botTyping('Atlas'), contains('Atlas'), reason: entry.key);
        expect(s.uploading(42), contains('42'), reason: entry.key);
        expect(
            s.fileTooLarge('a.pdf', 5), allOf(contains('a.pdf'), contains('5')),
            reason: entry.key);
        expect(s.fileTooLarge('a.pdf', 2.5), contains('2.5'));
        expect(s.tooManyFiles(5), contains('5'), reason: entry.key);
      }
      expect(giovStrings['fr']!.typeNotAllowed('a.pdf'),
          "a.pdf : ce type de fichier n'est pas autorisé.");
      expect(giovStrings['de']!.uploading(42), 'Wird hochgeladen: 42 %');
      expect(giovStrings['en']!.statusBot, 'AI assistant · Online');
    });

    test('locale resolution', () {
      expect(resolveGiovLocale('fr-CA'), 'fr');
      expect(resolveGiovLocale('pt_BR'), 'pt');
      expect(resolveGiovLocale('DE'), 'de');
      expect(resolveGiovLocale('ja-JP'), 'en');
      expect(resolveGiovLocale(null), 'en');
      expect(resolveGiovStrings(locale: 'es').you, 'Tú');
      expect(resolveGiovStrings().loading, isNotEmpty,
          reason: 'device locale falls back to a shipped language');
    });

    test('host overrides replace strings; empty ones are ignored', () {
      final strings = resolveGiovStrings(
        locale: 'es',
        override: (base) => base.copyWith(
            sendMessage: 'Mandar', tryAgain: '', botTyping: (name) => '$name…'),
      );
      expect(strings.sendMessage, 'Mandar');
      expect(strings.tryAgain, giovStrings['es']!.tryAgain);
      expect(strings.botTyping('Atlas'), 'Atlas…');
      expect(strings.you, giovStrings['es']!.you);
      expect(identical(resolveGiovStrings(locale: 'en'), giovStrings['en']),
          isTrue);
    });

    test('failures map to sentences, never server text', () {
      final strings = giovStrings['en']!;
      expect(strings.describeError(const GiovSessionExpiredException('x')),
          strings.sessionExpired);
      expect(strings.describeError(const GiovConversationClosedException('x')),
          strings.conversationEnded);
      expect(
          strings.describeError(const GiovWorkspaceBusyException('x',
              retryAfter: Duration(seconds: 30))),
          strings.busy);
      expect(strings.describeError(const GiovNetworkException('boom')),
          strings.unavailable);
    });
  });

  group('session scope', () {
    test('differs per workspace and visitor identity', () {
      final a = giovSessionScope('https://api.test/', 't',
          contact: const GiovContact(userId: 'u1'));
      expect(
          a,
          giovSessionScope('https://api.test', 't',
              contact: const GiovContact(userId: 'u1')));
      expect(
          a,
          isNot(giovSessionScope('https://api.test', 't',
              contact: const GiovContact(userId: 'u2'))));
      expect(
          a,
          isNot(giovSessionScope('https://api.test', 'other',
              contact: const GiovContact(userId: 'u1'))));
    });

    test('contact start fields carry userId + userHash and skip empty values',
        () {
      expect(
          const GiovContact(
                  userId: 'u1', userHash: 'ab', email: ' ', firstName: ' Ada ')
              .toStartFields(),
          {'userId': 'u1', 'userHash': 'ab', 'firstName': 'Ada'});
    });
  });
}
