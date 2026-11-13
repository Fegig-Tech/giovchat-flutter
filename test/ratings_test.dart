// Flutter 3.47 deprecates package:flutter/material.dart, and SemanticsData.hasFlag since 3.32;
// the replacements don't exist on Flutter 3.22, which the SDK still supports.
// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show SemanticsFlag;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:giovchat/giovchat.dart';
import 'package:giovchat/src/core/models.dart' show asMap;
import 'package:http/http.dart' as http;

import 'support/fakes.dart';

/// Far in the future, whatever the clock.
const future = 4102444800000;

Map<String, Object?> card([Map<String, Object?> extra = const {}]) =>
    {'type': 'rating', 'requestId': 'r1', 'closesAt': future, ...extra};

Map<String, Object?> cardMessage(String id,
        {List<Object?>? blocks, int createdAt = 10, bool isBot = false}) =>
    {
      'id': id,
      'role': 'agent',
      'content': 'How did we do? Please rate this conversation.',
      'createdAt': createdAt,
      'isBot': isBot,
      'blocks': blocks ?? [card()],
    };

GiovMessage message(Map<String, Object?> json) => GiovMessage.fromJson(json)!;

http.Response jsonResponse(Object? body,
        [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json', ...headers});

class Rig {
  Rig(this.async) {
    now = () => epoch.add(async.elapsed);
    server = FakeServer(now);
    sockets = Sockets(async);
    client = GiovChatClient(
      tenantKey: 't',
      baseUrl: 'https://api.example.test',
      httpClient: server.client,
      socketFactory: sockets.create,
      now: now,
      random: NoJitter(),
    );
  }

  final FakeAsync async;
  late final DateTime Function() now;
  late final FakeServer server;
  late final Sockets sockets;
  late final GiovChatClient client;

  void connect([GiovSession? session]) {
    final done = client.connect(session ?? testSession);
    async.flushMicrotasks();
    sockets.last.accept();
    settle(async, done);
  }
}

void main() {
  // ─── Parsing, patching, state ──────────────────────────────────────────────────────────────────

  test(
      'a rating block is read from a message; other and malformed blocks are ignored',
      () {
    final parsed = message(cardMessage('m1', blocks: [
      {'type': 'buttons', 'buttons': []},
      card({
        'score': 4,
        'comment': 'Fast',
        'url': 'https://x.test/rate/r1#k=abc'
      }),
    ]));
    expect(parsed.rating!.requestId, 'r1');
    expect(parsed.rating!.closesAt, future);
    expect(parsed.rating!.score, 4);
    expect(parsed.rating!.comment, 'Fast');
    expect(parsed.rating!.url, 'https://x.test/rate/r1#k=abc');
    expect(
        message(cardMessage('m2', blocks: [
          {'type': 'rating', 'requestId': 'r1'},
          {'type': 'mystery'}
        ])).rating,
        isNull,
        reason: 'closesAt is required');
    final odd = message(cardMessage('m3', blocks: [
      card({'score': 9, 'comment': 'x', 'url': 'javascript:alert(1)'})
    ]));
    expect(odd.rating!.score, isNull,
        reason: 'an out-of-range score is no answer');
    expect(odd.rating!.url, isNull, reason: 'only https links are kept');
    expect(
        message(cardMessage('m4', blocks: [
          card({'state': 'replaced'})
        ])).rating!.replaced,
        isTrue);
    expect(message({...cardMessage('m5'), 'blocks': 'nope'}).rating, isNull);
  });

  test("history rows carry the visitor's thumb on GiovBot answers only", () {
    final row = {
      'id': 'a1',
      'role': 'agent',
      'content': 'Hi',
      'created_at': 5,
      'is_bot': 1,
      'feedback': 'down'
    };
    expect(message(row).feedback, GiovFeedbackValue.down);
    expect(message({...row, 'feedback': 'sideways'}).feedback, isNull);
    expect(message({...row, 'is_bot': 0}).feedback, isNull,
        reason: "a person's message takes no thumb");
  });

  test('the rating frame patches the card of its message, and only that one',
      () {
    final frame = GiovRatingFrame.tryParse({
      'type': 'rating',
      'conversationId': 'c',
      'requestId': 'r1',
      'messageId': 'm1',
      'closesAt': future + 5,
      'score': 5,
      'comment': 'Great'
    })!;
    final messages = [
      message(cardMessage('m1')),
      message(cardMessage('m2', blocks: [
        card({'requestId': 'r2'})
      ])),
    ];
    final next = patchRating(messages, frame);
    expect(next[0].rating!.score, 5);
    expect(next[0].rating!.comment, 'Great');
    expect(next[0].rating!.closesAt, future + 5);
    expect(identical(next[1], messages[1]), isTrue);
    // A frame without a score means no answer yet.
    final cleared = patchRating(
        next,
        GiovRatingFrame.tryParse(
            {'type': 'rating', 'requestId': 'r1', 'closesAt': future})!);
    expect(cleared[0].rating!.score, isNull);
    expect(cleared[0].rating!.comment, isNull);
    // A frame with a score and no comment means the comment was removed.
    final kept = patchRating(
        next,
        GiovRatingFrame.tryParse({
          'type': 'rating',
          'requestId': 'r1',
          'messageId': 'm1',
          'closesAt': future + 5,
          'score': 5
        })!);
    expect(kept[0].rating!.score, 5);
    expect(kept[0].rating!.comment, isNull);
    expect(
        identical(
            patchRating(
                messages,
                const GiovRatingFrame(
                    requestId: 'r1', messageId: 'zzz', closesAt: 1)),
            messages),
        isTrue);
    expect(GiovRatingFrame.tryParse({'type': 'rating', 'requestId': 'r1'}),
        isNull);
    expect(
        GiovRatingFrame.tryParse(
            {'type': 'message', 'requestId': 'r1', 'closesAt': 1}),
        isNull);
  });

  test(
      'a frame can announce a replacement; a newer card hides an older unanswered one at once',
      () {
    final messages = [
      message(cardMessage('m1')),
      message(cardMessage('m2', createdAt: 20, blocks: [
        card({'requestId': 'r2'})
      ])),
    ];
    final replaced = patchRating(
        messages,
        GiovRatingFrame.tryParse({
          'type': 'rating',
          'requestId': 'r2',
          'messageId': 'm2',
          'closesAt': future,
          'state': 'replaced'
        })!);
    expect(replaced[1].rating!.replaced, isTrue);
    expect(ratingPhase(replaced[1].rating!, 0), GiovRatingPhase.hidden);
    final superseded = supersedeRatings(messages);
    expect(superseded[0].rating!.replaced, isTrue,
        reason: 'the old unanswered card is hidden');
    expect(superseded[1].rating!.replaced, isFalse);
    final answered = [
      message(cardMessage('m1', blocks: [
        card({'score': 3})
      ])),
      messages[1]
    ];
    expect(supersedeRatings(answered)[0].rating!.replaced, isFalse,
        reason: 'an answered card keeps its answer');
    expect(identical(supersedeRatings([messages[1]])[0], messages[1]), isTrue);
  });

  test(
      'the open card: hidden, open, closed by the clock; the pending request is the newest open card',
      () {
    const now = 1000000;
    GiovRatingBlock block(int closesAt, {bool replaced = false}) =>
        GiovRatingBlock(requestId: 'r', closesAt: closesAt, replaced: replaced);
    expect(ratingPhase(block(now + 1), now), GiovRatingPhase.open);
    expect(ratingPhase(block(now), now), GiovRatingPhase.closed,
        reason: 'read-only from closesAt on');
    expect(ratingPhase(block(now + 1, replaced: true), now),
        GiovRatingPhase.hidden);
    final messages = [
      message(cardMessage('m1', blocks: [
        card({'closesAt': now - 1})
      ])),
      message(cardMessage('m2', createdAt: 20, blocks: [
        card({
          'requestId': 'r2',
          'closesAt': now + 5,
          'score': 2,
          'comment': 'Meh'
        })
      ])),
    ];
    final request = pendingRatingRequest(messages, now)!;
    expect(request.requestId, 'r2');
    expect(request.messageId, 'm2');
    expect(request.answered, isTrue);
    expect(request.score, 2);
    expect(request.comment, 'Meh');
    expect(pendingRatingRequest(messages, now + 10), isNull,
        reason: 'closed by the clock');
    expect(pendingRatingRequest(const [], now), isNull);
  });

  test(
      'refusals map to typed errors; a 404 with no code is a server without the routes',
      () {
    GiovRatingProblem? problem(int status, Map<String, Object?> body) {
      final failure = ratingFailure(status, body, const Duration(seconds: 30));
      return failure is GiovRatingException ? failure.problem : null;
    }

    expect(problem(400, {'error': 'invalid_rating'}),
        GiovRatingProblem.invalidRating);
    expect(problem(400, {'error': 'invalid_feedback'}),
        GiovRatingProblem.invalidFeedback);
    expect(problem(404, {'error': 'request_not_found'}),
        GiovRatingProblem.requestNotFound);
    expect(problem(404, {'error': 'message_not_found'}),
        GiovRatingProblem.messageNotFound);
    expect(problem(409, {'error': 'request_replaced'}),
        GiovRatingProblem.requestReplaced);
    expect(problem(409, {'error': 'rating_closed'}),
        GiovRatingProblem.ratingClosed);
    expect(problem(429, {'error': 'too_many_changes'}),
        GiovRatingProblem.tooManyChanges);
    expect(problem(404, {}), GiovRatingProblem.unsupported);
    expect(problem(404, {'error': 'not_found'}), GiovRatingProblem.unsupported);
    expect(ratingFailure(401, {'error': 'unauthorized'}, Duration.zero),
        isA<GiovSessionExpiredException>());
    expect(ratingFailure(403, {'error': 'suspended'}, Duration.zero),
        isA<GiovSessionExpiredException>());
    expect(ratingFailure(500, {}, Duration.zero), isA<GiovServerException>());
    final limited = ratingFailure(
        429, {'error': 'rate_limited'}, const Duration(seconds: 17));
    expect(limited, isA<GiovRateLimitedException>());
    expect((limited as GiovRateLimitedException).retryAfter,
        const Duration(seconds: 17));
  });

  test(
      'thumbs: the same thumb again takes the vote back; never under streaming drafts or the rating request',
      () {
    expect(nextFeedback(null, GiovFeedbackValue.up), GiovFeedbackValue.up);
    expect(nextFeedback(GiovFeedbackValue.up, GiovFeedbackValue.up),
        GiovFeedbackValue.none);
    expect(nextFeedback(GiovFeedbackValue.up, GiovFeedbackValue.down),
        GiovFeedbackValue.down);
    final answer = message({
      'id': 'a1',
      'role': 'agent',
      'content': 'Hi',
      'createdAt': 1,
      'isBot': true
    });
    expect(canVoteOn(answer), isTrue);
    expect(canVoteOn(answer.copyWith(isStreaming: true)), isFalse);
    expect(canVoteOn(answer.copyWith(id: 'stream:s1')), isFalse);
    expect(canVoteOn(message(cardMessage('m1', isBot: true))), isFalse,
        reason: 'a GiovBot rating request gets no thumbs');
    expect(
        canVoteOn(message(
            {'id': 'p1', 'role': 'agent', 'content': 'Hi', 'createdAt': 1})),
        isFalse);
    final voted = applyFeedback([answer], 'a1', GiovFeedbackValue.down);
    expect(voted[0].feedback, GiovFeedbackValue.down);
    expect(
        applyFeedback(voted, 'a1', GiovFeedbackValue.none)[0].feedback, isNull);
  });

  test('every language ships the rating strings', () {
    for (final entry in giovStrings.entries) {
      final strings = entry.value;
      for (var score = 1; score <= 5; score++) {
        expect(strings.ratingFace(score).trim(), isNotEmpty,
            reason: '${entry.key} face $score');
      }
      expect(strings.ratingFace(1), isNot(strings.ratingFace(5)));
      expect(strings.ratingWait(7), contains('7'));
      for (final text in [
        strings.rateTitle,
        strings.ratingSend,
        strings.ratingThanks,
        strings.answerGood,
        strings.answerBad,
        strings.answerReason,
        strings.closeRating
      ]) {
        expect(text.trim(), isNotEmpty, reason: entry.key);
      }
    }
    expect(giovStrings['fr']!.ratingThanks,
        isNot(giovStrings['en']!.ratingThanks));
    expect(giovStrings['en']!.copyWith(ratingSend: 'Go').ratingSend, 'Go');
  });

  // ─── The client ─────────────────────────────────────────────────────────────────────────────────

  test(
      'submitRating sends the documented body, checks input first and renews the token once on 401',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      var calls = 0;
      rig.server.ratingHandler = (request) {
        calls++;
        return calls == 1
            ? jsonResponse({'error': 'unauthorized'}, 401)
            : jsonResponse({
                'requestId': 'r1',
                'score': 4,
                'comment': 'Quick',
                'closesAt': future,
                'ratedAt': 5
              });
      };
      rig.connect();
      final result = settle(async,
          rig.client.submitRating(4, comment: '  Quick  ', requestId: 'r1'));
      expect(result.score, 4);
      expect(result.comment, 'Quick');
      expect(result.closesAt, future);
      final posts =
          rig.server.to('/conversations/conv-1/rating', 'POST').toList();
      expect(posts, hasLength(2));
      expect(posts[0].headers['Authorization'], 'Bearer visitor-token-1');
      expect(posts[1].headers['Authorization'], 'Bearer visitor-token-2');
      expect(
          posts[1].json, {'score': 4, 'requestId': 'r1', 'comment': 'Quick'});
      for (final bad in [
        () => rig.client.submitRating(0),
        () => rig.client.submitRating(6),
        () => rig.client.submitRating(3, comment: 'x' * 1001),
      ]) {
        expect(
            () => settle(async, bad()),
            throwsA(isA<GiovRatingException>().having(
                (e) => e.problem, 'problem', GiovRatingProblem.invalidRating)));
      }
      expect(rig.server.count('rating'), 2,
          reason: 'nothing invalid reaches the server');
      rig.client.dispose();
    });
  });

  test('answer feedback: body, reason only with down, and refusals', () {
    fakeAsync((async) {
      final rig = Rig(async);
      rig.server.ratingHandler = (request) {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        return body['value'] == 'down'
            ? jsonResponse({'error': 'message_not_found'}, 404)
            : jsonResponse({
                'messageId': 'a1',
                'value': body['value'] == 'none' ? null : body['value'],
                'reason': null
              });
      };
      rig.connect();
      settle(
          async,
          rig.client.submitAnswerFeedback('a1', GiovFeedbackValue.up,
              reason: 'ignored'));
      expect(rig.server.requests.last.json, {'value': 'up'},
          reason: 'a reason is kept only with down');
      expect(
          () => settle(
              async,
              rig.client.submitAnswerFeedback('a1', GiovFeedbackValue.down,
                  reason: 'wrong')),
          throwsA(isA<GiovRatingException>().having(
              (e) => e.problem, 'problem', GiovRatingProblem.messageNotFound)));
      expect(
          rig.server.requests.last.json, {'value': 'down', 'reason': 'wrong'});
      settle(async,
          rig.client.submitAnswerFeedback('a/1', GiovFeedbackValue.none));
      expect(rig.server.requests.last.path,
          '/conversations/conv-1/messages/a%2F1/feedback');
      expect(
          () => settle(
              async,
              rig.client.submitAnswerFeedback('a1', GiovFeedbackValue.down,
                  reason: 'x' * 301)),
          throwsA(isA<GiovRatingException>().having(
              (e) => e.problem, 'problem', GiovRatingProblem.invalidFeedback)));
      rig.client.dispose();
    });
  });

  test(
      'an old server (404 with no code) marks ratings unsupported; a rate limit carries its pause',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      rig.server.ratingHandler = (request) {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        return body['score'] == 5
            ? jsonResponse({'error': 'rate_limited'}, 429, {'retry-after': '9'})
            : jsonResponse({}, 404);
      };
      rig.connect();
      expect(
          () => settle(async, rig.client.submitRating(5)),
          throwsA(isA<GiovRateLimitedException>().having(
              (e) => e.retryAfter, 'retryAfter', const Duration(seconds: 9))));
      expect(rig.client.ratingsUnsupported, isFalse);
      expect(
          () => settle(async, rig.client.submitRating(3)),
          throwsA(isA<GiovRatingException>().having(
              (e) => e.problem, 'problem', GiovRatingProblem.unsupported)));
      expect(rig.client.ratingsUnsupported, isTrue);
      rig.client.dispose();
    });
  });

  test(
      'rating frames reach the stream; unknown frames and blocks do not disturb the client',
      () {
    fakeAsync((async) {
      final rig = Rig(async);
      rig.connect();
      final seen = <Object>[];
      rig.client.ratingFrames.listen(seen.add);
      rig.client.messages.listen(seen.add);
      final socket = rig.sockets.last;
      socket.receive({'type': 'rating', 'requestId': 'r1'});
      socket.receive({'type': 'future_frame', 'x': 1});
      socket.receive({
        'id': 'm1',
        'role': 'agent',
        'content': 'Hi',
        'createdAt': 1,
        'blocks': [
          {'type': 'from_the_future'}
        ]
      });
      socket.receive({
        'type': 'rating',
        'requestId': 'r1',
        'messageId': 'm1',
        'closesAt': 5,
        'score': 3
      });
      async.flushMicrotasks();
      expect(seen, hasLength(2));
      expect((seen[0] as GiovMessage).rating, isNull);
      expect((seen[1] as GiovRatingFrame).score, 3);
      rig.client.dispose();
    });
  });

  // ─── Fixture 05-ratings.json through the client ──────────────────────────────────────────────────

  test('conformance: fixture 05-ratings.json through the SDK client', () {
    final fixture =
        jsonDecode(File('test/fixtures/05-ratings.json').readAsStringSync())
            as Map<String, Object?>;
    fakeAsync((async) {
      final rig = Rig(async);
      final vars = <String, String>{'tenantId': 't'};
      Object? sub(Object? value) =>
          jsonDecode(jsonEncode(value).replaceAllMapped(
              RegExp(r'\{\{(\w+)\}\}'), (match) => vars[match.group(1)]!));
      Object? concrete(Object? value) => switch (value) {
            '<number>' => future,
            '<nonempty>' => 'x',
            List() => [for (final item in value) concrete(item)],
            Map() => {
                for (final entry in value.entries)
                  entry.key: concrete(entry.value)
              },
            _ => value,
          };
      late Map<String, Object?> step;
      Map<String, Object?>? lastAnswer;
      Map<String, Object?>? cardJson;
      rig.server.ratingHandler = (request) {
        final expected = asMap(step['expect']);
        var body =
            asMap(concrete(sub(expected['body'] ?? <String, Object?>{})));
        final status = expected['status']! as int;
        if (status == 200 && request.url.path.endsWith('/rating')) {
          body = {
            'requestId': vars['requestId'],
            'closesAt': future,
            'ratedAt': 1,
            ...body
          };
          lastAnswer = body;
        }
        return jsonResponse(body, status);
      };
      final received = <GiovMessage>[];
      final frames = <GiovRatingFrame>[];
      GiovSession? session;
      for (final raw in fixture['steps']! as List) {
        step = raw as Map<String, Object?>;
        final httpStep = step['http'] == null ? null : asMap(step['http']);
        if (httpStep != null && httpStep['auth'] == 'agent') {
          // The team's request (outside the visitor spec): the server pushes a card.
          vars['requestId'] = 'req-1';
          vars['ratingMessageId'] = 'msg-rating-1';
          cardJson = cardMessage('msg-rating-1', createdAt: 20, blocks: [
            card({'requestId': 'req-1'})
          ]);
          rig.sockets.last.receive(cardJson);
          continue;
        }
        if (httpStep != null) {
          final method = httpStep['method']! as String;
          final path = sub(httpStep['path']) as String;
          final auth = httpStep['auth'];
          final json = httpStep['json'] == null
              ? <String, Object?>{}
              : asMap(sub(httpStep['json']));
          if (path == '/conversations' && method == 'POST') {
            final started = settle(async, rig.client.startConversation());
            session = started;
            vars['conversationId'] = started.conversationId;
            continue;
          }
          // The client fetches its visitor token itself.
          if (path == '/auth/widget-token') continue;
          if (path.endsWith('/history')) {
            rig.server.history = [
              {
                ...cardJson!,
                'blocks': [
                  card({'requestId': 'req-1', 'score': lastAnswer!['score']})
                ]
              }
            ];
            final history = settle(async, rig.client.fetchHistory());
            final patched = history.messages
                .firstWhere((m) => m.id == vars['ratingMessageId']);
            expect(patched.rating!.score, lastAnswer!['score'],
                reason: 'history returns the card with the answer applied');
            continue;
          }
          if (auth == null) continue; // the SDK always sends the visitor token
          // A vote that is not up, down or none cannot be written with the SDK's enum: the type refuses it.
          if (json['value'] != null &&
              !GiovFeedbackValue.values.any((v) => v.name == json['value'])) {
            continue;
          }
          final before = rig.server.requests.length;
          final expected = asMap(step['expect']);
          final status = expected['status']! as int;
          Object? error;
          Object? value;
          try {
            value = path.endsWith('/rating')
                ? settle(
                    async,
                    rig.client.submitRating(json['score']! as int,
                        comment: json['comment'] as String?,
                        requestId: json['requestId'] as String?))
                : settle(
                    async,
                    rig.client.submitAnswerFeedback(
                        Uri.decodeComponent(path.split('/')[4]),
                        GiovFeedbackValue.values
                            .firstWhere((v) => v.name == json['value']),
                        reason: json['reason'] as String?));
          } on Object catch (caught) {
            error = caught;
          }
          // Input the server would refuse (400) never leaves the device; the code is the server's.
          if (status == 400) {
            expect(error, isA<GiovRatingException>(),
                reason: '${step['note']}');
            expect((error! as GiovRatingException).code,
                asMap(expected['body'])['error']);
            expect(rig.server.requests.length, before,
                reason: 'nothing invalid is sent');
            continue;
          }
          final sent = rig.server.requests.skip(before).firstWhere(
              (r) => r.path == path,
              orElse: () =>
                  throw StateError('${step['note']}: the SDK called $path'));
          expect(sent.method, method);
          expect(sent.headers['Authorization'], 'Bearer visitor-token-1',
              reason: '${step['note']}: visitor token');
          for (final entry in json.entries) {
            expect(sent.json[entry.key], entry.value,
                reason: '${step['note']}: body.${entry.key}');
          }
          if (status == 200) {
            expect(error, isNull, reason: '${step['note']}: $error');
            if (value is GiovRatingResult) {
              final wanted = asMap(concrete(sub(expected['body'])));
              expect(value.score, wanted['score']);
              if (wanted['comment'] == null && wanted.containsKey('comment')) {
                expect(value.comment, isNull);
              } else if (wanted['comment'] != null) {
                expect(value.comment, wanted['comment']);
              }
            }
          } else {
            expect(error, isA<GiovRatingException>(),
                reason: '${step['note']}');
            expect((error! as GiovRatingException).code,
                asMap(expected['body'])['error']);
          }
          continue;
        }
        if (step['connect'] != null) {
          rig.client.messages.listen(received.add);
          rig.client.ratingFrames.listen(frames.add);
          rig.connect(session);
          continue;
        }
        if (step['send'] != null) {
          final content =
              asMap(asMap(step['send'])['frame'])['content']! as String;
          rig.client.send(content);
          async.flushMicrotasks();
          final sent = rig.sockets.last.messageFrames().last;
          expect(sent['content'], content);
          rig.sockets.last.receive({
            'type': 'message_ack',
            'clientMessageId': sent['clientMessageId'],
            'message': {
              'id': 'v1',
              'role': 'visitor',
              'content': content,
              'createdAt': 15
            }
          });
          continue;
        }
        if (step['receive'] != null) {
          final match = asMap(asMap(step['receive'])['match']);
          if (match['type'] == 'message_ack') continue;
          if (match['type'] == 'rating') {
            // The server echoes the changed answer on the socket.
            rig.sockets.last.receive({
              'type': 'rating',
              'conversationId': vars['conversationId'],
              'requestId': vars['requestId'],
              'messageId': vars['ratingMessageId'],
              'closesAt': future,
              'score': lastAnswer!['score']
            });
            async.flushMicrotasks();
            expect(frames.last.requestId, vars['requestId']);
            expect(frames.last.messageId, vars['ratingMessageId']);
            expect(frames.last.score, match['score']);
            continue;
          }
          final got = received.firstWhere((m) => m.id == sub(match['id']),
              orElse: () =>
                  throw StateError('the card arrived as a chat message'));
          expect(got.rating!.requestId, vars['requestId']);
          expect(got.content, isNotEmpty);
        }
      }
      rig.client.dispose();
    });
  });

  // ─── The controller ─────────────────────────────────────────────────────────────────────────────

  test(
      'the controller keeps the open card, announces each unanswered one once, patches from frames and closes by the clock',
      () {
    fakeAsync((async) {
      DateTime now() => epoch.add(async.elapsed);
      final server = FakeServer(now);
      final sockets = Sockets(async);
      final events = <GiovRatingEvent>[];
      final callbacks = <String>[];
      final controller = GiovChatController(
        tenantKey: 't',
        baseUrl: 'https://api.example.test',
        locale: 'en',
        httpClient: server.client,
        socketFactory: sockets.create,
        now: now,
        random: NoJitter(),
        onRatingRequested: (request) =>
            callbacks.add('requested ${request.requestId}'),
        onRatingSubmitted: (result) =>
            callbacks.add('submitted ${result.score}'),
        onAnswerFeedback: (feedback) => callbacks
            .add('feedback ${feedback.messageId} ${feedback.value.name}'),
      );
      controller.ratingEvents.listen(events.add);
      void pump() {
        for (var i = 0; i < 12; i++) {
          async.flushMicrotasks();
          async.elapse(Duration.zero);
        }
      }

      unawaited(controller.start());
      pump();
      expect(settle(async, controller.send('Hi')), isTrue);
      pump();
      server.ratingHandler = (request) {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        return request.url.path.endsWith('/rating')
            ? jsonResponse({
                'requestId': body['requestId'],
                'score': body['score'],
                'closesAt': epoch.millisecondsSinceEpoch + 120000,
                'ratedAt': 1
              })
            : jsonResponse(
                {'messageId': 'x', 'value': body['value'], 'reason': null});
      };
      sockets.last.accept();
      pump();
      final hello = sockets.last.messageFrames().last;
      sockets.last.receive({
        'type': 'message_ack',
        'clientMessageId': hello['clientMessageId'],
        'message': {
          'id': 'v1',
          'role': 'visitor',
          'content': 'Hi',
          'createdAt': 5
        }
      });
      pump();
      expect(controller.ratingRequest, isNull);

      final closesAt = epoch.millisecondsSinceEpoch + 60000;
      sockets.last.receive(cardMessage('card-1', blocks: [
        card({'closesAt': closesAt})
      ]));
      pump();
      expect(controller.ratingRequest!.requestId, 'r1');
      expect(controller.ratingRequest!.answered, isFalse);
      expect(callbacks, ['requested r1']);
      expect(events.single, isA<GiovRatingRequestedEvent>());
      // The same card again (a history catch-up) is not announced twice.
      sockets.last.receive(cardMessage('card-1', blocks: [
        card({'closesAt': closesAt})
      ]));
      pump();
      expect(callbacks, ['requested r1']);

      final result =
          settle(async, controller.submitRating(4, comment: 'Quick'));
      expect(result.score, 4);
      expect(callbacks.last, 'submitted 4');
      expect(controller.ratingRequest!.answered, isTrue);
      expect(controller.ratingRequest!.score, 4);
      expect(server.to('/conversations/conv-1/rating').single.json,
          {'score': 4, 'requestId': 'r1', 'comment': 'Quick'},
          reason: 'the open card is the default target');
      expect(
          controller.messages.firstWhere((m) => m.id == 'card-1').rating!.score,
          4);

      // Changed on another device.
      sockets.last.receive({
        'type': 'rating',
        'conversationId': 'conv-1',
        'requestId': 'r1',
        'messageId': 'card-1',
        'closesAt': closesAt,
        'score': 5
      });
      pump();
      expect(controller.ratingRequest!.score, 5);
      // A newer card replaces the old one.
      sockets.last.receive(cardMessage('card-2', createdAt: 30, blocks: [
        card({'requestId': 'r2', 'closesAt': closesAt})
      ]));
      pump();
      expect(controller.ratingRequest!.requestId, 'r2');
      expect(callbacks.last, 'requested r2');
      sockets.last.receive({
        'type': 'rating',
        'conversationId': 'conv-1',
        'requestId': 'r2',
        'messageId': 'card-2',
        'closesAt': closesAt,
        'state': 'replaced'
      });
      pump();
      expect(controller.ratingRequest!.requestId, 'r1',
          reason: 'the answered card is still open');

      // The clock closes it.
      final listened = <int>[];
      controller.addListener(() => listened.add(1));
      async.elapse(const Duration(seconds: 61));
      expect(controller.ratingRequest, isNull);
      expect(listened, isNotEmpty,
          reason: 'listeners hear about the card closing');

      // Thumbs.
      sockets.last.receive({
        'id': 'bot-1',
        'role': 'agent',
        'content': 'Hello',
        'createdAt': 40,
        'isBot': true
      });
      pump();
      settle(async,
          controller.submitAnswerFeedback('bot-1', GiovFeedbackValue.up));
      expect(controller.messages.firstWhere((m) => m.id == 'bot-1').feedback,
          GiovFeedbackValue.up);
      expect(callbacks.last, 'feedback bot-1 up');
      server.ratingHandler =
          (request) => jsonResponse({'error': 'internal'}, 500);
      expect(
          () => settle(
              async,
              controller.submitAnswerFeedback('bot-1', GiovFeedbackValue.down,
                  reason: 'no')),
          throwsA(isA<GiovServerException>()));
      expect(controller.messages.firstWhere((m) => m.id == 'bot-1').feedback,
          GiovFeedbackValue.up,
          reason: 'rolled back');
      server.ratingHandler = (request) => jsonResponse({}, 404);
      expect(
          () => settle(async,
              controller.submitAnswerFeedback('bot-1', GiovFeedbackValue.down)),
          throwsA(isA<GiovRatingException>()));
      expect(controller.ratingsSupported, isFalse);
      controller.dispose();
    });
  });

  test(
      'a closed or replaced refusal makes the card read-only or hides it on the controller',
      () {
    fakeAsync((async) {
      DateTime now() => epoch.add(async.elapsed);
      final server = FakeServer(now);
      final sockets = Sockets(async);
      final controller = GiovChatController(
        tenantKey: 't',
        baseUrl: 'https://api.example.test',
        locale: 'en',
        httpClient: server.client,
        socketFactory: sockets.create,
        now: now,
        random: NoJitter(),
      );
      void pump() {
        for (var i = 0; i < 12; i++) {
          async.flushMicrotasks();
          async.elapse(Duration.zero);
        }
      }

      unawaited(controller.start());
      pump();
      settle(async, controller.send('Hi'));
      pump();
      sockets.last.accept();
      pump();
      sockets.last.receive(cardMessage('card-1', blocks: [
        card({'closesAt': epoch.millisecondsSinceEpoch + 60000})
      ]));
      pump();
      server.ratingHandler =
          (request) => jsonResponse({'error': 'rating_closed'}, 409);
      expect(
          () => settle(async, controller.submitRating(3)),
          throwsA(isA<GiovRatingException>().having(
              (e) => e.problem, 'problem', GiovRatingProblem.ratingClosed)));
      expect(controller.ratingRequest, isNull);
      expect(
          ratingPhase(
              controller.messages.firstWhere((m) => m.id == 'card-1').rating!,
              now().millisecondsSinceEpoch),
          GiovRatingPhase.closed);
      server.ratingHandler =
          (request) => jsonResponse({'error': 'request_replaced'}, 409);
      expect(
          () => settle(async, controller.submitRating(3, requestId: 'r1')),
          throwsA(isA<GiovRatingException>().having(
              (e) => e.problem, 'problem', GiovRatingProblem.requestReplaced)));
      expect(
          controller.messages
              .firstWhere((m) => m.id == 'card-1')
              .rating!
              .replaced,
          isTrue);
      controller.dispose();
    });
  });

  // ─── The chat screen ────────────────────────────────────────────────────────────────────────────

  testWidgets(
      'the card is drawn, answered with a face and Send, shown as Thanks, then changed; the frame patches it live',
      (tester) async {
    final rig = WRig(tester);
    final events = <String>[];
    rig.controller = rig.makeController(
        onRatingRequested: (r) => events.add('requested ${r.requestId}'),
        onRatingSubmitted: (r) => events.add('submitted ${r.score}'));
    await rig.show();
    await rig.begin();
    rig.socket.receive(cardMessage('card-1',
        createdAt: DateTime.now().millisecondsSinceEpoch + 1000));
    await rig.settle();
    expect(
        find.text('How did we do? Please rate this conversation.',
            findRichText: true),
        findsOneWidget,
        reason: 'the sentence is the bubble text');
    expect(find.byKey(const ValueKey('giov-rating-form')), findsOneWidget);
    expect(events, ['requested r1']);
    // Accessibility: a radio-like group with labels; Send waits for a face.
    final great =
        tester.getSemantics(find.byKey(const ValueKey('giov-rating-face-5')));
    expect(great.label, 'Great');
    expect(great.hasFlag(SemanticsFlag.isInMutuallyExclusiveGroup), isTrue);
    expect(great.hasFlag(SemanticsFlag.hasCheckedState), isTrue);
    expect(
        tester
            .getSemantics(find.byKey(const ValueKey('giov-rating-send')))
            .hasFlag(SemanticsFlag.isEnabled),
        isFalse);

    await tester.tap(find.byKey(const ValueKey('giov-rating-face-4')));
    await tester.pump();
    expect(
        tester
            .getSemantics(find.byKey(const ValueKey('giov-rating-face-4')))
            .hasFlag(SemanticsFlag.isChecked),
        isTrue);
    await tester.enterText(
        find.byKey(const ValueKey('giov-rating-comment')), 'Quick answer');
    await tester.tap(find.byKey(const ValueKey('giov-rating-send')));
    await rig.settle();
    expect(rig.posts.last,
        {'score': 4, 'requestId': 'r1', 'comment': 'Quick answer'});
    expect(find.text('🙂 Thanks · Good'), findsOneWidget);
    expect(find.text('Quick answer'), findsOneWidget);
    expect(events.last, 'submitted 4');

    await tester.tap(find.byKey(const ValueKey('giov-rating-change')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('giov-rating-face-2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('giov-rating-send')));
    await rig.settle();
    expect(rig.posts.last['score'], 2);
    expect(find.text('🙁 Thanks · Bad'), findsOneWidget);

    rig.socket.receive({
      'type': 'rating',
      'conversationId': 'conv-1',
      'requestId': 'r1',
      'messageId': 'card-1',
      'closesAt': future,
      'score': 5
    });
    await rig.settle();
    expect(find.text('😄 Thanks · Great'), findsOneWidget);
    rig.socket.receive({
      'type': 'rating',
      'conversationId': 'conv-1',
      'requestId': 'r1',
      'messageId': 'card-1',
      'closesAt': future,
      'state': 'replaced'
    });
    await rig.settle();
    expect(find.byKey(const ValueKey('giov-rating-done')), findsNothing);
    expect(find.byKey(const ValueKey('giov-rating-form')), findsNothing);
    await rig.finish();
  });

  testWidgets(
      'a failed answer comes back with a message; closed and replaced refusals make the card read-only or hide it',
      (tester) async {
    final rig = WRig(tester);
    var answer = () => jsonResponse({}, 500);
    rig.onRating = (body) => answer();
    await rig.show();
    await rig.begin();
    rig.socket.receive(cardMessage('card-1',
        createdAt: DateTime.now().millisecondsSinceEpoch + 1000));
    await rig.settle();
    Future<void> send() async {
      await tester.tap(find.byKey(const ValueKey('giov-rating-send')));
      await rig.settle();
    }

    await tester.tap(find.byKey(const ValueKey('giov-rating-face-3')));
    await tester.pump();
    await send();
    expect(find.text("Couldn't send. Please try again."), findsOneWidget);
    expect(find.byKey(const ValueKey('giov-rating-form')), findsOneWidget,
        reason: 'the form is back');
    answer = () => jsonResponse({'error': 'too_many_changes'}, 429);
    await send();
    expect(find.text('You have changed this rating too many times.'),
        findsOneWidget);
    answer = () =>
        jsonResponse({'error': 'rate_limited'}, 429, {'retry-after': '12'});
    await send();
    expect(find.textContaining('Please wait 12 s'), findsOneWidget);
    answer = () => jsonResponse({'error': 'rating_closed'}, 409);
    await send();
    expect(find.byKey(const ValueKey('giov-rating-closed')), findsOneWidget,
        reason: 'read-only');
    expect(find.byKey(const ValueKey('giov-rating-face-3')), findsNothing);
    await rig.finish();

    final second = WRig(tester);
    second.onRating =
        (body) => jsonResponse({'error': 'request_replaced'}, 409);
    await second.show();
    await second.begin();
    second.socket.receive(cardMessage('card-1',
        createdAt: DateTime.now().millisecondsSinceEpoch + 1000));
    await second.settle();
    await tester.tap(find.byKey(const ValueKey('giov-rating-face-3')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('giov-rating-send')));
    await second.settle();
    expect(find.byKey(const ValueKey('giov-rating-form')), findsNothing);
    expect(find.byKey(const ValueKey('giov-rating-closed')), findsNothing,
        reason: 'a replaced card draws nothing');
    await second.finish();
  });

  testWidgets(
      'a card past closesAt is read-only; a newer card hides an older unanswered one',
      (tester) async {
    final rig = WRig(tester);
    await rig.show();
    await rig.begin();
    final base = DateTime.now().millisecondsSinceEpoch;
    rig.socket.receive(cardMessage('old', createdAt: base + 1000, blocks: [
      card({'requestId': 'r0', 'closesAt': base - 1000})
    ]));
    await rig.settle();
    expect(find.byKey(const ValueKey('giov-rating-closed')), findsOneWidget);
    rig.socket.receive(cardMessage('a', createdAt: base + 2000));
    rig.socket.receive(cardMessage('b', createdAt: base + 3000, blocks: [
      card({'requestId': 'r2'})
    ]));
    await rig.settle();
    expect(find.byKey(const ValueKey('giov-rating-form')), findsOneWidget,
        reason: 'only the newest open card is drawn');
    await rig.finish();
  });

  testWidgets(
      'thumbs on GiovBot answers: vote, take it back, reason on thumbs-down; none under the rating request',
      (tester) async {
    final rig = WRig(tester);
    final votes = <GiovAnswerFeedbackEvent>[];
    rig.controller = rig.makeController(onAnswerFeedback: votes.add);
    await rig.show();
    await rig.begin();
    final base = DateTime.now().millisecondsSinceEpoch;
    rig.socket.receive({
      'id': 'bot-1',
      'role': 'agent',
      'content': 'Your parcel ships today.',
      'createdAt': base + 1000,
      'isBot': true,
      'isAutomated': true
    });
    rig.socket
        .receive(cardMessage('card-bot', createdAt: base + 2000, isBot: true));
    await rig.settle();
    expect(find.byKey(const ValueKey('giov-feedback-bot-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('giov-feedback-card-bot')), findsNothing,
        reason: 'no thumbs under the GiovBot rating request');
    expect(
        tester
            .getSemantics(find.byKey(const ValueKey('giov-feedback-up')))
            .label,
        'Good answer');

    await tester.tap(find.byKey(const ValueKey('giov-feedback-up')));
    await rig.settle();
    expect(rig.feedbackPosts.last, {'value': 'up'});
    expect(
        tester
            .getSemantics(find.byKey(const ValueKey('giov-feedback-up')))
            .hasFlag(SemanticsFlag.isSelected),
        isTrue);
    await tester.tap(find.byKey(const ValueKey('giov-feedback-up')));
    await rig.settle();
    expect(rig.feedbackPosts.last, {'value': 'none'},
        reason: 'tapping the active thumb takes the vote back');
    await tester.tap(find.byKey(const ValueKey('giov-feedback-down')));
    await rig.settle();
    expect(find.byKey(const ValueKey('giov-feedback-reason')), findsOneWidget,
        reason: 'a reason is asked after thumbs-down');
    await tester.enterText(
        find.byKey(const ValueKey('giov-feedback-reason')), 'Wrong date');
    await tester.tap(find.byKey(const ValueKey('giov-feedback-send')));
    await rig.settle();
    expect(rig.feedbackPosts.last, {'value': 'down', 'reason': 'Wrong date'});
    expect(votes.last.reason, 'Wrong date');
    await rig.finish();

    // A failure rolls the thumb back and says so.
    final failing = WRig(tester);
    failing.onFeedback = (body) => jsonResponse({}, 500);
    await failing.show();
    await failing.begin();
    failing.socket.receive({
      'id': 'bot-1',
      'role': 'agent',
      'content': 'Hi',
      'createdAt': base + 1000,
      'isBot': true
    });
    await failing.settle();
    await tester.tap(find.byKey(const ValueKey('giov-feedback-up')));
    await failing.settle();
    expect(
        tester
            .getSemantics(find.byKey(const ValueKey('giov-feedback-up')))
            .hasFlag(SemanticsFlag.isSelected),
        isFalse);
    expect(find.text("Couldn't save"), findsOneWidget);
    await failing.finish();

    // An older server: the controls go away.
    final old = WRig(tester);
    old.onFeedback = (body) => jsonResponse({}, 404);
    await old.show();
    await old.begin();
    old.socket.receive({
      'id': 'bot-1',
      'role': 'agent',
      'content': 'Hi',
      'createdAt': base + 1000,
      'isBot': true
    });
    await old.settle();
    await tester.tap(find.byKey(const ValueKey('giov-feedback-up')));
    await old.settle();
    expect(find.byKey(const ValueKey('giov-feedback-bot-1')), findsNothing);
    await old.finish();

    // The host turned the thumbs off.
    final off = WRig(tester, answerFeedback: false);
    await off.show();
    await off.begin();
    off.socket.receive({
      'id': 'bot-1',
      'role': 'agent',
      'content': 'Hi',
      'createdAt': base + 1000,
      'isBot': true
    });
    await off.settle();
    expect(find.byKey(const ValueKey('giov-feedback-bot-1')), findsNothing);
    await off.finish();
  });

  testWidgets(
      'history brings the card with its answer and the earlier thumb; the interface follows the locale',
      (tester) async {
    final rig = WRig(tester, locale: 'fr');
    rig.server.history = [
      {
        'id': 'bot-1',
        'role': 'agent',
        'content': 'Hi',
        'created_at': 5,
        'is_bot': 1,
        'feedback': 'up'
      },
      cardMessage('card-1', createdAt: 6, blocks: [
        card({'score': 5, 'comment': 'Super aide'})
      ]),
    ];
    await rig.show();
    await rig.begin();
    expect(find.text('😄 Merci · Excellent'), findsOneWidget);
    expect(
        tester
            .getSemantics(find.byKey(const ValueKey('giov-feedback-up')))
            .hasFlag(SemanticsFlag.isSelected),
        isTrue);
    await rig.finish();
  });

  testWidgets(
      'the host can turn the card off, answer through the controller and open the built-in sheet',
      (tester) async {
    final rig = WRig(tester, ratingCard: false);
    await rig.show();
    await rig.begin();
    expect(rig.controller.ratingRequest, isNull);
    rig.socket.receive(cardMessage('card-1',
        createdAt: DateTime.now().millisecondsSinceEpoch + 1000));
    await rig.settle();
    expect(find.byKey(const ValueKey('giov-rating-form')), findsNothing,
        reason: 'the built-in card is off');
    expect(rig.controller.ratingRequest!.requestId, 'r1');

    final state = tester.state<GiovChatState>(find.byType(GiovChat));
    final shown = state.showRating();
    await rig.settle(80);
    expect(find.byKey(const ValueKey('giov-rating-sheet')), findsOneWidget);
    expect(find.text('Rate this conversation'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('giov-rating-face-5')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('giov-rating-send')));
    await rig.settle();
    expect(rig.posts.last, {'score': 5, 'requestId': 'r1'});
    expect(find.text('😄 Thanks · Great'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('giov-rating-sheet-close')));
    await rig.settle(80);
    expect(await shown, isTrue);
    expect(find.byKey(const ValueKey('giov-rating-sheet')), findsNothing);

    // Headless answers.
    final result = await tester
        .runAsync(() => rig.controller.submitRating(3, comment: 'Own UI'));
    expect(result!.score, 3);
    expect(
        rig.posts.last, {'score': 3, 'requestId': 'r1', 'comment': 'Own UI'});
    await rig.finish();

    // Nothing to show without a card.
    final empty = WRig(tester);
    await empty.show();
    await empty.begin();
    expect(
        await tester.runAsync(() =>
            tester.state<GiovChatState>(find.byType(GiovChat)).showRating()),
        isFalse);
    await empty.finish();
  });

  testWidgets('the sheet closes by itself when its card is replaced',
      (tester) async {
    final rig = WRig(tester, ratingCard: false);
    await rig.show();
    await rig.begin();
    rig.socket.receive(cardMessage('card-1',
        createdAt: DateTime.now().millisecondsSinceEpoch + 1000));
    await rig.settle();
    unawaited(tester.state<GiovChatState>(find.byType(GiovChat)).showRating());
    await rig.settle(80);
    expect(find.byKey(const ValueKey('giov-rating-sheet')), findsOneWidget);
    rig.socket.receive({
      'type': 'rating',
      'conversationId': 'conv-1',
      'requestId': 'r1',
      'messageId': 'card-1',
      'closesAt': future,
      'state': 'replaced'
    });
    await rig.settle(80);
    expect(find.byKey(const ValueKey('giov-rating-sheet')), findsNothing);
    await rig.finish();
  });

  // ─── Closed conversations ──────────────────────────────────────────────────────────────────────

  final closedHistory = [
    {
      'id': 'a1',
      'role': 'agent',
      'content': 'Glad that is sorted.',
      'created_at': 5,
      'is_bot': 1
    },
    cardMessage('card-1', createdAt: 6),
  ];

  testWidgets(
      'a closed conversation stays on screen read-only; its rating card renders and submits; the composer is a new-conversation button',
      (tester) async {
    final rig = WRig(tester);
    rig.server.status = 'closed';
    rig.server.history = closedHistory;
    await rig.seed();
    await rig.show();
    rig.socket.accept();
    await rig.settle();
    expect(rig.controller.closed, isTrue);
    expect(find.byKey(const ValueKey('giov-new-conversation')), findsOneWidget);
    expect(find.byKey(const ValueKey('giov-input')), findsNothing,
        reason: 'no composer');
    expect(
        find.text('Glad that is sorted.', findRichText: true), findsOneWidget,
        reason: 'the history stays visible');
    expect(find.text('Start a new conversation'), findsOneWidget);
    expect(find.byKey(const ValueKey('giov-rating-form')), findsOneWidget,
        reason: 'the card stays interactive');
    await tester.tap(find.byKey(const ValueKey('giov-rating-face-5')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('giov-rating-send')));
    await rig.settle();
    expect(rig.posts.last, {'score': 5, 'requestId': 'r1'});
    expect(find.text('😄 Thanks · Great'), findsOneWidget);
    expect(await rig.controller.send('too late'), isFalse,
        reason: 'a closed conversation takes no messages');
    await rig.finish();
  });

  testWidgets(
      'an ask-on-close card that arrives after the close renders and submits',
      (tester) async {
    final rig = WRig(tester);
    rig.server.status = 'closed';
    rig.server.history = [closedHistory[0]];
    await rig.seed();
    await rig.show();
    rig.socket.accept();
    await rig.settle();
    expect(find.byKey(const ValueKey('giov-rating-form')), findsNothing);
    rig.socket.receive(cardMessage('card-late',
        createdAt: DateTime.now().millisecondsSinceEpoch + 1000));
    await rig.settle();
    expect(find.byKey(const ValueKey('giov-rating-form')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('giov-rating-face-3')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('giov-rating-send')));
    await rig.settle();
    expect(rig.posts.last['score'], 3);
    await rig.finish();
  });

  testWidgets(
      'a 409 on resume still shows the closed conversation when its history can be read; otherwise it is forgotten',
      (tester) async {
    final rig = WRig(tester);
    rig.server
      ..resumeStatus = 409
      ..resumeError = 'conversation_closed'
      ..status = 'closed'
      ..history = closedHistory;
    await rig.seed();
    await rig.show();
    rig.socket.accept();
    await rig.settle();
    expect(find.byKey(const ValueKey('giov-new-conversation')), findsOneWidget);
    expect(
        find.text('Glad that is sorted.', findRichText: true), findsOneWidget);
    expect(find.byKey(const ValueKey('giov-rating-form')), findsOneWidget);
    await rig.finish();

    // A server that refuses the token for a closed conversation: the old behaviour.
    final refused = WRig(tester);
    refused.server
      ..resumeStatus = 409
      ..resumeError = 'conversation_closed'
      ..historyStatuses.addAll([401, 401]);
    await refused.seed();
    await refused.show();
    refused.sockets.last.accept();
    await refused.settle();
    expect(find.byKey(const ValueKey('giov-new-conversation')), findsNothing);
    expect(find.byKey(const ValueKey('giov-input')), findsOneWidget,
        reason: 'ready for a new conversation');
    expect(
        await refused.store
            .read(giovSessionScope('https://api.example.test', 't')),
        isNull);
    await refused.finish();
  });

  testWidgets(
      'starting a new conversation clears the closed one; the next message starts it',
      (tester) async {
    final rig = WRig(tester);
    rig.server.status = 'closed';
    rig.server.history = closedHistory;
    await rig.seed();
    await rig.show();
    rig.socket.accept();
    await rig.settle();
    await tester.tap(find.byKey(const ValueKey('giov-new-conversation')));
    await rig.settle();
    expect(find.byKey(const ValueKey('giov-new-conversation')), findsNothing);
    expect(find.byKey(const ValueKey('giov-input')), findsOneWidget);
    expect(find.text('Glad that is sorted.', findRichText: true), findsNothing,
        reason: 'the closed conversation is gone');
    expect(find.byKey(const ValueKey('giov-rating-form')), findsNothing);
    expect(rig.controller.closed, isFalse);
    expect(
        await rig.store.read(giovSessionScope('https://api.example.test', 't')),
        isNull);
    expect(rig.server.count('created'), 0,
        reason: 'nothing is created until the visitor writes');
    rig.server.status = 'open';
    rig.server.history = [];
    await tester.enterText(
        find.byKey(const ValueKey('giov-input')), 'Hello again');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('giov-send')));
    await rig.settle();
    expect(rig.server.count('created'), 1);
    await rig.finish();
  });

  test('every language ships the new-conversation button', () {
    for (final entry in giovStrings.entries) {
      expect(entry.value.startNewConversation.trim(), isNotEmpty,
          reason: entry.key);
    }
    expect(giovStrings['fr']!.startNewConversation,
        isNot(giovStrings['en']!.startNewConversation));
  });
}

/// A chat screen over the real controller, a fake server and hand-driven sockets.
class WRig {
  WRig(this.tester,
      {String locale = 'en',
      this.ratingCard = true,
      this.answerFeedback = true}) {
    _locale = locale;
    server.ratingHandler = _answer;
    controller = makeController();
  }

  final WidgetTester tester;
  final bool ratingCard;
  final bool answerFeedback;
  late final String _locale;
  final server = FakeServer(DateTime.now);
  final sockets = <FakeSocket>[];
  final posts = <Map<String, Object?>>[];
  final feedbackPosts = <Map<String, Object?>>[];
  late GiovChatController controller;
  SemanticsHandle? _semantics;
  final store = InMemoryGiovSessionStore();

  /// A conversation stored on this device, to be resumed when the chat opens.
  Future<void> seed() => store.write(
      giovSessionScope('https://api.example.test', 't'), testSession);

  /// Overrides for the answers (null: the normal ones).
  http.Response Function(Map<String, Object?> body)? onRating;
  http.Response Function(Map<String, Object?> body)? onFeedback;

  FakeSocket get socket => sockets.last;

  GiovChatController makeController({
    void Function(GiovRatingRequest)? onRatingRequested,
    void Function(GiovRatingResult)? onRatingSubmitted,
    void Function(GiovAnswerFeedbackEvent)? onAnswerFeedback,
  }) =>
      GiovChatController(
        tenantKey: 't',
        baseUrl: 'https://api.example.test',
        locale: _locale,
        sessionStore: store,
        httpClient: server.client,
        socketFactory: (url) {
          final socket = FakeSocket(url, Duration.zero);
          sockets.add(socket);
          return socket;
        },
        onRatingRequested: onRatingRequested,
        onRatingSubmitted: onRatingSubmitted,
        onAnswerFeedback: onAnswerFeedback,
      );

  http.Response _answer(http.Request request) {
    final body = request.body.isEmpty
        ? <String, Object?>{}
        : jsonDecode(request.body) as Map<String, Object?>;
    if (request.url.path.endsWith('/rating')) {
      posts.add(body);
      final custom = onRating;
      if (custom != null) return custom(body);
      return jsonResponse({
        'requestId': body['requestId'] ?? 'r1',
        'score': body['score'],
        if (body['comment'] != null) 'comment': body['comment'],
        'closesAt': future,
        'ratedAt': 1
      });
    }
    feedbackPosts.add(body);
    final custom = onFeedback;
    if (custom != null) return custom(body);
    return jsonResponse({
      'messageId': 'x',
      'value': body['value'] == 'none' ? null : body['value'],
      'reason': null
    });
  }

  Future<void> show() async {
    _semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GiovChat(
          controller: controller,
          ratingCard: ratingCard,
          answerFeedback: answerFeedback,
        ),
      ),
    ));
    await settle();
  }

  Future<void> settle([int rounds = 20]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
  }

  /// Types a first message, sends it, opens the socket and catches up: the conversation is active.
  Future<void> begin() async {
    await tester.enterText(find.byKey(const ValueKey('giov-input')), 'Hello');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('giov-send')));
    await settle();
    socket.accept();
    await settle();
    expect(controller.phase, GiovChatPhase.active);
  }

  Future<void> finish() async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await tester.pump(const Duration(seconds: 1));
    _semantics?.dispose();
  }
}
