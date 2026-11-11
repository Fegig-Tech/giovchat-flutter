import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:giovchat/giovchat.dart';

void main() {
  test(
      'messages leave in the order they were written, each under one id for good',
      () {
    final outbox = Outbox();
    final a = outbox.enqueue('first', now: 1, clientMessageId: 'a');
    outbox.enqueue('second',
        attachments: ['https://api.test/conversations/c/attachments/x'],
        now: 2,
        clientMessageId: 'b');
    expect(a.state, OutboxState.queued);
    final frames = outbox.takeQueued(now: 10);
    expect(frames.map((frame) => frame.clientMessageId), ['a', 'b']);
    expect(jsonDecode(frames[1].frame), {
      'type': 'message',
      'content': 'second',
      'clientMessageId': 'b',
      'attachments': ['https://api.test/conversations/c/attachments/x'],
    });
    expect((jsonDecode(frames[0].frame) as Map).containsKey('attachments'),
        isFalse,
        reason: 'no attachments key without files');
    expect(outbox.takeQueued(now: 11), isEmpty,
        reason: 'nothing is sent twice on the same socket');
  });

  test(
      'a dropped socket puts everything back in line with the same ids; an ack removes it',
      () {
    final outbox = Outbox();
    outbox.enqueue('one', now: 1, clientMessageId: 'one');
    outbox.enqueue('two', now: 2, clientMessageId: 'two');
    final first =
        outbox.takeQueued(now: 5).map((frame) => frame.frame).toList();
    outbox.socketClosed();
    expect(outbox.list().map((entry) => [entry.state, entry.sentAt]), [
      [OutboxState.queued, 0],
      [OutboxState.queued, 0],
    ]);
    expect(
        outbox.takeQueued(now: 6).map((frame) => frame.frame).toList(), first,
        reason: 'identical frames, so the server can deduplicate');
    expect(outbox.acknowledge('one'), isNotNull);
    expect(outbox.acknowledge('one'), isNull,
        reason: 'a repeated ack is ignored');
    expect(outbox.list().map((entry) => entry.clientMessageId), ['two']);
  });

  test(
      'save failures retry after 2 s and 4 s, then give up and wait for the visitor',
      () {
    final outbox = Outbox();
    outbox.enqueue('hello', now: 1, clientMessageId: 'm');
    outbox.takeQueued(now: 2);
    final delays = <Duration>[];
    OutboxRejection? outcome;
    for (var i = 0; i < maxSendFailures; i++) {
      outcome = outbox.rejected('m');
      if (!outcome!.failed) {
        delays.add(outcome.retryAfter);
        outbox.takeQueued(now: 3);
      }
    }
    expect(delays, [const Duration(seconds: 2), const Duration(seconds: 4)]);
    expect(outcome!.failed, isTrue);
    expect(outbox.get('m')!.state, OutboxState.failed);
    expect(outbox.takeQueued(now: 4), isEmpty,
        reason: 'a failed message is not sent again on its own');
    outbox.socketClosed();
    expect(outbox.get('m')!.state, OutboxState.failed,
        reason: 'reconnecting does not revive it');
    expect(outbox.retry('m'), isTrue);
    expect(
        outbox.takeQueued(now: 5).map((frame) => frame.clientMessageId), ['m']);
    expect(outbox.retry('m'), isFalse,
        reason: 'only failed messages can be retried');
  });

  test(
      'a message unanswered past the ack timeout (10 s) marks the socket as dead',
      () {
    final outbox = Outbox();
    outbox.enqueue('hi', now: 0, clientMessageId: 'x');
    expect(outbox.stale(now: ackTimeout.inMilliseconds * 5), isFalse,
        reason: 'queued messages never count');
    outbox.takeQueued(now: 1000);
    expect(outbox.stale(now: 1000 + ackTimeout.inMilliseconds), isFalse);
    expect(outbox.stale(now: 1001 + ackTimeout.inMilliseconds), isTrue);
  });

  test(
      'refusals fail the oldest message on the socket; empty and oversized messages are rejected up front',
      () {
    final outbox = Outbox();
    outbox.enqueue('a', now: 1, clientMessageId: 'a');
    outbox.enqueue('b', now: 2, clientMessageId: 'b');
    outbox.takeQueued(now: 3);
    expect(outbox.refuseOldestSending()!.clientMessageId, 'a');
    expect(outbox.list().map((entry) => entry.state),
        [OutboxState.failed, OutboxState.sending]);
    expect(
        () => outbox.enqueue('   '), throwsA(isA<GiovSendFailedException>()));
    expect(() => outbox.enqueue('x' * 2001),
        throwsA(isA<GiovSendFailedException>()));
    expect(() => outbox.enqueue('', attachments: ['https://api.test/a']),
        returnsNormally,
        reason: 'a file alone is a message');
  });

  test('listeners hear every change; client ids are unique UUIDs', () {
    final outbox = Outbox();
    var changes = 0;
    final stop = outbox.subscribe(() => changes += 1);
    outbox.enqueue('a', now: 1, clientMessageId: 'a');
    outbox.takeQueued(now: 2);
    outbox.acknowledge('a');
    stop();
    outbox.enqueue('b');
    expect(changes, 3);
    final ids = {for (var i = 0; i < 200; i++) randomClientId()};
    expect(ids.length, 200);
    expect(
        ids.first,
        matches(RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
  });
}
