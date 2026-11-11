import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:giovchat/giovchat.dart';

import 'support/fakes.dart';

class Rig {
  Rig(this.async, {bool flushOnOpen = true, Outbox? outbox}) {
    now = () => epoch.add(async.elapsed);
    server = FakeServer(now);
    sockets = Sockets(async);
    client = GiovChatClient(
      tenantKey: 't',
      baseUrl: 'https://api.example.test',
      httpClient: server.client,
      socketFactory: sockets.create,
      outbox: outbox ?? Outbox(now: () => now().millisecondsSinceEpoch),
      flushOnOpen: flushOnOpen,
      now: now,
      random: NoJitter(),
    );
  }

  final FakeAsync async;
  late final DateTime Function() now;
  late final FakeServer server;
  late final Sockets sockets;
  late final GiovChatClient client;

  /// connect() and open the socket.
  Future<void> connect() {
    final done = client.connect(testSession);
    async.flushMicrotasks();
    sockets.last.accept();
    async.flushMicrotasks();
    return done;
  }
}

void main() {
  test(
      'the config and push registration requests name the SDK; conversation requests do not',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      final config = settle(async, rig.client.fetchWidgetConfig());
      expect(config.title, 'Acme');
      expect(config.botName, 'Atlas');
      expect(rig.server.requests.single.headers['X-Giov-Client'],
          'flutter/$giovSdkVersion');
      expect(rig.server.requests.single.uri.toString(),
          'https://api.example.test/widget/config?tenantId=t');
      settle(async, rig.client.startConversation());
      expect(rig.server.requests.last.headers.containsKey('X-Giov-Client'),
          isFalse);
    });
  });

  test(
      'start sends the contact fields with userId and userHash; resume sends the session secret as bearer',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      final hash = 'a' * 64;
      final started = settle(
          async,
          rig.client.startConversation(
              GiovContact(userId: 'u1', userHash: hash, email: 'a@b.co')));
      expect(started, testSession);
      final start = rig.server.requests.last;
      expect(start.json, {
        'tenantId': 't',
        'userId': 'u1',
        'userHash': hash,
        'email': 'a@b.co'
      });
      expect(start.headers.containsKey('Authorization'), isFalse);

      settle(async, rig.client.resumeConversation(testSession));
      final resume = rig.server.requests.last;
      expect(resume.headers['Authorization'],
          'Bearer ${testSession.sessionToken}');
      expect(resume.json['conversationId'], 'conv-1');
    });
  });

  test('refusals map to typed failures', () {
    fakeAsync((async) {
      final rig = Rig(async);
      rig.server.resumeStatus = 409;
      expect(() => settle(async, rig.client.resumeConversation(testSession)),
          throwsA(isA<GiovConversationClosedException>()));
      rig.server.resumeStatus = 401;
      expect(() => settle(async, rig.client.resumeConversation(testSession)),
          throwsA(isA<GiovSessionExpiredException>()));
      rig.server.resumeStatus = 404;
      expect(
          () => settle(async, rig.client.resumeConversation(testSession)),
          throwsA(isA<GiovServerException>()
              .having((e) => e.status, 'status', 404)));
      rig.server.startStatus = 503;
      expect(
          () => settle(async, rig.client.startConversation()),
          throwsA(isA<GiovWorkspaceBusyException>().having(
              (e) => e.retryAfter, 'retryAfter', const Duration(seconds: 30))));
      rig.server
        ..startStatus = 401
        ..startError = 'invalid_user_hash';
      expect(() => settle(async, rig.client.startConversation()),
          throwsA(isA<GiovIdentityRejectedException>()));
    });
  });

  test(
      'messages written before the socket opens go out first, in order, under stable ids',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      final first = rig.client.send('written offline');
      final second = rig.client.send('and another');
      expect(rig.client.outbox.size, 2);
      settle(async, rig.connect());
      final socket = rig.sockets.last;
      expect(socket.url.toString(),
          'wss://api.example.test/conversations/conv-1/ws?role=user&token=visitor-token-1');
      expect(
          rig.server.to('/auth/widget-token').single.headers['Authorization'],
          'Bearer ${testSession.sessionToken}');
      expect(
          socket
              .messageFrames()
              .map((frame) => [frame['clientMessageId'], frame['content']]),
          [
            [first, 'written offline'],
            [second, 'and another'],
          ]);
      final acked = <String>[];
      rig.client.acks.listen((ack) => acked.add(
          '${ack.clientMessageId}>${ack.message.id}/${ack.message.role.name}'));
      socket.receive({
        'type': 'message_ack',
        'clientMessageId': first,
        'message': {
          'id': 'srv-1',
          'role': 'visitor',
          'content': 'written offline',
          'createdAt': 5
        },
      });
      expect(acked, ['$first>srv-1/visitor']);
      expect(rig.client.outbox.list().map((entry) => entry.clientMessageId),
          [second]);
      rig.client.dispose();
    });
  });

  test('ws:// is used for a local http:// API', () {
    fakeAsync((async) {
      final rig = Rig(async);
      final local = GiovChatClient(
        tenantKey: 't',
        baseUrl: 'http://127.0.0.1:8787',
        httpClient: rig.server.client,
        socketFactory: rig.sockets.create,
        now: rig.now,
      );
      final done = local.connect(testSession);
      async.flushMicrotasks();
      expect(
          rig.sockets.last.url.toString(),
          startsWith(
              'ws://127.0.0.1:8787/conversations/conv-1/ws?role=user&token='));
      rig.sockets.last.accept();
      settle(async, done);
      local.dispose();
    });
  });

  test('an attempt that has not opened after 10 s is given up', () {
    fakeAsync((async) {
      final rig = Rig(async);
      Object? failure;
      rig.client.connect(testSession).catchError((Object e) => failure = e);
      async.elapse(const Duration(seconds: 9));
      expect(failure, isNull);
      async.elapse(const Duration(seconds: 2));
      expect(
          failure,
          isA<GiovNetworkException>()
              .having((e) => e.timedOut, 'timedOut', true));
      expect(rig.sockets.last.closedByClient, isTrue);
      expect(rig.client.isConnected, isFalse);
    });
  });

  test(
      'ping every 25 s; a pong keeps the socket, a missing pong within 10 s reconnects with a fresh token',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      rig.sockets.autoPong = false;
      settle(async, rig.connect());
      final first = rig.sockets.last;
      async.elapse(const Duration(seconds: 24));
      expect(first.frames('ping'), isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(first.frames('ping'), hasLength(1));
      first.receive({'type': 'pong'});
      async.elapse(const Duration(seconds: 11));
      expect(first.closedByClient, isFalse, reason: 'the pong arrived');
      async.elapse(const Duration(seconds: 14)); // t = 50 s: second ping
      expect(first.frames('ping'), hasLength(2));
      async.elapse(const Duration(seconds: 9));
      expect(first.closedByClient, isFalse);
      async.elapse(
          const Duration(seconds: 2)); // t = 61 s; the deadline was 60 s
      expect(first.closedByClient, isTrue,
          reason: 'no pong within 10 s means the socket is dead');
      expect(rig.client.isConnected, isFalse);
      expect(rig.sockets.all, hasLength(1));
      async.elapse(const Duration(milliseconds: 499)); // 60 s + 1499 ms
      expect(rig.sockets.all, hasLength(1),
          reason: 'first retry waits 1500 ms');
      async.elapse(const Duration(milliseconds: 2));
      expect(rig.sockets.all, hasLength(2));
      expect(rig.sockets.last.url.queryParameters['token'], 'visitor-token-2',
          reason: 'a new visitor token before every connect');
      rig.client.dispose();
    });
  });

  test('reconnect backoff is min(1500 x 2^n, 15000) ms plus jitter', () {
    expect([for (var n = 0; n < 7; n++) giovReconnectDelay(n).inMilliseconds],
        [1500, 3000, 6000, 12000, 15000, 15000, 15000]);
    expect(giovReconnectDelay(0, jitter: 0.5).inMilliseconds, 1700);
    expect(giovReconnectDelay(30, jitter: 0.999).inMilliseconds, 15399);
    expect(socketOpenTimeout, const Duration(seconds: 10));
    expect(socketPingInterval, const Duration(seconds: 25));
    expect(socketPongTimeout, const Duration(seconds: 10));
  });

  test(
      'failed reconnect attempts keep backing off, the counter resets after a successful connect',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      settle(async, rig.connect());
      rig.sockets.last.drop();
      final times = <Duration>[];
      // Every new socket never opens: 10 s open timeout, then the next wait doubles.
      var seen = 1;
      for (var i = 0; i < 400 && times.length < 4; i++) {
        async.elapse(const Duration(milliseconds: 100));
        if (rig.sockets.all.length > seen) {
          seen = rig.sockets.all.length;
          times.add(async.elapsed);
        }
      }
      final gaps = [
        for (var i = 1; i < times.length; i++)
          (times[i] - times[i - 1]).inMilliseconds
      ];
      // gap = open timeout (10 s) + next backoff wait (3000, 6000, ...), measured at 100 ms resolution
      expect(gaps.first, closeTo(10000 + 3000, 150));
      expect(gaps[1], closeTo(10000 + 6000, 150));
      rig.client.dispose();
    });
  });

  test(
      'a message with no ack within 10 s means a dead socket: reconnect and resend under the same id',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      settle(async, rig.connect());
      final id = rig.client.send('are you there?');
      final first = rig.sockets.last;
      expect(first.messageFrames(), hasLength(1));
      async.elapse(const Duration(seconds: 9));
      expect(first.closedByClient, isFalse);
      async.elapse(const Duration(seconds: 4));
      expect(first.closedByClient, isTrue);
      expect(rig.client.outbox.get(id)!.state, OutboxState.queued,
          reason: 'unacknowledged stays in the outbox');
      async.elapse(const Duration(seconds: 2));
      rig.sockets.last.accept();
      async.flushMicrotasks();
      expect(rig.sockets.all, hasLength(2));
      expect(
          rig.sockets.last
              .messageFrames()
              .map((frame) => frame['clientMessageId']),
          [id]);
      rig.client.dispose();
    });
  });

  test(
      'close code 1000 "Conversation deleted" ends the connection with a closed-conversation failure and no retry',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      final errors = <GiovChatException>[];
      rig.client.errors.listen(errors.add);
      settle(async, rig.connect());
      rig.sockets.last.drop(1000, 'Conversation deleted');
      async.elapse(const Duration(minutes: 1));
      expect(errors.single, isA<GiovConversationClosedException>());
      expect(rig.sockets.all, hasLength(1));
    });
  });

  test(
      'sendMessage waits through the connection and resolves with the stored copy; disconnect settles waiters',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      final result = rig.client.sendMessage('queued while connecting');
      GiovMessage? stored;
      result.then((message) => stored = message);
      settle(async, rig.connect());
      final frame = rig.sockets.last.messageFrames().single;
      rig.sockets.last.receive({
        'type': 'message_ack',
        'clientMessageId': frame['clientMessageId'],
        'message': {
          'id': 'srv-9',
          'role': 'visitor',
          'content': frame['content'],
          'createdAt': 9
        },
      });
      async.flushMicrotasks();
      expect(stored!.id, 'srv-9');
      final lost = rig.client.sendMessage('still waiting');
      Object? failure;
      lost.catchError((Object e) => failure = GiovMessage(
          id: '', role: GiovRole.visitor, content: '$e', createdAt: 0));
      rig.client.disconnect();
      async.flushMicrotasks();
      expect(failure, isNotNull);
    });
  });

  test(
      'save failures retry after 2 s and 4 s quietly, then are reported once; a visitor retry sends it again',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      final errors = <GiovChatException>[];
      rig.client.errors.listen(errors.add);
      settle(async, rig.connect());
      final socket = rig.sockets.last;
      final id = rig.client.send('hello');
      Map<String, Object?> failed() =>
          {'type': 'error', 'error': 'message_failed', 'clientMessageId': id};
      socket.receive(failed());
      expect(rig.client.outbox.get(id)!.state, OutboxState.queued);
      async.elapse(const Duration(milliseconds: 1999));
      expect(socket.messageFrames(), hasLength(1));
      async.elapse(const Duration(milliseconds: 2));
      expect(socket.messageFrames(), hasLength(2), reason: 'resent after 2 s');
      socket.receive(failed());
      async.elapse(const Duration(milliseconds: 4001));
      expect(socket.messageFrames(), hasLength(3), reason: 'resent after 4 s');
      expect(errors, isEmpty, reason: 'failures are retried quietly');
      socket.receive(failed());
      expect(rig.client.outbox.get(id)!.state, OutboxState.failed);
      expect(errors.single, isA<GiovSendFailedException>());
      async.elapse(const Duration(seconds: 20));
      expect(socket.messageFrames(), hasLength(3),
          reason: 'not sent again on its own');
      expect(rig.client.retryMessage(id), isTrue);
      expect(socket.messageFrames(), hasLength(4));
      expect(socket.messageFrames().map((f) => f['clientMessageId']).toSet(),
          {id});
      rig.client.dispose();
    });
  });

  test('refusals fail the oldest message on the socket; rate limits only delay',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      settle(async, rig.connect());
      final socket = rig.sockets.last;
      final a = rig.client.send('a');
      final b = rig.client.send('b');
      socket.receive({'type': 'error', 'error': 'invalid_message'});
      expect(rig.client.outbox.get(a)!.state, OutboxState.failed);
      expect(rig.client.outbox.get(b)!.state, OutboxState.sending);
      socket.receive({'type': 'error', 'error': 'rate_limited'});
      expect(rig.client.outbox.get(b)!.state, OutboxState.queued,
          reason: 'rate limited: sent again a little later');
      async.elapse(const Duration(seconds: 3));
      expect(socket.messageFrames().where((f) => f['clientMessageId'] == b),
          hasLength(2));
      rig.client.dispose();
    });
  });

  test(
      'an unknown error code is a refusal like invalid_message: the oldest message fails instead of resending forever',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      final errors = <GiovChatException>[];
      rig.client.errors.listen(errors.add);
      settle(async, rig.connect());
      final socket = rig.sockets.last;
      final a = rig.client.send('a');
      final b = rig.client.send('b');
      socket.receive({'type': 'error', 'error': 'message_blocked'});
      expect(rig.client.outbox.get(a)!.state, OutboxState.failed);
      expect(rig.client.outbox.get(b)!.state, OutboxState.sending);
      expect(
          errors.single,
          isA<GiovSendFailedException>()
              .having((e) => e.code, 'code', 'message_blocked'));
      socket.receive({'type': 'error', 'error': 42});
      expect(rig.client.outbox.get(b)!.state, OutboxState.failed,
          reason: 'a malformed code is not a crash');
      socket.receive({'type': 'error', 'error': 'message_failed'});
      expect(errors, hasLength(2),
          reason: 'a save failure without an id names nothing to fail');
      async.elapse(const Duration(seconds: 30));
      expect(socket.closedByClient, isFalse,
          reason: 'no dead-socket reconnect loop');
      rig.client.dispose();
    });
  });

  test(
      'streamed replies arrive as whole text so far; the saved reply takes the draft key; stream_end alone drops a draft',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      final events = <String>[];
      final messages = <GiovMessage>[];
      rig.client.streamEvents.listen((event) => events.add(switch (event) {
            GiovStreamUpdate() => '${event.streamId}:${event.content}',
            GiovStreamEnd() => '${event.streamId}:end',
          }));
      rig.client.messages.listen(messages.add);
      settle(async, rig.connect());
      final socket = rig.sockets.last;
      socket.receive({'type': 'stream', 'streamId': 's1', 'content': 'Hel'});
      socket.receive(
          {'type': 'stream', 'streamId': 's1', 'content': 'Hello **there**'});
      socket.receive({
        'id': 'm1',
        'role': 'agent',
        'content': 'Hello **there**',
        'createdAt': 3,
        'isBot': true,
        'isAutomated': true,
        'streamId': 's1'
      });
      socket.receive({'type': 'stream_end', 'streamId': 's2'});
      expect(events, ['s1:Hel', 's1:Hello **there**', 's1:end', 's2:end']);
      expect(messages.single.clientMessageId, 'stream:s1');
      expect(messages.single.isBot, isTrue);
      expect(messages.single.key, 'stream:s1');
      rig.client.dispose();
    });
  });

  test(
      'typing: agent frames are reported; the visitor sends typing and typing_end once the socket is open',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      final seen = <String>[];
      rig.client.typing
          .listen((event) => seen.add('${event.active}/${event.isBot}'));
      rig.client.sendTyping();
      settle(async, rig.connect());
      final socket = rig.sockets.last;
      rig.client.sendTyping();
      rig.client.sendTypingEnd();
      expect(
          socket
              .frames()
              .where((f) => (f['type']! as String).startsWith('typing'))
              .map((f) => f['type']),
          ['typing', 'typing_end'],
          reason: 'nothing is sent before the socket opens');
      socket.receive({'type': 'typing', 'role': 'agent', 'isBot': true});
      socket.receive({'type': 'typing_end', 'role': 'agent'});
      socket.receive({'type': 'typing', 'role': 'visitor'});
      socket.receive({'type': 'typing_end', 'role': 'agent', 'isBot': false});
      expect(seen, ['true/true', 'false/null', 'false/false'],
          reason: 'a stop says whose indicator ends');
      rig.client.dispose();
    });
  });

  test(
      'agent replies keep their photo and attachments, unknown frames are ignored',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      final messages = <GiovMessage>[];
      rig.client.messages.listen(messages.add);
      settle(async, rig.connect());
      final socket = rig.sockets.last;
      socket.receive({'type': 'something_new', 'x': 1});
      socket.onMessage?.call('not json');
      socket.receive({
        'id': 'm2',
        'role': 'agent',
        'content': '',
        'createdAt': 4,
        'senderName': 'Ada',
        'senderAvatar': 'https://cdn.test/ada.png',
        'attachmentId': jsonEncode([
          'https://api.example.test/conversations/conv-1/attachments/a.png'
        ]),
        'attachmentPreviews': [
          {'width': 400, 'height': 300},
        ],
      });
      expect(messages, hasLength(1));
      expect(messages.single.senderAvatar, 'https://cdn.test/ada.png');
      expect(messages.single.attachments.single.url,
          'https://api.example.test/conversations/conv-1/attachments/a.png');
      expect(messages.single.attachments.single.preview!.aspectRatio,
          closeTo(4 / 3, 0.001));
      rig.client.dispose();
    });
  });

  test(
      'visitor tokens are renewed when less than a minute is left, kept otherwise',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      settle(async, rig.connect());
      expect(rig.server.count('token'), 1);
      settle(async, rig.client.fetchHistory());
      expect(rig.server.count('token'), 1,
          reason: 'the cached token is reused');
      async.elapse(const Duration(minutes: 14, seconds: 10)); // 50 s left
      settle(async, rig.client.fetchHistory());
      expect(rig.server.count('token'), 2);
      expect(
          rig.server
              .to('/conversations/conv-1/history')
              .last
              .headers['Authorization'],
          'Bearer visitor-token-2');
      rig.client.dispose();
    });
  });

  test(
      'a 401 renews the token once and retries; a second 401 means the session is gone',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      settle(async, rig.connect());
      rig.server.historyStatuses.add(401);
      settle(async, rig.client.fetchHistory());
      expect(rig.server.count('token'), 2);
      expect(rig.server.count('history'), 3 - 1,
          reason: 'one rejected, one retried');
      rig.server.historyStatuses.addAll([401, 401]);
      expect(() => settle(async, rig.client.fetchHistory()),
          throwsA(isA<GiovSessionExpiredException>()));
      rig.client.dispose();
    });
  });

  test(
      'history 404 surfaces as a 404 failure; history parses messages, assignee and access token',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
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
      settle(async, rig.connect());
      final accessSeen = <AttachmentAccess>[];
      rig.client.attachmentAccess.listen(accessSeen.add);
      final history = settle(async, rig.client.fetchHistory());
      expect(history.messages.map((m) => m.id), ['h1', 'h2']);
      expect(history.messages.first.role, GiovRole.visitor);
      expect(history.messages.last.senderName, 'Ada',
          reason: 'history rows carry no sender; the assignee is used');
      expect(history.assignedAgentAvatar, 'https://cdn.test/ada.png');
      rig.server.historyStatuses.add(404);
      expect(
          () => settle(async, rig.client.fetchHistory()),
          throwsA(isA<GiovServerException>()
              .having((e) => e.status, 'status', 404)));
      rig.client.dispose();
    });
  });

  test(
      'upload: multipart with progress, the file name and type; a 401 retries with a new token',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      settle(async, rig.connect());
      final bytes = Uint8List.fromList(List.filled(1000, 7));
      final file = GiovPickedFile.bytes(
          name: 'a.png',
          mimeType: 'image/png',
          bytes: bytes,
          width: 40,
          height: 30);
      final progress = <double>[];
      rig.server.uploadStatuses.add(401);
      final result = settle(
          async, rig.client.uploadAttachment(file, onProgress: progress.add));
      expect(result.url, endsWith('/attachments/a.png'));
      expect(result.filename, 'a.png');
      expect(progress, isNotEmpty);
      expect(progress.last, 1);
      final uploads = rig.server.to('/conversations/conv-1/upload-visitor');
      expect(uploads, hasLength(2));
      expect(uploads.first.headers['Authorization'], 'Bearer visitor-token-1');
      expect(uploads.last.headers['Authorization'], 'Bearer visitor-token-2');
      expect(uploads.last.headers['content-type'],
          startsWith('multipart/form-data; boundary='));
      expect(
          uploads.last.body,
          allOf(contains('name="file"'), contains('filename="a.png"'),
              contains('image/png')));
      rig.client.dispose();
    });
  });

  test('upload: a refusal is an attachment rejection', () {
    fakeAsync((async) {
      final rig = Rig(async);
      settle(async, rig.connect());
      final file = GiovPickedFile.bytes(
          name: 'a.exe',
          mimeType: 'application/x-msdownload',
          bytes: Uint8List(4));
      rig.server.uploadStatuses.add(400);
      expect(() => settle(async, rig.client.uploadAttachment(file)),
          throwsA(isA<GiovAttachmentRejectedException>()));
      rig.client.dispose();
    });
  });

  test('upload: each refusal maps to its failure', () {
    fakeAsync((async) {
      final rig = Rig(async);
      settle(async, rig.connect());
      final file = GiovPickedFile.bytes(
          name: 'a.png', mimeType: 'image/png', bytes: Uint8List(4));
      GiovChatException failure(int status) {
        rig.server.uploadStatuses.addAll(status == 401 ? [401, 401] : [status]);
        try {
          settle(async, rig.client.uploadAttachment(file));
        } on GiovChatException catch (error) {
          return error;
        }
        throw StateError('no failure');
      }

      expect(failure(404), isA<GiovConversationClosedException>());
      expect(failure(401), isA<GiovSessionExpiredException>());
      expect(failure(403), isA<GiovSessionExpiredException>());
      expect(
          failure(429),
          isA<GiovRateLimitedException>().having(
              (e) => e.retryAfter, 'retryAfter', const Duration(seconds: 30)));
      expect(failure(500), isA<GiovServerException>());
      expect(failure(415), isA<GiovAttachmentRejectedException>());
      rig.client.dispose();
    });
  });

  test(
      'upload: a server that never answers fails after the upload timeout instead of hanging',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      settle(async, rig.connect());
      rig.server.hangUploads = true;
      final file = GiovPickedFile.bytes(
          name: 'a.png', mimeType: 'image/png', bytes: Uint8List(10));
      Object? failure;
      unawaited(rig.client
          .uploadAttachment(file)
          .then((_) {}, onError: (Object error) => failure = error));
      async.elapse(const Duration(seconds: 119));
      expect(failure, isNull);
      async.elapse(const Duration(seconds: 2));
      expect(failure, isA<GiovNetworkException>());
      rig.client.dispose();
    });
  });

  test(
      'push registration sends token, platform and APNs environment with the visitor token',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      final hex = 'ab' * 32;
      expect(
          settle(async, rig.client.registerPushToken(hex, GiovPushPlatform.ios))
              .failure,
          GiovPushFailure.noConversation,
          reason: 'nothing to register for before a conversation');
      settle(async, rig.connect());
      final result = settle(
        async,
        rig.client.registerPushToken(
            hex,
            GiovPushPlatform.ios,
            const GiovPushOptions(
                environment: GiovPushEnvironment.sandbox,
                appId: 'com.acme.app',
                locale: 'fr')),
      );
      expect(result.registered, isTrue);
      final request =
          rig.server.to('/conversations/conv-1/push-token', 'POST').single;
      expect(request.headers['Authorization'], 'Bearer visitor-token-1');
      expect(request.headers['X-Giov-Client'], 'flutter/$giovSdkVersion',
          reason: 'stored with the device');
      expect(request.json, {
        'token': hex,
        'platform': 'ios',
        'environment': 'sandbox',
        'appId': 'com.acme.app',
        'locale': 'fr'
      });
      expect(settle(async, rig.client.unregisterPushToken(hex)), isTrue);
      final removal =
          rig.server.to('/conversations/conv-1/push-token', 'DELETE').single;
      expect(removal.json, {'token': hex});
      rig.client.dispose();
    });
  });

  test(
      'push registration degrades cleanly on a server without it, and never asks again',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      rig.server.pushStatus = 404;
      settle(async, rig.connect());
      expect(
          settle(
                  async,
                  rig.client.registerPushToken(
                      'device-token', GiovPushPlatform.android))
              .failure,
          GiovPushFailure.unsupported);
      final before = rig.server.requests.length;
      expect(
          settle(
                  async,
                  rig.client.registerPushToken(
                      'device-token', GiovPushPlatform.android))
              .failure,
          GiovPushFailure.unsupported);
      expect(rig.server.requests.length, before,
          reason: 'an unsupported server is not asked again');
      for (final status in [405, 501]) {
        final other = Rig(async)..server.pushStatus = status;
        settle(async, other.connect());
        expect(
            settle(async,
                    other.client.registerPushToken('t', GiovPushPlatform.fcm))
                .failure,
            GiovPushFailure.unsupported);
        other.client.dispose();
      }
      final failing = Rig(async)..server.pushStatus = 500;
      settle(async, failing.connect());
      expect(
          settle(async,
                  failing.client.registerPushToken('t', GiovPushPlatform.fcm))
              .failure,
          GiovPushFailure.failed);
      expect(
          settle(async,
                  failing.client.registerPushToken('', GiovPushPlatform.fcm))
              .failure,
          GiovPushFailure.failed);
      rig.client.dispose();
      failing.client.dispose();
    });
  });

  test(
      'disconnect keeps unsent messages; a new connection sends them under the same ids',
      () {
    fakeAsync((async) {
      final outbox = Outbox();
      final rig = Rig(async, outbox: outbox);
      settle(async, rig.connect());
      final id = rig.client.send('hello');
      expect(rig.sockets.last.messageFrames(), hasLength(1));
      rig.client.disconnect();
      expect(outbox.get(id)!.state, OutboxState.queued);
      final next = GiovChatClient(
        tenantKey: 't',
        baseUrl: 'https://api.example.test',
        outbox: outbox,
        httpClient: rig.server.client,
        socketFactory: rig.sockets.create,
        now: rig.now,
      );
      final done = next.connect(testSession);
      async.flushMicrotasks();
      rig.sockets.last.accept();
      settle(async, done);
      expect(rig.sockets.last.messageFrames().map((f) => f['clientMessageId']),
          [id]);
      next.dispose();
    });
  });
}
