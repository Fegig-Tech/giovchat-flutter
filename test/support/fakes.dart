import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:giovchat/giovchat.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final testSession =
    GiovSession(conversationId: 'conv-1', sessionToken: 'b' * 64);
final epoch = DateTime.utc(2026, 1, 1);

/// A random source whose jitter is always zero, so backoff delays are exact.
class NoJitter implements Random {
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0;
  @override
  int nextInt(int max) => 0;
}

/// A socket the test drives by hand.
class FakeSocket extends GiovSocket {
  FakeSocket(this.url, this.createdAt, {this.autoPong = true});

  final Uri url;
  final Duration createdAt;

  /// Answer pings at once, like a healthy server.
  final bool autoPong;
  final List<String> sent = [];
  bool open = false;
  bool closedByClient = false;

  @override
  bool get isOpen => open;

  @override
  void send(String frame) {
    if (!open) throw StateError('not open');
    sent.add(frame);
    // A real server answers after the ping has left, never inside send().
    if (autoPong && frame == '{"type":"ping"}') {
      scheduleMicrotask(() => open ? onMessage?.call('{"type":"pong"}') : null);
    }
  }

  @override
  void close([int? code, String? reason]) {
    closedByClient = true;
    open = false;
  }

  void accept() {
    open = true;
    onOpen?.call();
  }

  void receive(Map<String, Object?> frame) =>
      onMessage?.call(jsonEncode(frame));

  /// The server (or network) ended the socket.
  void drop([int? code, String? reason]) {
    open = false;
    onClose?.call(code, reason);
  }

  List<Map<String, Object?>> frames([String? type]) => [
        for (final text in sent)
          if ((jsonDecode(text) as Map<String, Object?>)['type'] == type ||
              type == null)
            jsonDecode(text) as Map<String, Object?>,
      ];

  /// Message frames only (no pings or typing).
  List<Map<String, Object?>> messageFrames() => frames('message');
}

class Sockets {
  Sockets(this.async);
  final FakeAsync async;
  final List<FakeSocket> all = [];
  bool autoPong = true;
  FakeSocket get last => all.last;

  GiovSocket create(Uri url) {
    final socket = FakeSocket(url, async.elapsed, autoPong: autoPong);
    all.add(socket);
    return socket;
  }
}

class LoggedRequest {
  LoggedRequest(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String body;

  String get path => uri.path;
  Map<String, Object?> get json =>
      body.isEmpty ? const {} : jsonDecode(body) as Map<String, Object?>;
}

/// A small Giov API: config, conversation start/resume, tokens, history, upload and push.
class FakeServer {
  FakeServer(this.now);

  final DateTime Function() now;
  final List<LoggedRequest> requests = [];
  final Map<String, int> calls = {};

  Map<String, Object?> config = {
    'title': 'Acme',
    'theme': 'light',
    'primaryColor': '#123456',
    'greetingText': 'Hi',
    'botEnabled': true,
    'botName': 'Atlas',
    'botAvatarUrl': 'https://cdn.test/atlas.png',
    'avatarUrl': 'https://cdn.test/team.png',
  };
  List<Object?> history = [];
  String status = 'open';
  String? assignedAgentName;
  String? assignedAgentAvatar;

  /// Status codes to answer the next calls with (one per call), before the normal behaviour.
  final List<int> historyStatuses = [];
  final List<int> tokenStatuses = [];
  final List<int> uploadStatuses = [];

  /// Never answer uploads (a stalled network).
  bool hangUploads = false;
  int? resumeStatus;
  String? resumeError;
  int? startStatus;
  String? startError;
  int pushStatus = 200;
  int tokenLifetimeSeconds = 900;
  int createdCounter = 0;

  /// Answers the rating and answer-feedback routes (404 without it, like an older server).
  http.Response Function(http.Request request)? ratingHandler;

  /// The id the next started conversation gets.
  String nextConversationId = 'conv-1';

  http.Client get client => MockClient(_handle);

  int count(String key) => calls[key] ?? 0;
  Iterable<LoggedRequest> to(String path, [String? method]) =>
      requests.where((request) =>
          request.path == path && (method == null || request.method == method));

  http.Response _json(Object? body,
          [int status = 200, Map<String, String> headers = const {}]) =>
      http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json', ...headers});

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    requests.add(LoggedRequest(
        request.method, request.url, request.headers, request.body));
    void bump(String key) => calls[key] = count(key) + 1;
    if (path == '/widget/config') {
      bump('config');
      return _json(config);
    }
    if (path == '/conversations' && request.method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      if (body['conversationId'] != null) {
        bump('resumed');
        if (resumeStatus != null) {
          return _json(
              {'error': resumeError ?? 'invalid_session'}, resumeStatus!);
        }
        return _json({
          'conversationId': body['conversationId'],
          'sessionToken': testSession.sessionToken
        });
      }
      bump('created');
      if (startStatus != null) {
        return _json({'error': startError ?? 'workspace_busy'}, startStatus!,
            startStatus == 503 ? {'retry-after': '30'} : const {});
      }
      return _json({
        'conversationId': nextConversationId,
        'sessionToken': testSession.sessionToken,
        'wsUrl': 'wss://api.example.test/conversations/$nextConversationId/ws'
      });
    }
    if (path == '/auth/widget-token') {
      bump('token');
      if (tokenStatuses.isNotEmpty) {
        return _json({'error': 'invalid_session'}, tokenStatuses.removeAt(0));
      }
      return _json({
        'token': 'visitor-token-${count('token')}',
        'expiresAt':
            now().millisecondsSinceEpoch ~/ 1000 + tokenLifetimeSeconds,
        'attachmentAccess': {
          'token': 'access-token-abcdefgh',
          'expiresAt': now().millisecondsSinceEpoch + 3600000
        },
      });
    }
    if (path.endsWith('/history')) {
      bump('history');
      if (historyStatuses.isNotEmpty) {
        return _json({'error': 'unauthorized'}, historyStatuses.removeAt(0));
      }
      return _json({
        'status': status,
        'messages': history,
        'assignedAgentName': assignedAgentName,
        'assignedAgentAvatar': assignedAgentAvatar
      });
    }
    if (path.endsWith('/upload-visitor')) {
      bump('upload');
      if (hangUploads) return Completer<http.Response>().future;
      if (uploadStatuses.isNotEmpty) {
        return _json({'error': 'invalid_token'}, uploadStatuses.removeAt(0));
      }
      final name =
          RegExp(r'filename="([^"]+)"').firstMatch(request.body)?.group(1) ??
              'a.png';
      return _json({
        'url':
            'https://api.example.test/conversations/conv-1/attachments/$name',
        'filename': name
      });
    }
    if (path.endsWith('/push-token')) {
      bump('push-${request.method}');
      return pushStatus == 200
          ? _json({'registered': true})
          : _json({'error': 'not_found'}, pushStatus);
    }
    if (path.endsWith('/rating') || path.contains('/feedback')) {
      bump(path.endsWith('/rating') ? 'rating' : 'feedback');
      final handler = ratingHandler;
      if (handler != null) return handler(request);
    }
    return _json({'error': 'not_found'}, 404);
  }
}

/// Runs [future] to completion inside [async] (flushing microtasks) and returns its value.
T settle<T>(FakeAsync async, Future<T> future) {
  T? value;
  Object? error;
  var done = false;
  future.then((result) {
    value = result;
    done = true;
  }, onError: (Object e) {
    error = e;
    done = true;
  });
  // Some plumbing (multipart streams) queues zero-delay timers; let them run without moving the clock.
  for (var round = 0; round < 20 && !done; round++) {
    async.flushMicrotasks();
    if (!done) async.elapse(Duration.zero);
  }
  async.flushMicrotasks();
  if (!done) throw StateError('The future is still pending.');
  if (error != null) throw error!;
  return value as T;
}

/// A [GiovSessionStore] that records what happens.
class RecordingStore extends InMemoryGiovSessionStore {
  final List<String> log = [];

  @override
  Future<void> write(String scope, GiovSession session) {
    log.add('write');
    return super.write(scope, session);
  }

  @override
  Future<void> delete(String scope) {
    log.add('delete');
    return super.delete(scope);
  }
}
