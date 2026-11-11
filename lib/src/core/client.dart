/// The visitor protocol client (docs/protocol/README.md): configuration, starting and resuming a
/// conversation, visitor tokens, the conversation socket with its heartbeat and reconnects,
/// history, streaming replies, typing, uploads and push registration. Pure Dart: no widgets.
///
/// The client is transport only. It reports what happens through streams and leaves the
/// protocol's catch-up order (open, history, merge, resend) to its owner, normally
/// `GiovChatController`: construct it with `flushOnOpen: false`, call [connect], load
/// [fetchHistory], merge, then [flush].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'attachments.dart';
import 'errors.dart';
import 'models.dart';
import 'outbox.dart';
import 'socket.dart';

/// Keep in step with pubspec.yaml; sent as `X-Giov-Client` so the dashboard can show where the
/// chat is installed.
const giovSdkVersion = '0.1.0';
const giovClientMarker = 'flutter/$giovSdkVersion';
const giovDefaultBaseUrl = 'https://api.giovchat.app';

/// Connection timings from the visitor protocol.
const socketOpenTimeout = Duration(seconds: 10);
const socketPingInterval = Duration(seconds: 25);
const socketPongTimeout = Duration(seconds: 10);
const requestTimeout = Duration(seconds: 15);
const uploadTimeout = Duration(seconds: 120);

/// Retry waits: `min(1500 × 2^attempt, 15000)` ms plus a little jitter (0 to 400 ms); the attempt
/// counter resets after a successful connect.
Duration giovReconnectDelay(int attempt, {double jitter = 0}) {
  final base = attempt >= 4 ? 15000 : min(1500 * (1 << attempt), 15000);
  return Duration(milliseconds: base + (jitter.clamp(0, 1) * 400).floor());
}

/// Validates the API base URL and removes a trailing slash.
String normalizeBaseUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !{'https', 'http'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const GiovInvalidResponseException(
        'Use an HTTP(S) API URL without credentials, query parameters or fragments.');
  }
  return uri.toString().replaceAll(RegExp(r'/$'), '');
}

/// A GiovBot reply arriving word by word: the whole text so far, then an end once it is saved or dropped.
sealed class GiovStreamEvent {
  const GiovStreamEvent(this.streamId);

  /// The visitor message this reply answers.
  final String streamId;
}

class GiovStreamUpdate extends GiovStreamEvent {
  const GiovStreamUpdate(super.streamId, this.content);

  /// The WHOLE reply so far, not a delta.
  final String content;
}

class GiovStreamEnd extends GiovStreamEvent {
  const GiovStreamEnd(super.streamId);
}

/// The server stored a visitor message; [message] replaces the optimistic copy, in place.
class GiovAck {
  const GiovAck(this.clientMessageId, this.message);
  final String clientMessageId;
  final GiovMessage message;
}

/// The agent side started or stopped typing. [isBot] is null when the server did not say; on a
/// stop it names whose indicator ends (a person's stop must not hide the bot's, and the reverse).
class GiovTypingEvent {
  const GiovTypingEvent({required this.active, this.isBot});
  final bool active;
  final bool? isBot;
}

class GiovUploadResult {
  const GiovUploadResult(
      {required this.url, required this.filename, this.preview});
  final String url;
  final String filename;
  final GiovAttachmentPreview? preview;
}

/// `ios` and `android` are accepted aliases (APNs for a hex token, FCM otherwise); use `apns` or
/// `fcm` to be explicit.
enum GiovPushPlatform { ios, android, apns, fcm }

enum GiovPushEnvironment { sandbox, production }

class GiovPushOptions {
  const GiovPushOptions({this.environment, this.appId, this.locale});

  /// APNs only: [GiovPushEnvironment.sandbox] for development builds (Xcode), production (the
  /// default) for TestFlight and the App Store.
  final GiovPushEnvironment? environment;

  /// The bundle id (iOS) or package name (Android).
  final String? appId;

  /// BCP 47 language for the generic notification text; defaults to the client's locale.
  final String? locale;
}

enum GiovPushFailure {
  /// The server has no visitor push (404, 405 or 501); the client stops asking.
  unsupported,
  noConversation,
  failed,
}

class GiovPushResult {
  const GiovPushResult.registered() : failure = null;
  const GiovPushResult.notRegistered(GiovPushFailure this.failure);
  final GiovPushFailure? failure;
  bool get registered => failure == null;

  @override
  String toString() =>
      registered ? 'GiovPushResult.registered' : 'GiovPushResult($failure)';
}

class _Reply {
  const _Reply(this.status, this.body, this.retryAfter);
  final int status;
  final Map<String, Object?> body;
  final Duration retryAfter;
  bool get ok => status >= 200 && status < 300;
  String? get code => body['error'] is String ? body['error']! as String : null;
}

GiovChatException toGiovException(Object error) =>
    error is GiovChatException ? error : GiovNetworkException('$error');

/// Transport for one workspace. Create one per chat; [connect] one conversation at a time.
class GiovChatClient {
  GiovChatClient({
    required this.tenantKey,
    String baseUrl = giovDefaultBaseUrl,
    Outbox? outbox,
    this.flushOnOpen = true,
    this.locale,
    http.Client? httpClient,
    GiovSocketFactory? socketFactory,
    DateTime Function()? now,
    Random? random,
  })  : baseUrl = normalizeBaseUrl(baseUrl),
        outbox = outbox ??
            Outbox(
                now: now == null ? null : () => now().millisecondsSinceEpoch),
        _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null,
        _socketFactory = socketFactory ?? defaultGiovSocketFactory,
        _clock = now ?? DateTime.now,
        _random = random ?? Random();

  /// The workspace key (public).
  final String tenantKey;
  final String baseUrl;

  /// Messages waiting for the server. Pass one that outlives this client so messages typed while
  /// reconnecting or in the background are sent once a socket is back.
  final Outbox outbox;

  /// Send the outbox as soon as a socket opens (default). The chat controller turns this off and
  /// calls [flush] after the history catch-up, in the protocol's order.
  final bool flushOnOpen;

  /// BCP 47 language sent with push registrations.
  final String? locale;

  final http.Client _http;
  final bool _ownsHttp;
  final GiovSocketFactory _socketFactory;
  final DateTime Function() _clock;
  final Random _random;

  final _messages = StreamController<GiovMessage>.broadcast(sync: true);
  final _acks = StreamController<GiovAck>.broadcast(sync: true);
  final _connection = StreamController<bool>.broadcast(sync: true);
  final _typing = StreamController<GiovTypingEvent>.broadcast(sync: true);
  final _errors = StreamController<GiovChatException>.broadcast(sync: true);
  final _streams = StreamController<GiovStreamEvent>.broadcast(sync: true);
  final _access = StreamController<AttachmentAccess>.broadcast(sync: true);

  /// Chat messages from the socket: replies, and (rarely) the visitor's own from another device.
  /// A saved GiovBot reply carries `clientMessageId == 'stream:<streamId>'`, the key its draft had.
  Stream<GiovMessage> get messages => _messages.stream;

  /// Stored copies of the visitor's own messages.
  Stream<GiovAck> get acks => _acks.stream;

  /// True when a socket opens, false when it closes or the client disconnects.
  Stream<bool> get connection => _connection.stream;
  Stream<GiovTypingEvent> get typing => _typing.stream;

  /// Failures that are not the answer to a call you made: refused messages, a dead session, a
  /// deleted conversation ([GiovConversationClosedException]), reconnect attempts that failed.
  Stream<GiovChatException> get errors => _errors.stream;
  Stream<GiovStreamEvent> get streamEvents => _streams.stream;

  /// A newer attachment download token arrived (with a visitor token, an upload or history).
  Stream<AttachmentAccess> get attachmentAccess => _access.stream;

  GiovSocket? _socket;
  void Function()? _dropSocket;
  void Function()? _cancelHandshake;
  Timer? _reconnectTimer;
  Timer? _heartbeat;
  Timer? _watchdog;
  final _resendTimers = <Timer>{};
  int _generation = 0;
  bool _desired = false;
  bool _disposed = false;
  int _attempt = 0;
  GiovSession? _session;
  VisitorToken? _visitorToken;
  Future<VisitorToken>? _tokenRequest;
  bool _pushUnsupported = false;
  final _pending = <String, List<Completer<GiovMessage>>>{};

  int _nowMs() => _clock().millisecondsSinceEpoch;

  bool get isConnected => _socket?.isOpen ?? false;

  /// The conversation this client is connected (or connecting) to.
  GiovSession? get session => _session;

  /// The current visitor token, a fallback credential for attachment downloads.
  String? get visitorToken => _visitorToken?.token;

  /// [visitorToken] while it has not expired, else null (an expired one cannot open anything).
  String? get usableVisitorToken {
    final token = _visitorToken;
    return token != null && token.expiresAt.isAfter(_clock())
        ? token.token
        : null;
  }

  /// Asks for a new visitor token now (which also brings a fresh attachment access token, see
  /// [attachmentAccess]). Never throws; false when there is no conversation or the request failed.
  Future<bool> renewVisitorToken() async {
    if (_session == null) return false;
    try {
      await _token(force: true);
      return true;
    } on Object {
      return false;
    }
  }

  void _emit<T>(StreamController<T> controller, T value) {
    if (!controller.isClosed) controller.add(value);
  }

  // ---------------------------------------------------------------------------------------------
  // HTTP

  Future<_Reply> _request(String method, String path,
      {Map<String, String> headers = const {}, Object? json}) async {
    final request = http.Request(method, Uri.parse(baseUrl + path))
      ..headers.addAll(headers);
    if (json != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(json);
    }
    try {
      final response = await (() async =>
              http.Response.fromStream(await _http.send(request)))()
          .timeout(requestTimeout);
      return _reply(response);
    } on TimeoutException {
      throw const GiovNetworkException('Chat request timed out.',
          timedOut: true);
    } on GiovChatException {
      rethrow;
    } on Object catch (error) {
      throw GiovNetworkException('$error');
    }
  }

  _Reply _reply(http.Response response) {
    Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      body = null;
    }
    final seconds = int.tryParse(response.headers['retry-after'] ?? '');
    return _Reply(
        response.statusCode, asMap(body), Duration(seconds: seconds ?? 30));
  }

  /// Maps an unsuccessful reply to the SDK's typed failures (README, "Errors, limits and headers").
  /// On routes that take the session, 401/403 mean the session is gone.
  GiovChatException _failure(_Reply reply, {bool sessionRoute = false}) {
    final code = reply.code;
    final message = reply.body['message'] is String
        ? reply.body['message']! as String
        : (code ?? 'HTTP ${reply.status}');
    if (code == 'invalid_user_hash') {
      return GiovIdentityRejectedException(message);
    }
    if (reply.status == 429) {
      return GiovRateLimitedException(message, retryAfter: reply.retryAfter);
    }
    if (reply.status == 503 && code == 'workspace_busy') {
      return GiovWorkspaceBusyException(message, retryAfter: reply.retryAfter);
    }
    if (reply.status == 409 || code == 'conversation_closed') {
      return GiovConversationClosedException(message,
          status: reply.status, code: code);
    }
    if (sessionRoute && (reply.status == 401 || reply.status == 403)) {
      return GiovSessionExpiredException(message,
          status: reply.status, code: code);
    }
    return GiovServerException(message, status: reply.status, code: code);
  }

  /// `GET /widget/config`, with the client marker header.
  Future<GiovWidgetConfig> fetchWidgetConfig() async {
    final reply = await _request(
        'GET', '/widget/config?tenantId=${Uri.encodeQueryComponent(tenantKey)}',
        headers: {'X-Giov-Client': giovClientMarker});
    if (!reply.ok) throw _failure(reply);
    if (reply.body['title'] is! String) {
      throw const GiovInvalidResponseException('Invalid widget configuration.');
    }
    return GiovWidgetConfig.fromJson(reply.body);
  }

  /// `POST /conversations` without a session: starts a new conversation. Call it when the visitor
  /// sends the first message or submits the pre-chat form, never just for opening the screen.
  Future<GiovSession> startConversation([GiovContact? contact]) =>
      _conversation(contact, null);

  /// `POST /conversations` with the stored session: resumes it. Throws
  /// [GiovSessionExpiredException] / [GiovConversationClosedException] (or a 404
  /// [GiovServerException]) when the stored pair must be forgotten.
  Future<GiovSession> resumeConversation(GiovSession session,
          [GiovContact? contact]) =>
      _conversation(contact, session);

  Future<GiovSession> _conversation(
      GiovContact? contact, GiovSession? existing) async {
    final reply = await _request(
      'POST',
      '/conversations',
      headers: {
        if (existing != null) 'Authorization': 'Bearer ${existing.sessionToken}'
      },
      json: {
        'tenantId': tenantKey,
        ...?contact?.toStartFields(),
        if (existing != null) 'conversationId': existing.conversationId
      },
    );
    if (!reply.ok) throw _failure(reply, sessionRoute: existing != null);
    final id = reply.body['conversationId'], token = reply.body['sessionToken'];
    if (id is! String ||
        id.isEmpty ||
        token is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) {
      throw const GiovInvalidResponseException(
          'Invalid chat session response.');
    }
    return GiovSession(conversationId: id, sessionToken: token);
  }

  Future<VisitorToken> _fetchToken(GiovSession session) async {
    final reply = await _request(
      'POST',
      '/auth/widget-token',
      headers: {'Authorization': 'Bearer ${session.sessionToken}'},
      json: {'tenantId': tenantKey, 'conversationId': session.conversationId},
    );
    if (!reply.ok) throw _failure(reply, sessionRoute: true);
    try {
      return VisitorToken.fromJson(reply.body, _clock());
    } on FormatException {
      throw const GiovInvalidResponseException('Invalid chat token response.');
    }
  }

  /// The visitor token; renewed when less than a minute is left. One request at a time.
  Future<VisitorToken> _token({bool force = false}) {
    final session = _session;
    if (session == null) return Future.error(const GiovDisconnectedException());
    final cached = _visitorToken;
    if (!force && cached != null && cached.usableAt(_clock())) {
      return Future.value(cached);
    }
    return _tokenRequest ??= _fetchToken(session).then((value) {
      if (identical(_session, session)) {
        _visitorToken = value;
        final access = value.attachmentAccess;
        if (access != null) _emit(_access, access);
      }
      return value;
    }).whenComplete(() => _tokenRequest = null);
  }

  /// A call with the visitor token: a 401 renews the token once and retries; a second 401 means
  /// the session is gone ([GiovSessionExpiredException]).
  Future<_Reply> _authed(String method, String path,
      {Object? json, Map<String, String> headers = const {}}) async {
    var token = await _token();
    var reply = await _request(method, path,
        headers: {...headers, 'Authorization': 'Bearer ${token.token}'},
        json: json);
    if (reply.status == 401) {
      token = await _token(force: true);
      reply = await _request(method, path,
          headers: {...headers, 'Authorization': 'Bearer ${token.token}'},
          json: json);
    }
    return reply;
  }

  String get _conversationPath =>
      '/conversations/${Uri.encodeComponent(_session!.conversationId)}';

  /// `GET /conversations/{id}/history` for the connected session. A 404 is a [GiovServerException]
  /// with `status == 404`: the conversation is gone, forget it.
  Future<GiovHistory> fetchHistory() async {
    if (_session == null) throw const GiovDisconnectedException();
    final reply = await _authed('GET', '$_conversationPath/history');
    if (!reply.ok) throw _failure(reply, sessionRoute: true);
    if (reply.body['messages'] is! List) {
      throw const GiovInvalidResponseException('Invalid conversation history.');
    }
    final history = GiovHistory.fromJson(reply.body);
    final access = history.attachmentAccess;
    if (access != null) _emit(_access, access);
    return history;
  }

  // ---------------------------------------------------------------------------------------------
  // Socket

  /// Uses [session] and opens the socket, resolving once it is open. Fails with a typed exception
  /// (no automatic retry for this first attempt); after it has opened once, a dropped socket is
  /// retried with backoff by the client itself.
  Future<void> connect(GiovSession session) async {
    // Messages already waiting in the outbox are kept: they go out on this socket.
    _teardown();
    _desired = true;
    _session = session;
    _attempt = 0;
    await _open(_generation);
  }

  Future<void> _open(int generation) async {
    if (!_desired || _session == null || generation != _generation) return;
    final token = (await _token(force: true)).token;
    final session = _session;
    if (!_desired || generation != _generation || session == null) {
      throw const GiovDisconnectedException();
    }
    final api = Uri.parse(baseUrl);
    final url = Uri(
      scheme: api.scheme == 'https' ? 'wss' : 'ws',
      host: api.host,
      port: api.hasPort ? api.port : null,
      path:
          '${api.path}/conversations/${Uri.encodeComponent(session.conversationId)}/ws',
      queryParameters: {'role': 'user', 'token': token},
    );
    final done = Completer<void>();
    final socket = _socketFactory(url);
    _socket = socket;
    var opened = false;
    Timer? openTimer;
    Timer? pongDeadline;

    void finish([GiovChatException? error]) {
      if (done.isCompleted) return;
      openTimer?.cancel();
      if (error == null) {
        done.complete();
      } else {
        done.completeError(error);
      }
    }

    void closed(int? code, String? reason) {
      pongDeadline?.cancel();
      if (generation != _generation || !identical(_socket, socket)) return;
      _socket = null;
      _dropSocket = null;
      socket
        ..onOpen = null
        ..onMessage = null
        ..onError = null
        ..onClose = null;
      outbox.socketClosed();
      _heartbeat?.cancel();
      _watchdog?.cancel();
      _heartbeat = _watchdog = null;
      _emit(_connection, false);
      finish(const GiovNetworkException('Chat connection closed.'));
      if (code == 1000 && reason == 'Conversation deleted') {
        // The conversation is gone: no reconnect; the owner forgets the stored session.
        _desired = false;
        _emit(
            _errors,
            const GiovConversationClosedException(
                'This conversation has ended.'));
        return;
      }
      if (opened) _reconnect(generation);
    }

    void drop() {
      socket.close();
      closed(null, null);
    }

    _cancelHandshake = () => finish(const GiovDisconnectedException());
    openTimer = Timer(socketOpenTimeout, () {
      finish(const GiovNetworkException('Chat connection timed out.',
          timedOut: true));
      drop();
    });

    socket.onOpen = () {
      if (generation != _generation || !_desired || done.isCompleted) {
        socket.close();
        return;
      }
      opened = true;
      _attempt = 0;
      _dropSocket = drop;
      _emit(_connection, true);
      // A ping every 25 s; no pong within 10 s means the socket is dead.
      _heartbeat = Timer.periodic(socketPingInterval, (_) {
        try {
          socket.send(jsonEncode({'type': 'ping'}));
        } on Object {
          drop();
          return;
        }
        pongDeadline?.cancel();
        pongDeadline = Timer(socketPongTimeout, drop);
      });
      // A message on a socket that never answered means the socket is dead: reconnect and resend.
      _watchdog = Timer.periodic(const Duration(seconds: 3), (_) {
        if (outbox.stale(now: _nowMs())) drop();
      });
      finish();
      if (flushOnOpen) flush();
    };
    socket.onError = (_) {
      finish(const GiovNetworkException('Unable to connect to chat.'));
    };
    socket.onClose = closed;
    socket.onMessage = (data) {
      if (generation != _generation || !identical(_socket, socket)) return;
      Object? decoded;
      try {
        decoded = jsonDecode(data);
      } on FormatException {
        return;
      }
      _receive(asMap(decoded), () {
        pongDeadline?.cancel();
        pongDeadline = null;
      });
    };
    await done.future;
  }

  void _receive(Map<String, Object?> data, void Function() pong) {
    final type = data['type'];
    if (type == 'pong') {
      pong();
      return;
    }
    if (type == 'typing' || type == 'typing_end') {
      if (data['role'] == 'agent') {
        _emit(
            _typing,
            GiovTypingEvent(
                active: type == 'typing',
                isBot: data['isBot'] is bool ? data['isBot']! as bool : null));
      }
      return;
    }
    final streamId = data['streamId'];
    if (type == 'stream' && streamId is String) {
      _emit(
          _streams,
          GiovStreamUpdate(streamId,
              data['content'] is String ? data['content']! as String : ''));
      return;
    }
    if (type == 'stream_end' && streamId is String) {
      _emit(_streams, GiovStreamEnd(streamId));
      return;
    }
    if (type == 'error') {
      _serverError(data);
      return;
    }
    final clientMessageId = data['clientMessageId'];
    if (type == 'message_ack' && clientMessageId is String) {
      final message =
          GiovMessage.fromJson({...asMap(data['message']), 'role': 'visitor'});
      final entry = outbox.acknowledge(clientMessageId);
      if (message != null) {
        _emit(_acks, GiovAck(clientMessageId, message));
        _settle(clientMessageId, message);
      } else if (entry != null) {
        _settle(clientMessageId, null);
      }
      return;
    }
    // Unknown frame types are ignored (protocol versioning).
    if (type != null && type != 'message') return;
    var message = GiovMessage.fromJson(data);
    if (message == null) return;
    // The saved reply takes the place of its streamed draft, under the draft's key so it is not redrawn.
    if (streamId is String) {
      message = message.copyWith(clientMessageId: 'stream:$streamId');
    }
    _emit(_messages, message);
    if (streamId is String) _emit(_streams, GiovStreamEnd(streamId));
  }

  /// Error frames: a save failure names its message; refusals and rate limits apply to what is on the socket.
  void _serverError(Map<String, Object?> data) {
    final socket = _socket;
    final id = data['clientMessageId'];
    final error = data['error'] is String ? data['error']! as String : null;
    if (error == 'message_failed') {
      if (id is! String) return;
      final outcome = outbox.rejected(id);
      if (outcome == null) return;
      if (outcome.failed) {
        _fail(id);
        _emit(
            _errors,
            const GiovSendFailedException(
                'Message could not be sent. Please try again.',
                code: 'message_failed'));
      } else {
        _later(outcome.retryAfter, () {
          if (identical(_socket, socket)) flush();
        });
      }
      return;
    }
    if (error == 'rate_limited') {
      // Too fast: everything on the socket goes again a little later, with the same ids.
      outbox.socketClosed();
      _later(const Duration(seconds: 3), () {
        if (identical(_socket, socket)) flush();
      });
      return;
    }
    // `invalid_message`, `invalid_attachment`, and any code added later (treated as
    // `invalid_message`): frames are checked in order, so the refusal is for the oldest message
    // still waiting. Ignoring it would leave that message "sending" and reconnect forever.
    final refused = outbox.refuseOldestSending();
    if (refused != null) _fail(refused.clientMessageId);
    _emit(
        _errors,
        GiovSendFailedException('Message could not be sent. Please try again.',
            code: error));
  }

  void _later(Duration delay, void Function() run) {
    late final Timer timer;
    timer = Timer(delay, () {
      _resendTimers.remove(timer);
      run();
    });
    _resendTimers.add(timer);
  }

  void _settle(String clientMessageId, GiovMessage? message) {
    final waiters = _pending.remove(clientMessageId) ?? const [];
    for (final waiter in waiters) {
      if (message != null) {
        waiter.complete(message);
      } else {
        waiter.completeError(const GiovSendFailedException(
            'Message could not be sent. Please try again.'));
      }
    }
  }

  void _fail(String clientMessageId) => _settle(clientMessageId, null);

  void _reconnect(int generation) {
    if (!_desired || generation != _generation || _reconnectTimer != null) {
      return;
    }
    final delay = giovReconnectDelay(_attempt++, jitter: _random.nextDouble());
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      _retryOpen(generation);
    });
  }

  void _retryOpen(int generation) {
    unawaited(_open(generation).catchError((Object error) {
      if (!_desired || generation != _generation) return;
      final failure = toGiovException(error);
      if (failure is GiovSessionExpiredException) {
        disconnect();
      } else {
        _reconnect(generation);
      }
      _emit(_errors, failure);
    }));
  }

  /// Reconnect now instead of waiting for the backoff, e.g. when the network comes back.
  void reconnectNow() {
    final timer = _reconnectTimer;
    if (!_desired || isConnected || timer == null) return;
    timer.cancel();
    _reconnectTimer = null;
    _attempt = 0;
    _retryOpen(_generation);
  }

  /// Puts everything waiting in the outbox on the socket, oldest first.
  void flush() {
    final socket = _socket;
    if (socket == null || !socket.isOpen) return;
    for (final item in outbox.takeQueued(now: _nowMs())) {
      try {
        socket.send(item.frame);
      } on Object {
        _dropSocket?.call();
        return;
      }
    }
  }

  /// Queues a visitor message and sends it as soon as a socket is open; returns its client message
  /// id at once. Delivery is tracked in [outbox] and confirmed through [acks]. Throws
  /// [GiovSendFailedException] for an empty or over-long message.
  String send(String text, {List<String> attachments = const []}) {
    final entry = outbox.enqueue(text, attachments: attachments, now: _nowMs());
    flush();
    return entry.clientMessageId;
  }

  /// Sends one message and completes with the stored copy once the server confirms it. While the
  /// connection is being restored it waits in the outbox instead of failing. Fails only when the
  /// server refuses it or [disconnect] is called first.
  Future<GiovMessage> sendMessage(String text) {
    final id = outbox.enqueue(text, now: _nowMs()).clientMessageId;
    final completer = Completer<GiovMessage>();
    _pending.putIfAbsent(id, () => []).add(completer);
    flush();
    return completer.future;
  }

  /// Sends a message that failed again, in its original place in the queue.
  bool retryMessage(String clientMessageId) {
    final retried = outbox.retry(clientMessageId);
    if (retried) flush();
    return retried;
  }

  /// The visitor started typing (send once per burst).
  void sendTyping() => _sendFrame({'type': 'typing'});
  void sendTypingEnd() => _sendFrame({'type': 'typing_end'});

  void _sendFrame(Map<String, Object?> frame) {
    final socket = _socket;
    if (socket == null || !socket.isOpen) return;
    try {
      socket.send(jsonEncode(frame));
    } on Object {
      // The next reconnect recovers.
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Uploads and push

  /// Uploads one file to this conversation and returns its URL for [send]. [onProgress] gets 0 to 1
  /// as the bytes leave the device. Retries once with a new token on 401. Throws
  /// [GiovAttachmentRejectedException] when the server refuses the file.
  Future<GiovUploadResult> uploadAttachment(GiovPickedFile file,
      {void Function(double fraction)? onProgress}) async {
    if (_session == null) throw const GiovDisconnectedException();
    final url = Uri.parse('$baseUrl$_conversationPath/upload-visitor');
    var token = (await _token()).token;
    var reply = await _upload(url, token, file, onProgress);
    if (reply.status == 401) {
      token = (await _token(force: true)).token;
      reply = await _upload(url, token, file, onProgress);
    }
    final url0 = reply.body['url'];
    if (!reply.ok || url0 is! String) {
      final message = reply.body['message'] is String
          ? reply.body['message']! as String
          : (reply.code ?? 'File upload failed.');
      final status = reply.status;
      if (status == 0) throw GiovNetworkException(message);
      if (reply.ok) {
        throw GiovInvalidResponseException('Invalid upload response.',
            status: status);
      }
      // 404: the conversation is gone; 401/403: so is the session; only other 4xx refuse the file.
      if (status == 401 || status == 403) {
        throw GiovSessionExpiredException(message,
            status: status, code: reply.code);
      }
      if (status == 404) {
        throw GiovConversationClosedException(message,
            status: status, code: reply.code);
      }
      if (status == 429) {
        throw GiovRateLimitedException(message, retryAfter: reply.retryAfter);
      }
      if (status >= 500) {
        throw GiovServerException(message, status: status, code: reply.code);
      }
      throw GiovAttachmentRejectedException(message,
          status: status, code: reply.code);
    }
    final access = AttachmentAccess.fromJson(reply.body['attachmentAccess']);
    if (access != null) _emit(_access, access);
    final filename = reply.body['filename'];
    return GiovUploadResult(
      url: url0,
      filename: filename is String ? filename : file.name,
      preview: GiovAttachmentPreview.sanitize(reply.body['preview']),
    );
  }

  Future<_Reply> _upload(Uri url, String token, GiovPickedFile file,
      void Function(double)? onProgress) async {
    try {
      // The whole exchange, not only the answer: a stalled network must not leave the upload (and
      // the composer waiting for it) hanging forever.
      return await _sendUpload(url, token, file, onProgress)
          .timeout(uploadTimeout);
    } on Object {
      return const _Reply(0, {}, Duration.zero);
    }
  }

  Future<_Reply> _sendUpload(Uri url, String token, GiovPickedFile file,
      void Function(double)? onProgress) async {
    final form = http.MultipartRequest('POST', url);
    final length = file.size ??
        (await file.openRead().expand((chunk) => chunk).toList()).length;
    MediaType type;
    try {
      type = MediaType.parse(file.mimeType);
    } on FormatException {
      type = MediaType('application', 'octet-stream');
    }
    form.files.add(http.MultipartFile('file', file.openRead(), length,
        filename: file.name.isEmpty ? 'file' : file.name, contentType: type));
    final preview = uploadPreview(file);
    if (preview != null) {
      form.fields['thumbnail'] = preview.thumb;
      form.fields['width'] = '${preview.width}';
      form.fields['height'] = '${preview.height}';
    }
    final body = form.finalize();
    final streamed = http.StreamedRequest('POST', url)
      ..headers.addAll({...form.headers, 'Authorization': 'Bearer $token'})
      ..contentLength = form.contentLength;
    final total = form.contentLength;
    var sent = 0;
    final sending = _http.send(streamed).then<http.StreamedResponse?>(
        (response) => response,
        onError: (Object _) => null);
    await streamed.sink.addStream(body.map((chunk) {
      sent += chunk.length;
      if (onProgress != null && total > 0) onProgress(min(1, sent / total));
      return chunk;
    }));
    unawaited(streamed.sink.close());
    final response = await sending;
    if (response == null) return const _Reply(0, {}, Duration.zero);
    final reply = _reply(await http.Response.fromStream(response));
    if (reply.ok) onProgress?.call(1);
    return reply;
  }

  /// Registers this device for visitor push notifications about this conversation (README, "Push
  /// notifications"). Never throws: a server without visitor push answers 404/405/501, after which
  /// the client stops asking and reports [GiovPushFailure.unsupported].
  Future<GiovPushResult> registerPushToken(
      String token, GiovPushPlatform platform,
      [GiovPushOptions options = const GiovPushOptions()]) async {
    if (_pushUnsupported) {
      return const GiovPushResult.notRegistered(GiovPushFailure.unsupported);
    }
    if (_session == null) {
      return const GiovPushResult.notRegistered(GiovPushFailure.noConversation);
    }
    if (token.trim().isEmpty || token.length > 4096) {
      return const GiovPushResult.notRegistered(GiovPushFailure.failed);
    }
    try {
      // The client marker is stored with the device, so the dashboard knows which SDK registered it.
      final reply =
          await _authed('POST', '$_conversationPath/push-token', headers: {
        'X-Giov-Client': giovClientMarker
      }, json: {
        'token': token,
        'platform': platform.name,
        if (options.environment != null)
          'environment': options.environment!.name,
        if (options.appId != null && options.appId!.isNotEmpty)
          'appId': options.appId,
        if ((options.locale ?? locale) != null)
          'locale': options.locale ?? locale,
      });
      if (reply.status == 404 || reply.status == 405 || reply.status == 501) {
        _pushUnsupported = true;
        return const GiovPushResult.notRegistered(GiovPushFailure.unsupported);
      }
      return reply.ok
          ? const GiovPushResult.registered()
          : const GiovPushResult.notRegistered(GiovPushFailure.failed);
    } on Object {
      return const GiovPushResult.notRegistered(GiovPushFailure.failed);
    }
  }

  /// Stops push notifications about this conversation on this device (sign-out, notifications off).
  /// Never throws; true when the server confirmed. While disconnected it uses [session] (the stored
  /// pair) with a fresh visitor token, so it also works with the chat closed.
  Future<bool> unregisterPushToken(String token, {GiovSession? session}) async {
    final current = _session;
    final target = current ?? session;
    if (target == null || _pushUnsupported || token.isEmpty) return false;
    try {
      if (current != null) {
        return (await _authed('DELETE', '$_conversationPath/push-token',
                json: {'token': token}))
            .ok;
      }
      final visitor = await _fetchToken(target);
      final reply = await _request(
        'DELETE',
        '/conversations/${Uri.encodeComponent(target.conversationId)}/push-token',
        headers: {'Authorization': 'Bearer ${visitor.token}'},
        json: {'token': token},
      );
      return reply.ok;
    } on Object {
      return false;
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Teardown

  void _rejectPending() {
    for (final waiters in _pending.values) {
      for (final waiter in waiters) {
        waiter.completeError(const GiovSendFailedException(
            'Delivery could not be confirmed. Check the conversation before sending again.'));
      }
    }
    _pending.clear();
  }

  /// Closes the connection. Unsent messages stay in the outbox; futures from [sendMessage] fail.
  void disconnect() {
    _rejectPending();
    _teardown();
  }

  void _teardown() {
    _desired = false;
    _generation++;
    _reconnectTimer?.cancel();
    _heartbeat?.cancel();
    _watchdog?.cancel();
    for (final timer in _resendTimers) {
      timer.cancel();
    }
    _resendTimers.clear();
    _reconnectTimer = _heartbeat = _watchdog = null;
    _dropSocket = null;
    _cancelHandshake?.call();
    _cancelHandshake = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      socket
        ..onOpen = null
        ..onMessage = null
        ..onError = null
        ..onClose = null
        ..close();
    }
    // Unsent messages stay in the outbox; a later connection sends them.
    outbox.socketClosed();
    _session = null;
    _visitorToken = null;
    _tokenRequest = null;
    _emit(_connection, false);
  }

  /// Disconnects and closes the streams. The client cannot be used afterwards.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    disconnect();
    for (final controller in <StreamController<Object?>>[
      _messages,
      _acks,
      _connection,
      _typing,
      _errors,
      _streams,
      _access
    ]) {
      unawaited(controller.close());
    }
    if (_ownsHttp) _http.close();
  }
}
