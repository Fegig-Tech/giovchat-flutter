/// Visitor messages the server has not acknowledged yet, in the order they were written. Every
/// message keeps one client message id for its whole life, so resending after a dropped socket can
/// never store it twice: the server answers a repeat with the original's ack (README, "Outbox and
/// idempotency"). Pure: no sockets or timers, so the rules are testable on their own. The chat
/// controller owns one so messages typed while reconnecting or in the background are sent once a
/// socket is back; the transport only flushes it.
library;

import 'dart:convert';
import 'dart:math';

import 'errors.dart';

/// `queued`: waiting for a socket. `sending`: on a socket, no ack yet. `failed`: the visitor must
/// retry or discard ("not sent · tap to retry").
enum OutboxState { queued, sending, failed }

class OutboxEntry {
  OutboxEntry({
    required this.clientMessageId,
    required this.content,
    required this.attachments,
    required this.createdAt,
    this.state = OutboxState.queued,
    this.sentAt = 0,
    this.failures = 0,
  });

  final String clientMessageId;
  final String content;

  /// Uploaded attachment URLs this message carries.
  final List<String> attachments;

  /// Unix milliseconds.
  final int createdAt;
  OutboxState state;

  /// When it last went out on a socket (Unix ms); 0 while it is waiting for one.
  int sentAt;

  /// Times the server said it could not save it.
  int failures;

  OutboxEntry copy() => OutboxEntry(
        clientMessageId: clientMessageId,
        content: content,
        attachments: List.of(attachments),
        createdAt: createdAt,
        state: state,
        sentAt: sentAt,
        failures: failures,
      );
}

/// A sent message with no ack after this long means a dead socket: reconnect and resend.
const ackTimeout = Duration(seconds: 10);

/// Save failures retried before the visitor is told the message did not send.
const maxSendFailures = 3;
const maxMessageChars = 2000;

/// Wait before resending after a save failure: 2 s, 4 s, …
Duration sendRetryDelay(int failures) =>
    Duration(milliseconds: 2000 * failures);

final _random = Random.secure();

/// A random (version 4) UUID, made on the device.
String randomClientId() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex =
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class OutboxFrame {
  const OutboxFrame(this.clientMessageId, this.frame);
  final String clientMessageId;

  /// The JSON text to put on the socket.
  final String frame;
}

class OutboxRejection {
  const OutboxRejection({required this.failed, required this.retryAfter});

  /// True once the message gave up; the visitor decides.
  final bool failed;
  final Duration retryAfter;
}

class Outbox {
  Outbox({int Function()? now})
      : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _now;
  final Map<String, OutboxEntry> _entries = {};
  final List<void Function()> _listeners = [];

  /// Calls [listener] after every change; returns the function that stops it.
  void Function() subscribe(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _changed() {
    for (final listener in List.of(_listeners)) {
      try {
        listener();
      } on Object {
        // Listeners cannot break the queue.
      }
    }
  }

  /// Copies, oldest first.
  List<OutboxEntry> list() =>
      [for (final entry in _entries.values) entry.copy()];
  OutboxEntry? get(String clientMessageId) => _entries[clientMessageId]?.copy();
  int get size => _entries.length;

  /// Adds a message at the end. Throws [GiovSendFailedException] when it could never be accepted
  /// (empty or too long).
  OutboxEntry enqueue(String content,
      {List<String> attachments = const [],
      int? now,
      String? clientMessageId}) {
    if ((content.trim().isEmpty && attachments.isEmpty) ||
        content.length > maxMessageChars) {
      throw const GiovSendFailedException(
          'Messages must contain 1-2000 characters.');
    }
    final id = clientMessageId ?? randomClientId();
    final entry = OutboxEntry(
        clientMessageId: id,
        content: content,
        attachments: List.of(attachments),
        createdAt: now ?? _now());
    _entries[id] = entry;
    _changed();
    return entry.copy();
  }

  /// The wire frame; identical every time it is sent.
  static String frame(OutboxEntry entry) =>
      jsonFrame(entry.clientMessageId, entry.content, entry.attachments);

  static String jsonFrame(
          String clientMessageId, String content, List<String> attachments) =>
      jsonEncode({
        'type': 'message',
        'content': content,
        'clientMessageId': clientMessageId,
        if (attachments.isNotEmpty) 'attachments': attachments,
      });

  /// Everything waiting for a socket, in order, marked as sent now. Failed messages wait for [retry].
  List<OutboxFrame> takeQueued({int? now}) {
    final out = <OutboxFrame>[];
    final time = now ?? _now();
    for (final entry in _entries.values) {
      if (entry.state != OutboxState.queued) continue;
      entry.state = OutboxState.sending;
      entry.sentAt = time;
      out.add(OutboxFrame(entry.clientMessageId, frame(entry)));
    }
    if (out.isNotEmpty) _changed();
    return out;
  }

  /// The server saved it: the message leaves the queue. Unknown ids (already acknowledged) return null.
  OutboxEntry? acknowledge(String clientMessageId) {
    final entry = _entries.remove(clientMessageId);
    if (entry == null) return null;
    _changed();
    return entry;
  }

  /// The server could not save it: wait and resend, or give up after [maxSendFailures].
  OutboxRejection? rejected(String clientMessageId) {
    final entry = _entries[clientMessageId];
    if (entry == null || entry.state == OutboxState.failed) return null;
    entry.failures += 1;
    entry.sentAt = 0;
    entry.state = entry.failures >= maxSendFailures
        ? OutboxState.failed
        : OutboxState.queued;
    _changed();
    final failed = entry.state == OutboxState.failed;
    return OutboxRejection(
        failed: failed,
        retryAfter: failed ? Duration.zero : sendRetryDelay(entry.failures));
  }

  /// A message the server refused outright (invalid content or attachment): no retry can fix it.
  OutboxEntry? refuseOldestSending() {
    for (final entry in _entries.values) {
      if (entry.state != OutboxState.sending) continue;
      entry.state = OutboxState.failed;
      entry.sentAt = 0;
      _changed();
      return entry.copy();
    }
    return null;
  }

  /// The socket went away: whatever was on it goes out again on the next one, with the same ids.
  void socketClosed() {
    var changed = false;
    for (final entry in _entries.values) {
      if (entry.state == OutboxState.sending) {
        entry.state = OutboxState.queued;
        entry.sentAt = 0;
        changed = true;
      }
    }
    if (changed) _changed();
  }

  /// True when a message has waited longer than [ackTimeout] on an open socket.
  bool stale({int? now}) {
    final time = now ?? _now();
    for (final entry in _entries.values) {
      if (entry.state == OutboxState.sending &&
          entry.sentAt > 0 &&
          time - entry.sentAt > ackTimeout.inMilliseconds) {
        return true;
      }
    }
    return false;
  }

  /// The visitor asked to try a failed message again: it rejoins the queue in its original place.
  bool retry(String clientMessageId) {
    final entry = _entries[clientMessageId];
    if (entry == null || entry.state != OutboxState.failed) return false;
    entry.state = OutboxState.queued;
    entry.failures = 0;
    entry.sentAt = 0;
    _changed();
    return true;
  }

  bool remove(String clientMessageId) {
    final removed = _entries.remove(clientMessageId) != null;
    if (removed) _changed();
    return removed;
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    _changed();
  }
}
