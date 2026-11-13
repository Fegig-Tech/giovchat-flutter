import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show AppLifecycleState;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:giovchat/giovchat.dart';

import 'support/fakes.dart';

class CRig {
  CRig(
    this.async, {
    bool visible = true,
    this.keepConnected = false,
    this.contact,
    GiovSession? stored,
    RecordingStore? store,
    Duration grace = const Duration(seconds: 5),
  }) {
    now = () => epoch.add(async.elapsed);
    server = FakeServer(now);
    sockets = Sockets(async);
    this.store = store ?? RecordingStore();
    if (stored != null) {
      unawaited(this.store.write(
          giovSessionScope('https://api.example.test', 't', contact: contact),
          stored));
      async.flushMicrotasks();
      this.store.log.clear();
    }
    controller = GiovChatController(
      tenantKey: 't',
      baseUrl: 'https://api.example.test',
      contact: contact,
      sessionStore: this.store,
      keepConnected: keepConnected,
      visible: visible,
      locale: 'en',
      backgroundGrace: grace,
      httpClient: server.client,
      socketFactory: sockets.create,
      now: now,
      random: NoJitter(),
      onError: errors.add,
      onUnreadCountChange: unread.add,
      onConversationStart: started.add,
    );
  }

  final FakeAsync async;
  final bool keepConnected;
  final GiovContact? contact;
  late final DateTime Function() now;
  late final FakeServer server;
  late final Sockets sockets;
  late final RecordingStore store;
  late final GiovChatController controller;
  final errors = <GiovChatException>[];
  final unread = <int>[];
  final started = <String>[];

  GiovChatPhase get phase => controller.phase;
  FakeSocket get socket => sockets.last;

  void pump([int rounds = 12]) {
    for (var i = 0; i < rounds; i++) {
      async.flushMicrotasks();
      async.elapse(Duration.zero);
    }
  }

  void start() {
    unawaited(controller.start());
    pump();
  }

  /// The socket opens and the catch-up runs.
  void open() {
    socket.accept();
    pump();
  }

  /// Protocol v1: the first message starts the conversation; wait until connected and caught up.
  void begin([String text = 'Hi']) {
    expect(phase, GiovChatPhase.ready,
        reason: 'opening the chat creates nothing');
    expect(server.count('created'), 0);
    expect(settle(async, controller.send(text)), isTrue);
    pump();
    open();
    expect(phase, GiovChatPhase.active);
    expect(server.count('created'), 1);
  }

  void dispose() {
    controller.dispose();
  }
}

void main() {
  test(
      'opening the chat creates nothing; the first message starts the conversation and goes out after the history catch-up',
      () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.start();
      expect(rig.phase, GiovChatPhase.ready);
      expect(rig.controller.config!.title, 'Acme');
      expect(rig.server.count('created'), 0);
      expect(rig.sockets.all, isEmpty);
      expect(rig.controller.header!.kind, GiovHeaderKind.bot,
          reason: 'before anyone writes, the bot answers');

      expect(settle(async, rig.controller.send('  Hi there  ')), isTrue);
      rig.pump();
      expect(rig.phase, GiovChatPhase.connecting);
      expect(rig.controller.messages.single.delivery, GiovDelivery.sending,
          reason: 'shown at once');
      expect(rig.controller.messages.single.content, 'Hi there');
      rig.socket.accept();
      expect(rig.socket.messageFrames(), isEmpty,
          reason: 'the outbox waits for the history catch-up');
      rig.pump();
      expect(rig.phase, GiovChatPhase.active);
      expect(rig.server.count('history'), 1);
      expect(rig.socket.messageFrames().single['content'], 'Hi there');
      expect(rig.store.log, ['write']);
      expect(rig.started, ['conv-1']);
      expect(rig.controller.conversationId, 'conv-1');
      expect(rig.controller.hasConversation, isTrue);
      rig.dispose();
    });
  });

  test(
      'a dropped socket catches up on history; text typed meanwhile goes out on the next one under the same key',
      () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.start();
      rig.begin();
      rig.socket.receive({
        'id': 'a1',
        'role': 'agent',
        'content': 'Hello, how can I help?',
        'createdAt': 10,
        'senderName': 'Ada',
        'senderAvatar': 'https://cdn.test/ada.png'
      });
      expect(rig.controller.messages.any((m) => m.id == 'a1'), isTrue);
      expect(
          rig.controller.header,
          const GiovHeaderIdentity(
              kind: GiovHeaderKind.person,
              title: 'Ada',
              avatar: 'https://cdn.test/ada.png'),
          reason: 'a person replying takes over the header');

      final first = rig.socket;
      first.drop();
      rig.pump();
      expect(rig.phase, GiovChatPhase.connecting);
      expect(
          rig.controller.connectionStatus, GiovConnectionStatus.disconnected);
      expect(settle(async, rig.controller.send('typed while offline')), isTrue);
      final pending = rig.controller.messages
          .firstWhere((m) => m.content == 'typed while offline');
      expect(pending.delivery, GiovDelivery.sending);

      async.elapse(const Duration(milliseconds: 1500));
      rig.pump();
      expect(rig.sockets.all, hasLength(2));
      final historyBefore = rig.server.count('history');
      rig.open();
      expect(rig.phase, GiovChatPhase.active);
      expect(rig.server.count('history'), historyBefore + 1,
          reason: 'history is reloaded after every reconnect');
      final frame = rig.socket
          .messageFrames()
          .firstWhere((f) => f['content'] == 'typed while offline');
      expect(frame['clientMessageId'], pending.clientMessageId);

      rig.socket.receive({
        'type': 'message_ack',
        'clientMessageId': frame['clientMessageId'],
        'message': {
          'id': 'srv-7',
          'role': 'visitor',
          'content': frame['content'],
          'createdAt': 99999
        },
      });
      final saved = rig.controller.messages
          .firstWhere((m) => m.content == 'typed while offline');
      expect(saved.id, 'srv-7');
      expect(saved.clientMessageId, pending.clientMessageId,
          reason: 'the bubble keeps its key, so it is not redrawn');
      expect(saved.key, pending.key);
      expect(saved.delivery, GiovDelivery.sent);
      expect(
          rig.controller.messages
              .where((m) => m.content == 'typed while offline'),
          hasLength(1));
      rig.dispose();
    });
  });

  test(
      'history merges by id with frames received meanwhile, then the outbox is resent',
      () {
    fakeAsync((async) {
      final rig = CRig(async, stored: testSession);
      rig.server.history = [
        {'id': 'h1', 'role': 'user', 'content': 'Hi', 'createdAt': 1},
        {
          'id': 'h2',
          'role': 'agent',
          'content': 'Hello',
          'createdAt': 2,
          'isBot': true,
          'isAutomated': true
        },
      ];
      rig.start();
      expect(rig.server.count('created'), 0,
          reason: 'a stored conversation is resumed at once');
      expect(rig.server.count('resumed'), 1);
      expect(rig.phase, GiovChatPhase.connecting);
      rig.open();
      expect(rig.phase, GiovChatPhase.active);
      expect(rig.controller.messages.map((m) => m.id), ['h1', 'h2']);
      rig.socket.receive({
        'id': 'h2',
        'role': 'agent',
        'content': 'Hello',
        'createdAt': 2,
        'isBot': true,
        'isAutomated': true
      });
      expect(rig.controller.messages, hasLength(2),
          reason: 'deduplicated by id');
      rig.dispose();
    });
  });

  test(
      'a conversation_state frame closes the chat at once and a reopen brings the composer back',
      () {
    fakeAsync((async) {
      final rig = CRig(async, stored: testSession);
      rig.start();
      rig.open();
      expect(rig.phase, GiovChatPhase.active);
      expect(rig.controller.closed, isFalse);
      // No status (an older server): nothing changes.
      rig.socket.receive({'type': 'conversation_state', 'handedOff': true});
      expect(rig.controller.closed, isFalse);
      rig.socket.receive({
        'type': 'conversation_state',
        'handedOff': true,
        'assignedAgentName': 'Ada',
        'status': 'closed'
      });
      expect(rig.controller.closed, isTrue);
      expect(rig.phase, GiovChatPhase.active);
      expect(settle(async, rig.controller.send('too late')), isFalse);
      rig.socket.receive({'type': 'conversation_state', 'status': 'open'});
      expect(rig.controller.closed, isFalse);
      rig.dispose();
    });
  });

  test(
      'a closed conversation stays read-only until a new one is started; a deleted one, or one the server will not let us read, is forgotten',
      () {
    fakeAsync((async) {
      // Resume answers 409 and the history cannot be read: forgotten.
      var rig = CRig(async, stored: testSession);
      rig.server
        ..resumeStatus = 409
        ..historyStatuses.addAll([401, 401]);
      rig.start();
      rig.open();
      expect(rig.phase, GiovChatPhase.ready);
      expect(rig.store.log, ['delete']);
      rig.dispose();

      // Resume answers 409 and the history is readable: shown read-only.
      rig = CRig(async, stored: testSession);
      rig.server
        ..resumeStatus = 409
        ..status = 'closed';
      rig.start();
      rig.open();
      expect(rig.controller.closed, isTrue);
      expect(rig.phase, GiovChatPhase.active);
      expect(rig.store.log, isEmpty);
      rig.dispose();

      // History says closed.
      rig = CRig(async, stored: testSession)..server.status = 'closed';
      rig.start();
      rig.open();
      expect(rig.phase, GiovChatPhase.active);
      expect(rig.controller.closed, isTrue);
      expect(rig.store.log, isEmpty, reason: 'kept while it is shown');
      expect(rig.controller.hasConversation, isTrue);
      expect(settle(async, rig.controller.send('too late')), isFalse);
      settle(async, rig.controller.startNewConversation());
      rig.pump();
      expect(rig.phase, GiovChatPhase.ready);
      expect(rig.controller.closed, isFalse);
      expect(rig.store.log, ['delete']);
      expect(rig.controller.hasConversation, isFalse);
      expect(rig.socket.closedByClient, isTrue);
      expect(settle(async, rig.controller.send('again')), isTrue,
          reason: 'the next message starts a new conversation');
      rig.server.status = 'open';
      rig.pump();
      expect(rig.server.count('created'), 1);
      rig.dispose();

      // History answers 404.
      rig = CRig(async, stored: testSession)
        ..server.historyStatuses.addAll([404]);
      rig.start();
      rig.open();
      expect(rig.phase, GiovChatPhase.ready);
      expect(rig.store.log, ['delete']);
      rig.dispose();

      // Close code 1000 "Conversation deleted".
      rig = CRig(async, stored: testSession);
      rig.start();
      rig.open();
      rig.socket.drop(1000, 'Conversation deleted');
      rig.pump();
      expect(rig.phase, GiovChatPhase.ready);
      expect(rig.store.log, ['delete']);
      async.elapse(const Duration(minutes: 1));
      expect(rig.sockets.all, hasLength(1),
          reason: 'no reconnect for a deleted conversation');
      rig.dispose();
    });
  });

  test(
      'an expired session ends in the error phase, forgets the stored pair and a retry starts clean',
      () {
    fakeAsync((async) {
      final rig = CRig(async, stored: testSession);
      rig.server.tokenStatuses.add(401);
      rig.start();
      expect(rig.phase, GiovChatPhase.error);
      expect(rig.controller.error, isA<GiovSessionExpiredException>());
      expect(rig.store.log, ['delete']);
      expect(rig.errors.single, isA<GiovSessionExpiredException>());
      unawaited(rig.controller.retry());
      rig.pump();
      expect(rig.phase, GiovChatPhase.ready);
      rig.dispose();
    });
  });

  test('history names the teammate who has the conversation', () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.server
        ..assignedAgentName = 'Ada'
        ..assignedAgentAvatar = 'https://cdn.test/ada.png'
        ..history = [
          {'id': 'h1', 'role': 'user', 'content': 'Hi', 'created_at': 1},
          {
            'id': 'h2',
            'role': 'agent',
            'content': 'Hello!',
            'created_at': 2,
            'is_bot': 0,
            'is_automated': 0
          },
        ];
      rig.start();
      rig.begin();
      expect(rig.controller.currentAgentName, 'Ada');
      expect(rig.controller.currentAgentAvatar, 'https://cdn.test/ada.png');
      expect(rig.controller.header!.kind, GiovHeaderKind.person);
      expect(rig.controller.messages.firstWhere((m) => m.id == 'h2').senderName,
          'Ada');
      rig.dispose();
    });
  });

  test(
      'streamed replies show as they are written and become one saved message in the same place',
      () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.start();
      rig.begin();
      final socket = rig.socket;
      socket.receive({'type': 'typing', 'role': 'agent', 'isBot': true});
      expect(rig.controller.agentTyping, isTrue);
      expect(rig.controller.agentTypingIsBot, isTrue);
      socket.receive(
          {'type': 'stream', 'streamId': 'r1', 'content': 'Our **hours**'});
      final draft = rig.controller.messages.firstWhere((m) => m.isStreaming);
      expect(draft.content, 'Our **hours**');
      expect(draft.clientMessageId, 'stream:r1');
      expect(rig.controller.agentTyping, isFalse,
          reason: 'the draft replaces the typing indicator');
      socket.receive({
        'type': 'stream',
        'streamId': 'r1',
        'content': 'Our **hours** are 9–5.'
      });
      socket.receive({
        'id': 'm9',
        'role': 'agent',
        'content': 'Our **hours** are 9–5.',
        'createdAt': 2000000000000,
        'isBot': true,
        'isAutomated': true,
        'streamId': 'r1'
      });
      final replies = rig.controller.messages
          .where((m) => m.role == GiovRole.agent)
          .toList();
      expect(replies, hasLength(1));
      expect([
        replies.single.id,
        replies.single.clientMessageId,
        replies.single.isStreaming
      ], [
        'm9',
        'stream:r1',
        false
      ]);
      socket.receive({'type': 'typing_end', 'role': 'agent', 'isBot': true});
      expect(rig.controller.agentTyping, isFalse);

      // A cancelled reply sends only stream_end.
      socket
          .receive({'type': 'stream', 'streamId': 'r2', 'content': 'Thinking'});
      expect(rig.controller.messages.where((m) => m.isStreaming), hasLength(1));
      socket.receive({'type': 'stream_end', 'streamId': 'r2'});
      expect(rig.controller.messages.where((m) => m.isStreaming), isEmpty);
      // A draft is lost with the socket.
      socket.receive({'type': 'stream', 'streamId': 'r3', 'content': 'Half'});
      socket.drop();
      expect(rig.controller.messages.where((m) => m.isStreaming), isEmpty);
      rig.dispose();
    });
  });

  test(
      'a typing_end for the other kind keeps the indicator; one for the same kind or without a kind hides it',
      () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.start();
      rig.begin();
      final socket = rig.socket;
      socket.receive({'type': 'typing', 'role': 'agent', 'isBot': false});
      socket.receive({'type': 'typing_end', 'role': 'agent', 'isBot': true});
      expect([
        rig.controller.agentTyping,
        rig.controller.agentTypingIsBot
      ], [
        true,
        false
      ], reason: "the bot's stop is not the person's");
      socket.receive({'type': 'typing_end', 'role': 'agent', 'isBot': false});
      expect(rig.controller.agentTyping, isFalse);
      socket.receive({'type': 'typing', 'role': 'agent', 'isBot': true});
      socket.receive({'type': 'typing_end', 'role': 'agent', 'isBot': false});
      expect([rig.controller.agentTyping, rig.controller.agentTypingIsBot],
          [true, true]);
      socket.receive({'type': 'typing_end', 'role': 'agent'});
      expect(rig.controller.agentTyping, isFalse);
      rig.dispose();
    });
  });

  test(
      'a failed catch-up after a reconnect still resends the outbox; a dead session ends the chat',
      () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.start();
      rig.begin();
      rig.socket.drop();
      rig.pump();
      expect(settle(async, rig.controller.send('typed while offline')), isTrue);
      async.elapse(const Duration(milliseconds: 1500));
      rig.server.historyStatuses.add(500);
      rig.open();
      expect(rig.phase, GiovChatPhase.active);
      expect(rig.controller.error, isA<GiovServerException>());
      expect(rig.socket.messageFrames().map((f) => f['content']),
          contains('typed while offline'),
          reason:
              'the message does not wait for a catch-up that may never come');

      // Resume reloads the history; two 401s mean the session is gone.
      rig.server.historyStatuses.addAll([401, 401]);
      rig.controller.resume();
      rig.pump();
      expect(rig.phase, GiovChatPhase.error);
      expect(rig.controller.error, isA<GiovSessionExpiredException>());
      expect(rig.socket.closedByClient, isTrue);
      expect(rig.store.log, contains('delete'));
      rig.dispose();
    });
  });

  test(
      'kept connected while hidden: replies count as unread until the chat opens; the same connection stays',
      () {
    fakeAsync((async) {
      final rig =
          CRig(async, visible: false, keepConnected: true, stored: testSession);
      rig.start();
      rig.open();
      expect(rig.phase, GiovChatPhase.active);
      expect(rig.server.count('created'), 0);
      rig.socket.receive({
        'id': 'a1',
        'role': 'agent',
        'content': 'Your order shipped',
        'createdAt': 100,
        'senderName': 'Ada'
      });
      rig.socket.receive({
        'id': 'a2',
        'role': 'agent',
        'content': 'Anything else?',
        'createdAt': 101,
        'senderName': 'Ada'
      });
      expect(rig.controller.unreadCount, 2);
      expect(GiovUnread.read('t'), 2);
      final sockets = rig.sockets.all.length;
      rig.controller.setVisible(true);
      expect(rig.controller.unreadCount, 0);
      expect(rig.sockets.all.length, sockets,
          reason: 'opening the chat keeps the same connection');
      expect(rig.unread.sublist(rig.unread.length - 3), [1, 2, 0]);
      expect(GiovUnread.read('t'), 0);
      rig.socket.receive({
        'id': 'a3',
        'role': 'agent',
        'content': 'Hello again',
        'createdAt': 102
      });
      expect(rig.controller.unreadCount, 0,
          reason: 'visible: nothing is unread');
      rig.dispose();
    });
  });

  test(
      'a hidden chat never starts a conversation; without keepConnected it disconnects',
      () {
    fakeAsync((async) {
      final rig = CRig(async, visible: false, keepConnected: true);
      rig.start();
      expect(rig.phase, GiovChatPhase.idle);
      expect(rig.server.count('created'), 0);
      expect(rig.sockets.all, isEmpty);
      rig.controller.setVisible(true);
      rig.pump();
      expect(rig.phase, GiovChatPhase.ready);
      rig.begin();
      rig.dispose();

      final plain = CRig(async, stored: testSession);
      plain.start();
      plain.open();
      expect(plain.phase, GiovChatPhase.active);
      plain.controller.setVisible(false);
      plain.pump();
      expect(
          plain.controller.connectionStatus, GiovConnectionStatus.disconnected);
      expect(plain.socket.closedByClient, isTrue);
      plain.controller.setVisible(true);
      plain.pump();
      expect(plain.sockets.all, hasLength(2));
      plain.dispose();
    });
  });

  test(
      "the visitor's typing is sent once per burst and ends after 2.5 s of quiet or on send",
      () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.start();
      rig.begin();
      final socket = rig.socket;
      socket.sent.clear();
      rig.controller
        ..notifyTyping()
        ..notifyTyping()
        ..notifyTyping();
      expect(socket.frames().map((f) => f['type']), ['typing']);
      async.elapse(const Duration(milliseconds: 2400));
      expect(socket.frames().map((f) => f['type']), ['typing']);
      async.elapse(const Duration(milliseconds: 200));
      expect(socket.frames().map((f) => f['type']), ['typing', 'typing_end']);
      // A new burst, ended by sending.
      socket.sent.clear();
      rig.controller.notifyTyping();
      expect(settle(async, rig.controller.send('done')), isTrue);
      expect(
          socket
              .frames()
              .where((f) => f['type'] != 'ping')
              .map((f) => f['type']),
          ['typing', 'typing_end', 'message']);
      rig.dispose();
    });
  });

  test(
      'the pre-chat form is asked before any conversation exists, and its fields go to the start request',
      () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.server.config = {
        ...rig.server.config,
        'requestUserInfo': {'email': true, 'firstName': true}
      };
      rig.start();
      expect(rig.phase, GiovChatPhase.preChat);
      expect(rig.controller.requiredFields.email, isTrue);
      expect(rig.controller.requiredFields.firstName, isTrue);
      expect(rig.controller.requiredFields.phone, isFalse);
      expect(rig.server.count('created'), 0);
      expect(settle(async, rig.controller.send('hi')), isFalse,
          reason: 'the form comes first');
      unawaited(rig.controller.submitContact(
          const GiovContact(email: 'not-an-email', firstName: 'Ada')));
      rig.pump();
      expect(rig.phase, GiovChatPhase.preChat,
          reason: 'a malformed email is still missing');
      expect(rig.controller.requiredFields.email, isTrue);
      expect(rig.controller.requiredFields.firstName, isFalse);
      unawaited(rig.controller
          .submitContact(const GiovContact(email: 'ada@acme.co')));
      rig.pump();
      expect(rig.server.count('created'), 1);
      expect(rig.server.to('/conversations', 'POST').last.json,
          {'tenantId': 't', 'email': 'ada@acme.co', 'firstName': 'Ada'});
      rig.open();
      expect(rig.phase, GiovChatPhase.active);
      rig.dispose();
    });
  });

  test('a known visitor starts with userId and userHash', () {
    fakeAsync((async) {
      final hash = 'c' * 64;
      final rig =
          CRig(async, contact: GiovContact(userId: 'cust_42', userHash: hash));
      rig.start();
      rig.begin();
      expect(rig.server.to('/conversations', 'POST').single.json,
          {'tenantId': 't', 'userId': 'cust_42', 'userHash': hash});
      rig.dispose();
    });
  });

  test(
      'going to the background closes the socket after a short grace; coming back reconnects and catches up',
      () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.start();
      rig.begin();
      final before = rig.server.count('history');

      // A short interruption does not close the socket.
      rig.controller.handleLifecycle(AppLifecycleState.inactive);
      async.elapse(const Duration(seconds: 3));
      expect(rig.socket.closedByClient, isFalse);
      rig.controller.handleLifecycle(AppLifecycleState.resumed);
      rig.pump();
      expect(rig.sockets.all, hasLength(1));
      expect(rig.server.count('history'), before + 1,
          reason:
              'the history is reloaded on resume even when the socket survived');

      // A long one does.
      rig.controller.handleLifecycle(AppLifecycleState.paused);
      async.elapse(const Duration(seconds: 6));
      rig.pump();
      expect(rig.sockets.all.first.closedByClient, isTrue);
      expect(
          rig.controller.connectionStatus, GiovConnectionStatus.disconnected);
      async.elapse(const Duration(minutes: 2));
      expect(rig.sockets.all, hasLength(1),
          reason: 'no reconnect while in the background');
      rig.controller.resume();
      rig.pump();
      expect(rig.sockets.all, hasLength(2));
      final reloaded = rig.server.count('history');
      rig.open();
      expect(rig.phase, GiovChatPhase.active);
      expect(rig.server.count('history'), reloaded + 1);
      rig.dispose();
    });
  });

  test(
      'a push token requested before the conversation connects is registered once it does',
      () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.start();
      final hex = 'ab' * 32;
      GiovPushResult? result;
      unawaited(rig.controller
          .registerPushToken(hex, GiovPushPlatform.ios,
              options: const GiovPushOptions(
                  environment: GiovPushEnvironment.sandbox,
                  appId: 'com.acme.app'))
          .then((r) => result = r));
      rig.pump();
      expect(result, isNull);
      rig.begin();
      expect(result!.registered, isTrue);
      expect(
          rig.server
              .to('/conversations/conv-1/push-token', 'POST')
              .single
              .json['environment'],
          'sandbox');
      expect(
          rig.server
              .to('/conversations/conv-1/push-token', 'POST')
              .single
              .json['locale'],
          'en');
      expect(
          settle(
                  async,
                  rig.controller
                      .registerPushToken('new-token', GiovPushPlatform.android))
              .registered,
          isTrue,
          reason: 'registers at once when connected');
      rig.dispose();
    });
  });

  test(
      'a failed message shows as not sent; retry sends it again in place, discard removes it',
      () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.start();
      rig.begin();
      final id =
          rig.socket.messageFrames().single['clientMessageId']! as String;
      Map<String, Object?> failure() =>
          {'type': 'error', 'error': 'message_failed', 'clientMessageId': id};
      rig.socket.receive(failure());
      async.elapse(const Duration(seconds: 2, milliseconds: 1));
      rig.socket.receive(failure());
      async.elapse(const Duration(seconds: 4, milliseconds: 1));
      rig.socket.receive(failure());
      expect(rig.controller.messages.single.delivery, GiovDelivery.failed);
      expect(rig.errors.last, isA<GiovSendFailedException>());
      expect(rig.controller.messages.single.key, id);
      rig.controller.retryMessage(id);
      expect(rig.controller.messages.single.delivery, GiovDelivery.sending);
      expect(rig.socket.messageFrames().last['clientMessageId'], id);
      rig.socket.receive({'type': 'error', 'error': 'invalid_message'});
      expect(rig.controller.messages.single.delivery, GiovDelivery.failed);
      rig.controller.discardMessage(id);
      expect(rig.controller.messages, isEmpty);
      rig.dispose();
    });
  });

  test('messages over 2000 characters are refused up front', () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.start();
      expect(settle(async, rig.controller.send('x' * 2001)), isFalse);
      expect(rig.controller.error, isA<GiovSendFailedException>());
      expect(rig.server.count('created'), 0);
      expect(settle(async, rig.controller.send('   ')), isFalse);
      rig.dispose();
    });
  });

  test(
      'files upload first, then go out as one message each after the text; names survive from this device',
      () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.start();
      rig.begin('first');
      final a = GiovPickedFile.bytes(
          name: 'a.png',
          mimeType: 'image/png',
          bytes: Uint8List(8),
          width: 40,
          height: 30);
      final b = GiovPickedFile.bytes(
          name: 'b.png', mimeType: 'image/png', bytes: Uint8List(8));
      expect(rig.controller.checkFiles([a, b]).accepted, hasLength(2));
      expect(
          rig.controller
              .checkFiles([
                GiovPickedFile.bytes(
                    name: 'x.exe',
                    mimeType: 'application/x-msdownload',
                    bytes: Uint8List(1))
              ])
              .problems
              .single,
          isA<AttachmentTypeNotAllowed>());
      rig.socket.sent.clear();
      expect(settle(async, rig.controller.send('see these', files: [a, b])),
          isTrue);
      rig.pump();
      expect(rig.server.count('upload'), 2);
      final frames = rig.socket.messageFrames();
      expect(frames, hasLength(3));
      expect(frames[0]['content'], 'see these');
      expect(frames[0].containsKey('attachments'), isFalse);
      expect((frames[1]['attachments']! as List).single,
          endsWith('/attachments/a.png'));
      expect(frames[1]['content'], '');
      final shown = rig.controller.messages
          .firstWhere((m) => m.attachments.any((x) => x.url.endsWith('a.png')));
      expect(shown.attachments.single.filename, 'a.png');
      expect(shown.attachments.single.contentType, 'image/png');
      expect(
          shown.attachments.single.preview!.aspectRatio, closeTo(4 / 3, 0.001));
      expect(rig.controller.attachmentUrl(shown.attachments.single.url),
          endsWith('?at=access-token-abcdefgh'));
      expect(rig.controller.uploads, isEmpty);
      expect(rig.controller.sending, isFalse);

      // A failed upload queues nothing.
      rig.server.uploadStatuses.addAll([400, 400]);
      expect(settle(async, rig.controller.send('', files: [a])), isFalse);
      expect(rig.controller.error, isA<GiovAttachmentRejectedException>());
      rig.dispose();
    });
  });

  test('files cannot be sent before a conversation exists', () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.start();
      final file = GiovPickedFile.bytes(
          name: 'a.png', mimeType: 'image/png', bytes: Uint8List(8));
      expect(settle(async, rig.controller.send('', files: [file])), isFalse);
      expect(rig.server.count('upload'), 0);
      rig.dispose();
    });
  });

  test('a store that fails is reported and never breaks the chat', () {
    fakeAsync((async) {
      final rig = CRig(async, store: _BrokenStore());
      rig.start();
      expect(rig.phase, GiovChatPhase.ready);
      rig.begin();
      expect(rig.errors.whereType<GiovStorageException>(), isNotEmpty);
      rig.dispose();
    });
  });

  test('reset forgets the conversation, the stored session and the outbox', () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.start();
      rig.begin();
      unawaited(rig.controller.reset());
      rig.pump();
      expect(rig.phase, GiovChatPhase.ready);
      expect(rig.controller.messages, isEmpty);
      expect(rig.controller.hasConversation, isFalse);
      expect(rig.store.log, contains('delete'));
      expect(rig.controller.outbox.size, 0);
      rig.dispose();
    });
  });

  test(
      'a network failure on the first load ends in the error phase with a typed failure',
      () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.server.config = {'oops': true};
      rig.start();
      expect(rig.phase, GiovChatPhase.error);
      expect(rig.controller.error, isA<GiovInvalidResponseException>());
      rig.dispose();
    });
  });

  test(
      'a busy workspace is reported on start, the message stays queued and the start is tried again after Retry-After',
      () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.server.startStatus = 503;
      rig.start();
      expect(settle(async, rig.controller.send('hello')), isTrue);
      rig.pump();
      expect(rig.phase, GiovChatPhase.connecting,
          reason: 'the conversation stays on screen while it is retried');
      expect(rig.controller.reconnecting, isTrue);
      expect(rig.controller.error, isA<GiovWorkspaceBusyException>());
      expect(rig.controller.messages.single.delivery, GiovDelivery.sending);
      rig.server.startStatus = null;
      async.elapse(const Duration(seconds: 29));
      expect(rig.server.count('created'), 1,
          reason: 'Retry-After (30 s) is longer than the first backoff step');
      async.elapse(const Duration(seconds: 1));
      rig.pump();
      expect(rig.server.count('created'), 2);
      rig.open();
      expect(rig.phase, GiovChatPhase.active);
      expect(rig.socket.messageFrames().single['content'], 'hello');
      rig.dispose();
    });
  });

  test(
      'a first connection that fails is retried with the protocol backoff; Try again restarts at once',
      () {
    fakeAsync((async) {
      final rig = CRig(async, stored: testSession);
      rig.start();
      // The socket never opens: the 10 s open timeout fails the attempt.
      async.elapse(const Duration(seconds: 10));
      rig.pump();
      expect(rig.phase, GiovChatPhase.connecting);
      expect(rig.controller.reconnecting, isTrue);
      expect(rig.controller.error, isA<GiovNetworkException>());
      expect(rig.sockets.all, hasLength(1));
      async.elapse(const Duration(milliseconds: 1499));
      expect(rig.sockets.all, hasLength(1));
      async.elapse(const Duration(milliseconds: 1));
      rig.pump();
      expect(rig.sockets.all, hasLength(2), reason: 'first retry after 1.5 s');
      async.elapse(const Duration(seconds: 10));
      rig.pump();
      async.elapse(const Duration(milliseconds: 2999));
      expect(rig.sockets.all, hasLength(2));
      async.elapse(const Duration(milliseconds: 1));
      rig.pump();
      expect(rig.sockets.all, hasLength(3), reason: 'then 3 s');
      rig.open();
      expect(rig.phase, GiovChatPhase.active);
      expect(rig.controller.reconnecting, isFalse);
      rig.dispose();
    });
  });

  test('a refusal only the visitor can fix is not retried by itself', () {
    fakeAsync((async) {
      final rig = CRig(async,
          contact: const GiovContact(userId: 'u1', userHash: 'bad'));
      rig.server.startStatus = 401;
      rig.server.startError = 'invalid_user_hash';
      rig.start();
      expect(settle(async, rig.controller.send('hello')), isTrue);
      rig.pump();
      expect(rig.phase, GiovChatPhase.error);
      expect(rig.controller.error, isA<GiovIdentityRejectedException>());
      async.elapse(const Duration(minutes: 5));
      expect(rig.server.count('created'), 1);
      rig.dispose();
    });
  });

  test(
      'start() on a started controller does nothing: no second resume, the socket stays',
      () {
    fakeAsync((async) {
      final rig = CRig(async, stored: testSession);
      rig.start();
      rig.open();
      final socket = rig.socket;
      unawaited(rig.controller.start());
      rig.pump();
      expect(rig.sockets.all, hasLength(1));
      expect(socket.closedByClient, isFalse);
      expect(rig.server.count('resumed'), 1);
      expect(rig.phase, GiovChatPhase.active);
      unawaited(rig.controller.retry());
      rig.pump();
      expect(rig.sockets.all, hasLength(2),
          reason: 'retry() is the explicit restart');
      rig.dispose();
    });
  });

  test(
      'upload failures: 404 forgets the conversation, 401/403 end the session, 429 keeps Retry-After, 5xx is the server, 4xx refuses the file',
      () {
    fakeAsync((async) {
      final file = GiovPickedFile.bytes(
          name: 'a.png', mimeType: 'image/png', bytes: Uint8List(8));

      var rig = CRig(async);
      rig.start();
      rig.begin();
      rig.server.uploadStatuses.add(429);
      expect(settle(async, rig.controller.send('', files: [file])), isFalse);
      expect(
          rig.controller.error,
          isA<GiovRateLimitedException>().having(
              (e) => e.retryAfter, 'retryAfter', const Duration(seconds: 30)));
      rig.server.uploadStatuses.add(503);
      expect(settle(async, rig.controller.send('', files: [file])), isFalse);
      expect(rig.controller.error,
          isA<GiovServerException>().having((e) => e.status, 'status', 503));
      rig.server.uploadStatuses.add(413);
      expect(settle(async, rig.controller.send('', files: [file])), isFalse);
      expect(rig.controller.error, isA<GiovAttachmentRejectedException>());
      expect(rig.phase, GiovChatPhase.active);

      rig.server.uploadStatuses.add(404);
      expect(settle(async, rig.controller.send('', files: [file])), isFalse);
      rig.pump();
      expect(rig.phase, GiovChatPhase.ready,
          reason: 'the conversation is gone, like a closed one');
      expect(rig.controller.error, isA<GiovConversationClosedException>());
      expect(rig.controller.hasConversation, isFalse);
      expect(rig.store.log, contains('delete'));
      rig.dispose();

      rig = CRig(async);
      rig.start();
      rig.begin();
      rig.server.uploadStatuses.addAll([403]);
      expect(settle(async, rig.controller.send('', files: [file])), isFalse);
      rig.pump();
      expect(rig.phase, GiovChatPhase.error);
      expect(rig.controller.error, isA<GiovSessionExpiredException>());
      expect(rig.socket.closedByClient, isTrue);
      expect(rig.store.log, contains('delete'));
      rig.dispose();
    });
  });

  test(
      'push: the token is remembered and registered again for a new conversation; reset forgets it',
      () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.start();
      rig.begin();
      final hex = 'ab' * 32;
      expect(
          settle(async,
                  rig.controller.registerPushToken(hex, GiovPushPlatform.apns))
              .registered,
          isTrue);
      final first =
          rig.server.to('/conversations/conv-1/push-token', 'POST').single;
      expect(first.headers['X-Giov-Client'], 'flutter/$giovSdkVersion');
      expect(first.json['locale'], 'en');

      // A reconnect to the same conversation does not register again.
      rig.socket.drop();
      async.elapse(const Duration(milliseconds: 1500));
      rig.open();
      expect(rig.server.count('push-POST'), 1);

      // The team closes it; the next message starts conv-2, which gets the token without the host.
      rig.server.status = 'closed';
      rig.controller.resume();
      rig.pump();
      expect(rig.controller.closed, isTrue);
      settle(async, rig.controller.startNewConversation());
      rig.pump();
      expect(rig.phase, GiovChatPhase.ready);
      rig.server
        ..status = 'open'
        ..nextConversationId = 'conv-2';
      expect(settle(async, rig.controller.send('new question')), isTrue);
      rig.pump();
      rig.open();
      expect(
          rig.server
              .to('/conversations/conv-2/push-token', 'POST')
              .single
              .json['token'],
          hex);

      // After reset the next conversation is not registered.
      settle(async, rig.controller.reset());
      rig.server.nextConversationId = 'conv-3';
      expect(settle(async, rig.controller.send('as someone else')), isTrue);
      rig.pump();
      rig.open();
      expect(
          rig.server.to('/conversations/conv-3/push-token', 'POST'), isEmpty);
      rig.dispose();
    });
  });

  test(
      'push: a request before any conversation waits for the first one and resolves no_conversation on dispose',
      () {
    fakeAsync((async) {
      final rig = CRig(async);
      rig.start();
      GiovPushResult? result;
      unawaited(rig.controller
          .registerPushToken('fcm-token-1', GiovPushPlatform.fcm)
          .then((value) => result = value));
      async.elapse(const Duration(minutes: 10));
      expect(result, isNull, reason: 'kept for the first conversation');
      rig.dispose();
      async.flushMicrotasks();
      expect(result!.failure, GiovPushFailure.noConversation);
    });
  });

  test(
      'push: unregister works while the chat is closed, with the stored session and a fresh visitor token',
      () {
    fakeAsync((async) {
      // Never started: the stored pair is read.
      var rig = CRig(async, stored: testSession, visible: false);
      expect(settle(async, rig.controller.unregisterPushToken('fcm-token-1')),
          isTrue);
      final removal =
          rig.server.to('/conversations/conv-1/push-token', 'DELETE').single;
      expect(removal.headers['Authorization'], 'Bearer visitor-token-1');
      expect(removal.json, {'token': 'fcm-token-1'});
      expect(rig.sockets.all, isEmpty);
      rig.dispose();

      // Started, then hidden (disconnected).
      rig = CRig(async, stored: testSession);
      rig.start();
      rig.open();
      rig.controller.setVisible(false);
      rig.pump();
      expect(rig.controller.isConnected, isFalse);
      expect(settle(async, rig.controller.unregisterPushToken('fcm-token-1')),
          isTrue);
      expect(rig.server.to('/conversations/conv-1/push-token', 'DELETE'),
          hasLength(1));
      rig.dispose();
    });
  });

  test(
      'the session scope is the workspace and the visitor id: a profile edit keeps the conversation',
      () {
    String scope(GiovContact contact, [String? key]) =>
        giovSessionScope('https://api.example.test', 't',
            contact: contact, sessionKey: key);
    expect(
        scope(const GiovContact(
            userId: 'u1', firstName: 'Ada', email: 'a@x.test')),
        scope(const GiovContact(
            userId: 'u1',
            firstName: 'Ada L.',
            email: 'ada@x.test',
            phone: '+1')));
    expect(scope(const GiovContact(userId: 'u1')),
        isNot(scope(const GiovContact(userId: 'u2'))));
    expect(scope(const GiovContact(), 'k1'),
        isNot(scope(const GiovContact(), 'k2')));
  });

  test(
      'attachment links renew the visitor token once the access token runs out, at most once a minute',
      () {
    fakeAsync((async) {
      final rig = CRig(async, stored: testSession);
      rig.start();
      rig.open();
      const file =
          'https://api.example.test/conversations/conv-1/attachments/a.png';
      expect(
          rig.controller.attachmentUrl(file), '$file?at=access-token-abcdefgh');
      final tokens = rig.server.count('token');
      // The access token (1 h) is unusable 5 minutes before it expires; the visitor token (15 min) is long gone.
      async.elapse(const Duration(minutes: 56));
      expect(rig.controller.attachmentUrl(file), file,
          reason: 'no expired credential is put in a link');
      expect(rig.controller.attachmentUrl(file), file);
      rig.pump();
      expect(rig.server.count('token'), tokens + 1,
          reason: 'one renewal for both calls');
      expect(
          rig.controller.attachmentUrl(file), '$file?at=access-token-abcdefgh');
      rig.dispose();
    });
  });
}

class _BrokenStore extends RecordingStore {
  @override
  Future<GiovSession?> read(String scope) =>
      Future.error(StateError('keychain locked'));
  @override
  Future<void> write(String scope, GiovSession session) =>
      Future.error(StateError('keychain locked'));
  @override
  Future<void> delete(String scope) =>
      Future.error(StateError('keychain locked'));
}
